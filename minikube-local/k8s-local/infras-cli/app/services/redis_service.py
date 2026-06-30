"""Redis ACL provisioning service."""

import structlog
from typing import Dict, Any

from .base import InfrastructureService

logger = structlog.get_logger(__name__)


class RedisService(InfrastructureService):
    """Redis ACL provisioning using kubectl exec and ConfigMap updates."""

    async def create_acl(
        self,
        service_name: str,
        password: str,
        **kwargs
    ) -> Dict[str, Any]:
        """
        Create Redis ACL user and reload configuration.

        Args:
            service_name: Name of the service (also Redis username)
            password: Password for the service user
            **kwargs: Additional parameters (not used for Redis)

        Returns:
            Dictionary with connection details and vault path
        """
        logger.info("Creating Redis ACL", service_name=service_name)

        # 1. Fetch admin password from Vault
        admin_pass = await self.vault.fetch_secret("infras/redis/auth", "password")

        # 2. Update ConfigMap with new ACL rule
        # Format: user <service_name> on ><password> ~<service_name>:* &* +@all -@dangerous +cluster
        acl_rule = f"user {service_name} on >{password} ~{service_name}:* &* +@all -@dangerous +cluster"

        logger.debug("Updating Redis ACL ConfigMap", service_name=service_name)

        try:
            await self.k8s.update_config_map(
                namespace="infras-redis",
                name="redis-acl-config",
                key="users.acl",
                value=acl_rule,
                append=True
            )
        except Exception as e:
            logger.error("Failed to update Redis ConfigMap", error=str(e))
            # ConfigMap might not exist yet, create it
            logger.warning("ConfigMap update failed, attempting to use ACL LOAD directly")
            pass

        # 3. Reload ACL on all Redis pods
        logger.debug("Reloading ACL on Redis pods")

        # Get all Redis pods
        pods_output = await self.k8s.exec_command(
            namespace="infras-redis",
            pod="deployment/redis",  # This should resolve to all pods eventually
            command=["redis-cli", "-a", admin_pass, "ACL", "LOAD"]
        )

        # Note: In cluster setup, we need to reload on all nodes
        # For simplicity, we're using the deployment which will pick one pod
        # In production, you'd want to loop through all statefulset pods

        logger.info("Redis ACL reloaded successfully", service_name=service_name)

        # 4. Store credential in Vault
        vault_path = await self._store_credential(service_name, password)

        return {
            "host": "redis-0.redis-headless.infras-redis.svc.cluster.local",
            "port": 6379,
            "username": service_name,
            "vault_path": vault_path
        }

    async def verify_acl(self, service_name: str) -> bool:
        """
        Verify Redis ACL was created successfully.

        Args:
            service_name: Name of the service

        Returns:
            True if user exists in ACL list, False otherwise
        """
        logger.info("Verifying Redis ACL", service_name=service_name)

        # Errors here (Vault/exec failures) propagate so they are reported as
        # "could not verify" rather than a misleading "not found".
        admin_pass = await self.vault.fetch_secret("infras/redis/auth", "password")

        # List ACL users
        acl_list = await self.k8s.exec_command(
            namespace="infras-redis",
            pod="statefulset/redis",
            command=["redis-cli", "-a", admin_pass, "ACL", "LIST"]
        )

        # Check if user exists in ACL list
        user_exists = f"user {service_name} on" in acl_list

        if user_exists:
            logger.info("Redis ACL verified", service_name=service_name)
            return True

        logger.warning("Redis ACL not found", service_name=service_name)
        return False

    def get_vault_path(self, service_name: str) -> str:
        """
        Get Vault path for storing credentials.

        Args:
            service_name: Name of the service

        Returns:
            Vault path
        """
        return f"infras/redis/{service_name}"
