"""Factory must know about the minio infra type."""

from unittest.mock import MagicMock

from app.services.factory import ServiceFactory
from app.services.minio_service import MinIOService


def test_factory_creates_minio_service():
    svc = ServiceFactory.create_service("minio", MagicMock(), MagicMock())
    assert isinstance(svc, MinIOService)


def test_minio_in_supported_services():
    assert "minio" in ServiceFactory.get_supported_services()
