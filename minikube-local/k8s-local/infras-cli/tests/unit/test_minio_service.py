"""Unit tests for MinIOService (mocked Vault / MinIO clients)."""

import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from app.services.minio_service import MinIOService


def _service():
    vault = MagicMock()
    vault.fetch_secret = AsyncMock(side_effect=["minio", "minio123"])
    vault._detect_mount = MagicMock(return_value=("secret", "infras/minio/app1"))
    vault.client = MagicMock()
    svc = MinIOService(vault, MagicMock())
    # Neutralize the inherited Vault write so we test only MinIO behavior.
    svc._store_credential = AsyncMock(return_value="infras/minio/app1")
    return svc, vault


@pytest.mark.asyncio
async def test_create_acl_provisions_bucket_user_and_policy():
    svc, vault = _service()
    admin, s3 = MagicMock(), MagicMock()
    s3.bucket_exists.return_value = False
    with patch.object(MinIOService, "_clients", return_value=(admin, s3)):
        result = await svc.create_acl("app1", "secretpw")

    s3.make_bucket.assert_called_once_with("app1")
    admin.add_user.assert_called_once_with(access_key="app1", secret_key="secretpw")
    admin.set_user_or_group_policy.assert_called_once_with(
        policy_name="app-app1", user_or_group="app1"
    )
    # Policy JSON scopes to just this bucket
    _, kw = admin.add_canned_policy.call_args
    policy = json.loads(kw["policy"])
    assert policy["Statement"][0]["Resource"] == [
        "arn:aws:s3:::app1",
        "arn:aws:s3:::app1/*",
    ]
    assert result["bucket"] == "app1"
    assert result["access_key"] == "app1"
    assert result["vault_path"] == "infras/minio/app1"


@pytest.mark.asyncio
async def test_verify_acl_true_when_user_listed():
    svc, _ = _service()
    admin = MagicMock()
    admin.list_users.return_value = {"app1": {}, "other": {}}
    with patch.object(MinIOService, "_clients", return_value=(admin, MagicMock())):
        assert await svc.verify_acl("app1") is True


@pytest.mark.asyncio
async def test_verify_acl_false_when_user_absent():
    svc, _ = _service()
    admin = MagicMock()
    admin.list_users.return_value = {"other": {}}
    with patch.object(MinIOService, "_clients", return_value=(admin, MagicMock())):
        assert await svc.verify_acl("app1") is False


def test_get_vault_path():
    svc, _ = _service()
    assert svc.get_vault_path("app1") == "infras/minio/app1"
