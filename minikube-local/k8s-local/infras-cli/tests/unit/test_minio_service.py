"""Unit tests for MinIOService (mocked Vault / MinIO clients).

Mocks are spec'd to the real minio SDK classes so a call to a method that
does not exist on the pinned minio==7.2.15 raises AttributeError in-test
(catches API drift instead of failing only at deploy time).
"""

import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from minio import Minio, MinioAdmin

from app.services.minio_service import MinIOService


def _service():
    vault = MagicMock()
    vault.fetch_secret = AsyncMock(side_effect=["minio", "minio123"])
    svc = MinIOService(vault, MagicMock())
    # Neutralize the inherited Vault write so we test only MinIO behavior.
    svc._store_credential = AsyncMock(return_value="infras/minio/app1")
    return svc, vault


def test_policy_json_scopes_to_single_bucket():
    policy = json.loads(MinIOService._policy_json("app1"))
    assert policy["Statement"][0]["Resource"] == [
        "arn:aws:s3:::app1",
        "arn:aws:s3:::app1/*",
    ]


@pytest.mark.asyncio
async def test_create_acl_provisions_bucket_user_and_policy():
    svc, _ = _service()
    admin = MagicMock(spec=MinioAdmin)
    s3 = MagicMock(spec=Minio)
    s3.bucket_exists.return_value = False
    with patch.object(MinIOService, "_clients", return_value=(admin, s3)):
        result = await svc.create_acl("app1", "secretpw")

    s3.make_bucket.assert_called_once_with("app1")
    admin.user_add.assert_called_once_with("app1", "secretpw")
    admin.policy_set.assert_called_once_with("app-app1", user="app1")
    # policy_add receives the policy name and a filesystem path to the JSON
    assert admin.policy_add.call_count == 1
    assert admin.policy_add.call_args[0][0] == "app-app1"
    assert result["bucket"] == "app1"
    assert result["access_key"] == "app1"
    assert result["policy"] == "app-app1"
    assert result["vault_path"] == "infras/minio/app1"


@pytest.mark.asyncio
async def test_verify_acl_true_when_user_listed():
    svc, _ = _service()
    admin = MagicMock(spec=MinioAdmin)
    admin.user_list.return_value = json.dumps({"app1": {}, "other": {}})
    with patch.object(MinIOService, "_clients", return_value=(admin, MagicMock(spec=Minio))):
        assert await svc.verify_acl("app1") is True


@pytest.mark.asyncio
async def test_verify_acl_false_when_user_absent():
    svc, _ = _service()
    admin = MagicMock(spec=MinioAdmin)
    admin.user_list.return_value = json.dumps({"other": {}})
    with patch.object(MinIOService, "_clients", return_value=(admin, MagicMock(spec=Minio))):
        assert await svc.verify_acl("app1") is False


def test_get_vault_path():
    svc, _ = _service()
    assert svc.get_vault_path("app1") == "infras/minio/app1"
