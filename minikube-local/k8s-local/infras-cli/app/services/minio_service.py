"""MinIO ACL provisioning service (bucket-per-app + scoped IAM policy)."""

import json
import os
import re
import tempfile
import structlog
from typing import Dict, Any

from minio import Minio, MinioAdmin
from minio.credentials import StaticProvider

from .base import InfrastructureService
from ..config import settings

logger = structlog.get_logger(__name__)


class MinIOService(InfrastructureService):
    """Provision MinIO access: a dedicated bucket + scoped policy + user per app.

    Method names target the pinned minio==7.2.15 admin API:
      user_add(access_key, secret_key), policy_add(policy_name, policy_file),
      policy_set(policy_name, user=...), user_list() -> JSON string.
    """

    def _clients(self, admin_user: str, admin_pass: str):
        """Build (MinioAdmin, Minio) clients from admin credentials."""
        creds = StaticProvider(admin_user, admin_pass)
        admin = MinioAdmin(
            endpoint=settings.minio_endpoint,
            credentials=creds,
            secure=settings.minio_secure,
        )
        s3 = Minio(
            settings.minio_endpoint,
            access_key=admin_user,
            secret_key=admin_pass,
            secure=settings.minio_secure,
        )
        return admin, s3

    @staticmethod
    def _bucket_name(service_name: str) -> str:
        """Derive an S3-valid bucket name from the service name.

        The MinIO *user* (access key) keeps the exact service name — MinIO
        allows underscores/uppercase there, and it stays consistent with the
        app's identity and Vault (e.g. `super_app`, like postgres/kafka). Only
        the *bucket* must obey S3 rules (3-63 chars, lowercase alphanumerics
        and hyphens, start/end alphanumeric), so we sanitize just the bucket:
        lowercase, non-alphanumerics → '-', collapse/trim hyphens.

        Raises ValueError only when no valid bucket name can be formed (too
        short/long or empty after sanitizing).
        """
        b = re.sub(r"[^a-z0-9]+", "-", service_name.lower()).strip("-")
        b = re.sub(r"-{2,}", "-", b)
        if not re.match(r"^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", b):
            raise ValueError(
                f"Cannot derive a valid S3 bucket name from '{service_name}': "
                f"result '{b}' must be 3-63 chars of lowercase letters/digits/hyphens "
                "(start & end alphanumeric). Choose a longer/simpler name."
            )
        return b

    @staticmethod
    def _policy_json(bucket: str) -> str:
        """Full read/write scoped to exactly one bucket."""
        return json.dumps({
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Action": ["s3:*"],
                    "Resource": [
                        f"arn:aws:s3:::{bucket}",
                        f"arn:aws:s3:::{bucket}/*",
                    ],
                }
            ],
        })

    async def create_acl(self, service_name: str, password: str, **kwargs) -> Dict[str, Any]:
        logger.info("Creating MinIO ACL", service_name=service_name)

        admin_user = await self.vault.fetch_secret("infras/minio/root", "username")
        admin_pass = await self.vault.fetch_secret("infras/minio/root", "password")

        admin, s3 = self._clients(admin_user, admin_pass)
        # User/access-key keeps the exact service name; bucket is sanitized to
        # satisfy S3 naming (e.g. super_app -> user super_app, bucket super-app).
        bucket = self._bucket_name(service_name)
        policy_name = f"app-{service_name}"

        # 1. Bucket (idempotent)
        if not s3.bucket_exists(bucket):
            s3.make_bucket(bucket)
            logger.info("Created MinIO bucket", bucket=bucket)

        # 2. Scoped policy (upsert). policy_add reads a FILE path, so write the
        #    JSON to a temp file and clean it up afterwards.
        fd, policy_file = tempfile.mkstemp(suffix=".json")
        try:
            with os.fdopen(fd, "w") as f:
                f.write(self._policy_json(bucket))
            admin.policy_add(policy_name, policy_file)
        finally:
            os.unlink(policy_file)

        # 3. User whose access key IS the service name (upsert)
        admin.user_add(service_name, password)

        # 4. Attach the policy to the user
        admin.policy_set(policy_name, user=service_name)

        # 5. Store credential in Vault (+ app secret) via the inherited helper
        vault_path = await self._store_credential(service_name, password)

        logger.info("MinIO ACL created", service_name=service_name, vault_path=vault_path)
        return {
            "endpoint": settings.minio_endpoint,
            "bucket": bucket,
            "access_key": service_name,
            "policy": policy_name,
            "vault_path": vault_path,
        }

    async def verify_acl(self, service_name: str, **kwargs) -> bool:
        logger.info("Verifying MinIO ACL", service_name=service_name)
        admin_user = await self.vault.fetch_secret("infras/minio/root", "username")
        admin_pass = await self.vault.fetch_secret("infras/minio/root", "password")
        admin, _ = self._clients(admin_user, admin_pass)
        # Errors (endpoint/Vault unreachable) propagate -> reported as "could not verify".
        # user_list() returns a JSON string keyed by access key.
        users = json.loads(admin.user_list())
        exists = service_name in users
        if exists:
            logger.info("MinIO ACL verified", service_name=service_name)
        else:
            logger.warning("MinIO ACL not found", service_name=service_name)
        return exists

    def get_vault_path(self, service_name: str) -> str:
        return f"infras/minio/{service_name}"
