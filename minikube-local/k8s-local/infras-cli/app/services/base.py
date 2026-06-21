"""Abstract base class for infrastructure services."""

from abc import ABC, abstractmethod
from typing import Dict, Any, Optional
import structlog

logger = structlog.get_logger(__name__)


class InfrastructureService(ABC):
    """
    Abstract base class for all infrastructure services.

    All services (MySQL, PostgreSQL, Redis, Kafka, Keycloak) must
    implement this interface to ensure consistent ACL creation.
    """

    def __init__(self, vault_service, k8s_operations):
        """
        Initialize infrastructure service.

        Args:
            vault_service: Vault service instance
            k8s_operations: Kubernetes operations instance
        """
        self.vault = vault_service
        self.k8s = k8s_operations

    @abstractmethod
    async def create_acl(
        self,
        service_name: str,
        password: str,
        **kwargs
    ) -> Dict[str, Any]:
        """
        Create ACL for a service.

        Args:
            service_name: Name of the service
            password: Password for the service
            **kwargs: Additional service-specific parameters (e.g., owner_username for Keycloak)

        Returns:
            Dictionary with connection details and vault path

        Raises:
            Exception: If ACL creation fails
        """
        pass

    @abstractmethod
    async def verify_acl(self, service_name: str) -> bool:
        """
        Verify that ACL was created successfully.

        Args:
            service_name: Name of the service

        Returns:
            True if ACL exists and is working, False otherwise
        """
        pass

    @abstractmethod
    def get_vault_path(self, service_name: str) -> str:
        """
        Get Vault path for storing credentials.

        Args:
            service_name: Name of the service

        Returns:
            Vault path (e.g., "infras/mysql/service_name")
        """
        pass

    async def _store_credential(
        self,
        service_name: str,
        password: str
    ) -> str:
        """
        Store credential in Vault with {infra_type}.username and {infra_type}.password keys.

        Also creates app secret at 'apps/data/{service_name}' with application.name
        and the infra credentials.

        Args:
            service_name: Name of the service
            password: Password to store

        Returns:
            Vault path where credential was stored
        """
        # Get infra type from class name (e.g., KafkaService -> kafka)
        infra_type = self.__class__.__name__.replace("Service", "").lower()

        vault_path = self.get_vault_path(service_name)

        # Store with {infra_type}.username and {infra_type}.password format
        mount_point, secret_path = self.vault._detect_mount(vault_path)
        self.vault.client.secrets.kv.v2.create_or_update_secret(
            path=secret_path,
            mount_point=mount_point,
            secret={
                f"{infra_type}.username": service_name,
                f"{infra_type}.password": password
            }
        )
        logger.info("Stored credential in Vault", vault_path=vault_path, infra_type=infra_type)

        # Create app secret
        await self._create_app_secret(service_name, password, infra_type)

        return vault_path

    async def _create_app_secret(
        self,
        service_name: str,
        password: str,
        infra_type: str
    ) -> None:
        """
        Create/update app secret in Vault with application name only.

        Creates/updates the secret at 'apps/{service_name}' with:
        - application.name: service name

        The infra credentials ({infra_type}.username, {infra_type}.password)
        are stored separately in the infra secret path.

        Args:
            service_name: Name of the service/app
            password: Password for the infra service (not stored in app secret)
            infra_type: Infrastructure type (kafka, postgres, etc.)
        """
        app_secret_path = f"apps/{service_name}"

        # Check if app secret already exists
        mount_point, secret_path = self.vault._detect_mount(app_secret_path)
        existing_data = {}
        try:
            response = self.vault.client.secrets.kv.v2.read_secret_version(
                path=secret_path,
                mount_point=mount_point
            )
            existing_data = response['data']['data']
        except Exception:
            pass  # Secret doesn't exist yet

        # Only update application.name, preserve other existing keys
        # (but don't store infra credentials here)
        app_secret_data = {
            **existing_data,
            "application.name": service_name
        }

        logger.info("Creating app secret", app_path=app_secret_path)

        self.vault.client.secrets.kv.v2.create_or_update_secret(
            path=secret_path,
            mount_point=mount_point,
            secret=app_secret_data
        )
        logger.info("App secret created successfully", app_path=app_secret_path)
