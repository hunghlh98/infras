"""PostgreSQL ACL provisioning service."""

import structlog
from typing import Dict, Any

from .base import InfrastructureService

logger = structlog.get_logger(__name__)


class PostgreSQLService(InfrastructureService):
    """PostgreSQL ACL provisioning using kubectl exec."""

    async def create_acl(
        self,
        service_name: str,
        password: str,
        **kwargs
    ) -> Dict[str, Any]:
        """
        Create PostgreSQL database, user, and set ownership.

        Args:
            service_name: Name of the service (also database name and username)
            password: Password for the service user
            **kwargs: Additional parameters (not used for PostgreSQL)

        Returns:
            Dictionary with connection details and vault path
        """
        logger.info("Creating PostgreSQL ACL", service_name=service_name)

        # 1. Fetch admin password from Vault
        admin_pass = await self.vault.fetch_secret("infras/postgres/auth", "password")

        # Helper function to run psql with password
        async def psql_command(sql: str) -> str:
            """Execute psql command with authentication."""
            return await self.k8s.exec_command(
                namespace="infras-postgres",
                pod="deployment/postgres",
                container="postgres",
                command=["bash", "-c", f"PGPASSWORD='{admin_pass}' psql -U postgres -c \"{sql}\""]
            )

        async def psql_query(sql: str) -> str:
            """Execute psql query with authentication (returns unformatted output)."""
            return await self.k8s.exec_command(
                namespace="infras-postgres",
                pod="deployment/postgres",
                container="postgres",
                command=["bash", "-c", f"PGPASSWORD='{admin_pass}' psql -U postgres -tAc \"{sql}\""]
            )

        # 2. Check if user exists
        check_user = f"SELECT 1 FROM pg_roles WHERE rolname='{service_name}';"
        user_exists = await psql_query(check_user)

        # 3. Create or update user
        if not user_exists.strip():
            logger.debug("Creating PostgreSQL user", service_name=service_name)
            create_cmd = f'CREATE USER "{service_name}" WITH PASSWORD \'{password}\';'
            await psql_command(create_cmd)
        else:
            logger.debug("Updating PostgreSQL user password", service_name=service_name)
            alter_cmd = f'ALTER USER "{service_name}" WITH PASSWORD \'{password}\';'
            await psql_command(alter_cmd)

        # 4. Check and create database
        check_db = f"SELECT 1 FROM pg_database WHERE datname='{service_name}';"
        db_exists = await psql_query(check_db)

        if not db_exists.strip():
            logger.debug("Creating PostgreSQL database", service_name=service_name)
            create_db_cmd = f'CREATE DATABASE "{service_name}" OWNER "{service_name}";'
            await psql_command(create_db_cmd)
        else:
            logger.debug("Updating PostgreSQL database ownership", service_name=service_name)
            alter_db_cmd = f'ALTER DATABASE "{service_name}" OWNER TO "{service_name}";'
            await psql_command(alter_db_cmd)

        # 5. Store credential in Vault
        vault_path = await self._store_credential(service_name, password)

        logger.info("PostgreSQL ACL created successfully", service_name=service_name, vault_path=vault_path)

        return {
            "database": service_name,
            "host": "postgres.infras-postgres.svc.cluster.local",
            "port": 5432,
            "username": service_name,
            "vault_path": vault_path
        }

    async def verify_acl(self, service_name: str) -> bool:
        """
        Verify PostgreSQL ACL was created successfully.

        Args:
            service_name: Name of the service

        Returns:
            True if database and user exist, False otherwise
        """
        logger.info("Verifying PostgreSQL ACL", service_name=service_name)

        # Errors here (Vault/exec failures) propagate to the caller so they are
        # reported as "could not verify" rather than a misleading "not found".
        admin_pass = await self.vault.fetch_secret("infras/postgres/auth", "password")

        # Helper function to run psql with password
        async def psql_query(sql: str) -> str:
            """Execute psql query with authentication (returns unformatted output)."""
            return await self.k8s.exec_command(
                namespace="infras-postgres",
                pod="deployment/postgres",
                container="postgres",
                command=["bash", "-c", f"PGPASSWORD='{admin_pass}' psql -U postgres -tAc \"{sql}\""]
            )

        # Check if user exists
        user_check = await psql_query(f"SELECT 1 FROM pg_roles WHERE rolname='{service_name}';")

        # Check if database exists
        db_check = await psql_query(f"SELECT 1 FROM pg_database WHERE datname='{service_name}';")

        user_exists = bool(user_check.strip())
        db_exists = bool(db_check.strip())

        if user_exists and db_exists:
            logger.info("PostgreSQL ACL verified", service_name=service_name)
            return True

        # Queries ran but role/database is absent -> genuinely not found.
        logger.warning("PostgreSQL ACL not found", service_name=service_name,
                       user_exists=user_exists, db_exists=db_exists)
        return False

    def get_vault_path(self, service_name: str) -> str:
        """
        Get Vault path for storing credentials.

        Args:
            service_name: Name of the service

        Returns:
            Vault path
        """
        return f"infras/postgres/{service_name}"
