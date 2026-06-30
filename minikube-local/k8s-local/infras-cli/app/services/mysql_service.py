"""MySQL ACL provisioning service."""

import structlog
from typing import Dict, Any

from .base import InfrastructureService

logger = structlog.get_logger(__name__)


class MySQLService(InfrastructureService):
    """MySQL ACL provisioning using kubectl exec."""

    async def create_acl(
        self,
        service_name: str,
        password: str,
        **kwargs
    ) -> Dict[str, Any]:
        """
        Create MySQL database, user, and grants.

        Args:
            service_name: Name of the service (also database name and username)
            password: Password for the service user
            **kwargs: Additional parameters (not used for MySQL)

        Returns:
            Dictionary with connection details and vault path
        """
        logger.info("Creating MySQL ACL", service_name=service_name)

        # 1. Fetch root password from Vault
        root_pass = await self.vault.fetch_secret("infras/mysql/root", "password")

        # 2. Execute SQL commands via kubectl exec
        commands = [
            # Create database
            f"CREATE DATABASE IF NOT EXISTS `{service_name}`;",
            # Create user (with backticks for identifier, single quotes for string)
            f"CREATE USER IF NOT EXISTS '{service_name}'@'%' IDENTIFIED BY '{password}';",
            # Update password
            f"ALTER USER '{service_name}'@'%' IDENTIFIED BY '{password}';",
            # Grant privileges
            f"GRANT ALL PRIVILEGES ON `{service_name}`.* TO '{service_name}'@'%';",
            # Flush privileges
            "FLUSH PRIVILEGES;"
        ]

        for cmd in commands:
            logger.debug("Executing MySQL command", command=cmd[:50] + "...")
            await self.k8s.exec_command(
                namespace="infras-mysql",
                pod="deployment/mysql",
                command=["mysql", "-u", "root", f"-p{root_pass}", "-e", cmd]
            )

        # 3. Store credential in Vault
        vault_path = await self._store_credential(service_name, password)

        logger.info("MySQL ACL created successfully", service_name=service_name, vault_path=vault_path)

        return {
            "database": service_name,
            "host": "mysql.infras-mysql.svc.cluster.local",
            "port": 3306,
            "username": service_name,
            "vault_path": vault_path
        }

    async def verify_acl(self, service_name: str) -> bool:
        """
        Verify MySQL ACL was created successfully.

        Args:
            service_name: Name of the service

        Returns:
            True if database and user exist, False otherwise
        """
        logger.info("Verifying MySQL ACL", service_name=service_name)

        # Errors here (Vault/exec failures) propagate so they are reported as
        # "could not verify" rather than a misleading "not found".
        root_pass = await self.vault.fetch_secret("infras/mysql/root", "password")

        # Check if database exists
        db_check = await self.k8s.exec_command(
            namespace="infras-mysql",
            pod="deployment/mysql",
            command=["mysql", "-u", "root", "-p" + root_pass,
                   "-e", f"SHOW DATABASES LIKE '{service_name}';"]
        )

        # Check if user exists
        user_check = await self.k8s.exec_command(
            namespace="infras-mysql",
            pod="deployment/mysql",
            command=["mysql", "-u", "root", "-p" + root_pass,
                   "-e", f"SELECT User FROM mysql.user WHERE User='{service_name}';"]
        )

        db_exists = service_name in db_check
        user_exists = service_name in user_check

        if db_exists and user_exists:
            logger.info("MySQL ACL verified", service_name=service_name)
            return True

        logger.warning("MySQL ACL not found", service_name=service_name,
                       db_exists=db_exists, user_exists=user_exists)
        return False

    def get_vault_path(self, service_name: str) -> str:
        """
        Get Vault path for storing credentials.

        Args:
            service_name: Name of the service

        Returns:
            Vault path
        """
        return f"infras/mysql/{service_name}"
