"""Keycloak realm and client provisioning service."""

import structlog
import requests
from typing import Dict, Any

from .base import InfrastructureService

logger = structlog.get_logger(__name__)


class KeycloakService(InfrastructureService):
    """Keycloak realm/client provisioning using HTTP API."""

    async def create_acl(
        self,
        service_name: str,
        password: str,
        owner_username: str = None,
        **kwargs
    ) -> Dict[str, Any]:
        """
        Create Keycloak realm, user, and client.

        Args:
            service_name: Name of the service (also client_id)
            password: Password for the service client
            owner_username: Owner username (realm name and username)
            **kwargs: Additional parameters (not used)

        Returns:
            Dictionary with connection details and vault path

        Raises:
            ValueError: If owner_username is not provided
        """
        if not owner_username:
            raise ValueError("owner_username is required for Keycloak ACL creation")

        logger.info("Creating Keycloak ACL", service_name=service_name, realm=owner_username)

        # 1. Fetch admin credentials from Vault
        admin_user = await self.vault.fetch_secret("infras/keycloak/auth", "username")
        admin_pass = await self.vault.fetch_secret("infras/keycloak/auth", "password")

        # 2. Authenticate with Keycloak admin API
        keycloak_url = "http://keycloak.infras-keycloak.svc.cluster.local:8080"

        logger.debug("Authenticating with Keycloak admin API")

        token_response = requests.post(
            f"{keycloak_url}/realms/master/protocol/openid-connect/token",
            data={
                "grant_type": "password",
                "client_id": "admin-cli",
                "username": admin_user,
                "password": admin_pass
            }
        )
        token_response.raise_for_status()
        token = token_response.json()["access_token"]
        headers = {"Authorization": f"Bearer {token}"}

        # 3. Check if realm exists, create if not
        logger.debug("Checking if realm exists", realm=owner_username)

        realm_response = requests.get(
            f"{keycloak_url}/admin/realms/{owner_username}",
            headers=headers
        )

        if realm_response.status_code == 404:
            logger.info("Creating Keycloak realm", realm=owner_username)
            create_realm_response = requests.post(
                f"{keycloak_url}/admin/realms",
                headers=headers,
                json={"realm": owner_username, "enabled": True}
            )
            create_realm_response.raise_for_status()
        else:
            realm_response.raise_for_status()

        # 4. Check if user exists in realm, create with realm-admin role if not
        logger.debug("Checking if realm user exists", username=owner_username)

        users_response = requests.get(
            f"{keycloak_url}/admin/realms/{owner_username}/users",
            params={"username": owner_username},
            headers=headers
        )
        users_response.raise_for_status()
        users = users_response.json()

        if not users:
            logger.info("Creating realm user", username=owner_username)

            # Generate password and store in Vault
            user_pass = await self.vault.ensure_credential(
                f"infras/keycloak/users/{owner_username}",
                owner_username
            )

            # Create user
            create_user_response = requests.post(
                f"{keycloak_url}/admin/realms/{owner_username}/users",
                headers=headers,
                json={"username": owner_username, "enabled": True}
            )
            create_user_response.raise_for_status()

            # Get user ID
            user_id = requests.get(
                f"{keycloak_url}/admin/realms/{owner_username}/users",
                params={"username": owner_username},
                headers=headers
            ).json()[0]["id"]

            # Set password
            set_password_response = requests.put(
                f"{keycloak_url}/admin/realms/{owner_username}/users/{user_id}/reset-password",
                headers=headers,
                json={"type": "password", "value": user_pass}
            )
            set_password_response.raise_for_status()

            logger.info("Realm user created successfully", username=owner_username)
        else:
            logger.debug("Realm user already exists", username=owner_username)

        # 5. Check if client exists, create or update secret
        logger.debug("Checking if client exists", client_id=service_name)

        clients_response = requests.get(
            f"{keycloak_url}/admin/realms/{owner_username}/clients",
            params={"clientId": service_name},
            headers=headers
        )
        clients_response.raise_for_status()
        clients = clients_response.json()

        if not clients:
            logger.info("Creating Keycloak client", client_id=service_name)
            create_client_response = requests.post(
                f"{keycloak_url}/admin/realms/{owner_username}/clients",
                headers=headers,
                json={
                    "clientId": service_name,
                    "secret": password,
                    "publicClient": False,
                    "directAccessGrantsEnabled": True,
                    "serviceAccountsEnabled": True
                }
            )
            create_client_response.raise_for_status()
        else:
            logger.info("Updating Keycloak client secret", client_id=service_name)
            client_id = clients[0]["id"]
            update_client_response = requests.put(
                f"{keycloak_url}/admin/realms/{owner_username}/clients/{client_id}",
                headers=headers,
                json={"secret": password}
            )
            update_client_response.raise_for_status()

        logger.info("Keycloak ACL created successfully",
                   service_name=service_name,
                   realm=owner_username)

        return {
            "realm": owner_username,
            "client_id": service_name,
            "client_secret": password,
            "url": f"{keycloak_url}/realms/{owner_username}",
            "vault_path": f"infras/keycloak/users/{owner_username}"
        }

    async def verify_acl(self, service_name: str, owner_username: str = None) -> bool:
        """
        Verify Keycloak realm and client were created successfully.

        Args:
            service_name: Name of the service (client_id)
            owner_username: Owner username (realm name)

        Returns:
            True if realm and client exist, False otherwise
        """
        if not owner_username:
            raise ValueError("owner_username (realm) is required for Keycloak verification")

        logger.info("Verifying Keycloak ACL", service_name=service_name, realm=owner_username)

        # Errors here (Vault/Keycloak API failures) propagate so they are
        # reported as "could not verify" rather than a misleading "not found".
        admin_pass = await self.vault.fetch_secret("infras/keycloak/auth", "password")
        keycloak_url = "http://keycloak.infras-keycloak.svc.cluster.local:8080"

        # Get admin token
        token_response = requests.post(
            f"{keycloak_url}/realms/master/protocol/openid-connect/token",
            data={
                "grant_type": "password",
                "client_id": "admin-cli",
                "username": await self.vault.fetch_secret("infras/keycloak/auth", "username"),
                "password": admin_pass
            }
        )
        token_response.raise_for_status()
        token = token_response.json()["access_token"]
        headers = {"Authorization": f"Bearer {token}"}

        # Check if realm exists
        realm_response = requests.get(
            f"{keycloak_url}/admin/realms/{owner_username}",
            headers=headers
        )

        if realm_response.status_code == 404:
            logger.warning("Keycloak realm not found", realm=owner_username)
            return False
        realm_response.raise_for_status()

        # Check if client exists
        clients_response = requests.get(
            f"{keycloak_url}/admin/realms/{owner_username}/clients",
            params={"clientId": service_name},
            headers=headers
        )
        clients_response.raise_for_status()
        clients = clients_response.json()

        if clients:
            logger.info("Keycloak ACL verified", service_name=service_name, realm=owner_username)
            return True

        logger.warning("Keycloak client not found", service_name=service_name)
        return False

    def get_vault_path(self, service_name: str, owner_username: str = None) -> str:
        """
        Get Vault path for storing credentials.

        Args:
            service_name: Name of the service
            owner_username: Owner username (required for Keycloak)

        Returns:
            Vault path
        """
        if not owner_username:
            # For vault path, we might just return a pattern
            return f"infras/keycloak/users/<owner_username>"
        return f"infras/keycloak/users/{owner_username}"
