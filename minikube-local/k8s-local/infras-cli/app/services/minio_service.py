"""MinIO ACL provisioning service (bucket-per-app + scoped IAM policy)."""

import json
import structlog
from typing import Dict, Any

from minio import Minio, MinioAdmin
from minio.credentials import StaticProvider

from .base import InfrastructureService
from ..config import settings

logger = structlog.get_logger(__name__)


class MinIOService(InfrastructureService):
    """Provision MinIO access: a dedicated bucket + scoped policy + user per app."""

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
        bucket = service_name
        policy_name = f"app-{service_name}"

        # 1. Bucket (idempotent)
        if not s3.bucket_exists(bucket):
            s3.make_bucket(bucket)
            logger.info("Created MinIO bucket", bucket=bucket)

        # 2. Scoped canned policy (upsert)
        admin.add_canned_policy(policy_name=policy_name, policy=self._policy_json(bucket))

        # 3. User whose access key IS the service name (upsert)
        admin.add_user(access_key=service_name, secret_key=password)

        # 4. Attach the policy to the user
        admin.set_user_or_group_policy(policy_name=policy_name, user_or_group=service_name)

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
        users = admin.list_users()
        exists = service_name in users
        if exists:
            logger.info("MinIO ACL verified", service_name=service_name)
        else:
            logger.warning("MinIO ACL not found", service_name=service_name)
        return exists

    def get_vault_path(self, service_name: str) -> str:
        return f"infras/minio/{service_name}"
