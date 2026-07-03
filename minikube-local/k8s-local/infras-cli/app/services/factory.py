"""Service factory for creating infrastructure service instances."""

import structlog
from typing import Type

from .base import InfrastructureService
from .mysql_service import MySQLService
from .postgres_service import PostgreSQLService
from .redis_service import RedisService
from .kafka_service import KafkaService
from .keycloak_service import KeycloakService
from .minio_service import MinIOService
from .vault_service import VaultService
from ..k8s.operations import KubernetesOperations

logger = structlog.get_logger(__name__)


class ServiceFactory:
    """Factory for creating infrastructure service instances."""

    SUPPORTED_SERVICES = {
        "mysql": MySQLService,
        "postgres": PostgreSQLService,
        "postgresql": PostgreSQLService,  # Alias for postgres
        "redis": RedisService,
        "kafka": KafkaService,
        "keycloak": KeycloakService,
        "minio": MinIOService,
    }

    @classmethod
    def create_service(
        cls,
        infra_type: str,
        vault_service: VaultService,
        k8s_ops: KubernetesOperations
    ) -> InfrastructureService:
        """
        Create a service instance by infrastructure type.

        Args:
            infra_type: Infrastructure type (mysql, postgres, redis, kafka, keycloak)
            vault_service: Vault service instance
            k8s_ops: Kubernetes operations instance

        Returns:
            Infrastructure service instance

        Raises:
            ValueError: If infrastructure type is not supported

        Example:
            >>> vault = VaultService()
            >>> k8s = KubernetesOperations()
            >>> service = ServiceFactory.create_service("mysql", vault, k8s)
            >>> isinstance(service, MySQLService)
            True
        """
        # Normalize to lowercase
        infra_type_lower = infra_type.lower()

        # Check if service type is supported
        if infra_type_lower not in cls.SUPPORTED_SERVICES:
            supported = ", ".join(sorted(set(cls.SUPPORTED_SERVICES.keys())))
            raise ValueError(
                f"Unsupported infrastructure type: '{infra_type}'. "
                f"Supported types: {supported}"
            )

        # Get service class
        service_class: Type[InfrastructureService] = cls.SUPPORTED_SERVICES[infra_type_lower]

        logger.info(
            "Creating infrastructure service",
            infra_type=infra_type_lower,
            service_class=service_class.__name__
        )

        # Create and return service instance
        return service_class(vault_service, k8s_ops)

    @classmethod
    def get_supported_services(cls) -> list:
        """
        Get list of supported infrastructure types.

        Returns:
            List of supported service type names
        """
        return sorted(set(cls.SUPPORTED_SERVICES.keys()))
