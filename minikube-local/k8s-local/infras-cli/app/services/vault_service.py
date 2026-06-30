"""Vault service for secrets, policies, tokens, and user management."""

import structlog
from typing import List, Optional, Dict, Any
import time

try:
    from hvac import Client as VaultClient
    from hvac.exceptions import VaultError
except ImportError:
    raise ImportError("hvac library is required. Install with: pip install hvac")

from ..config import settings

logger = structlog.get_logger(__name__)


class VaultService:
    """
    Vault service for managing secrets, policies, tokens, and users.

    Supports KV v2 secrets engines and userpass authentication.
    """

    def __init__(self, vault_addr: str = None, vault_token: str = None):
        """
        Initialize Vault service.

        Args:
            vault_addr: Vault address (default from settings)
            vault_token: Vault root token (default from settings or env)
        """
        self.vault_addr = vault_addr or settings.vault_addr
        self.vault_token = vault_token or settings.vault_token

        if not self.vault_token:
            raise ValueError("Vault token is required")

        # Initialize hvac client
        self.client = VaultClient(
            url=self.vault_addr,
            token=self.vault_token
        )

        logger.info("Vault service initialized", vault_addr=self.vault_addr)

        # Note: Connection verification is done on-demand in check_connection()
        # We don't verify in __init__ to avoid blocking during initialization

    # ============================================================================
    # Connection Operations
    # ============================================================================

    async def check_connection(self) -> bool:
        """
        Check if Vault is reachable (unauthenticated health ping).

        Note: this succeeds even when the configured token is invalid, because
        Vault's health endpoint does not require authentication. Use
        check_token_valid() to verify the token itself.

        Returns:
            True if Vault is reachable, False otherwise
        """
        try:
            self.client.sys.read_health_status()
            logger.debug("Vault connection check successful")
            return True
        except Exception as e:
            logger.warning("Vault connection check failed", error=str(e))
            return False

    async def check_token_valid(self) -> bool:
        """
        Check if the configured Vault token actually authenticates.

        Performs a token lookup-self; returns False if the token is missing,
        expired, revoked, or otherwise invalid (i.e. credentials are stale).

        Returns:
            True if the token is valid, False otherwise
        """
        try:
            if not self.vault_token:
                return False
            self.client.auth.token.lookup_self()
            logger.debug("Vault token validity check successful")
            return True
        except Exception as e:
            logger.warning("Vault token validity check failed", error=str(e))
            return False

    # ============================================================================
    # Secret Operations (KV v2)
    # ============================================================================

    async def fetch_secret(self, path: str, field: str = "value") -> str:
        """
        Fetch a secret from Vault KV v2.

        Args:
            path: Secret path (without mount prefix, e.g., "mysql/root")
            field: Field name within the secret (default: "value")

        Returns:
            Secret value as string

        Raises:
            VaultError: If secret doesn't exist or access denied
        """
        logger.debug("Fetching secret from Vault", path=path, field=field)

        # Detect mount point from path prefix
        mount_point, secret_path = self._detect_mount(path)

        try:
            response = self.client.secrets.kv.v2.read_secret_version(
                path=secret_path,
                mount_point=mount_point
            )

            # KV v2 stores data in response['data']['data']
            if field in response['data']['data']:
                value = response['data']['data'][field]
                logger.debug("Secret fetched successfully", path=path, field=field)
                return str(value)
            else:
                raise ValueError(f"Field '{field}' not found in secret at {path}")

        except Exception as e:
            logger.error("Failed to fetch secret", path=path, field=field, error=str(e))
            raise

    async def list_secrets(self, path: str) -> list:
        """
        List secret keys under a KV v2 path.

        Args:
            path: Path to list (e.g., "infras/postgres" or "apps")

        Returns:
            List of key names (trailing slashes stripped). Returns [] if the
            path has no entries or does not exist.
        """
        mount_point, secret_path = self._detect_mount(path)
        try:
            resp = self.client.secrets.kv.v2.list_secrets(
                path=secret_path,
                mount_point=mount_point
            )
            keys = resp.get("data", {}).get("keys", [])
            return [k.rstrip("/") for k in keys]
        except Exception as e:
            # InvalidPath (no entries) is normal — return empty rather than error
            logger.debug("List secrets returned nothing", path=path, error=str(e))
            return []

    async def store_credential(
        self,
        path: str,
        username: str,
        password: str
    ) -> None:
        """
        Store username/password credential in Vault KV v2.

        Args:
            path: Secret path (without mount prefix)
            username: Username
            password: Password

        Raises:
            VaultError: If storage fails
        """
        logger.debug("Storing credential in Vault", path=path, username=username)

        # Detect mount point
        mount_point, secret_path = self._detect_mount(path)

        try:
            self.client.secrets.kv.v2.create_or_update_secret(
                path=secret_path,
                mount_point=mount_point,
                secret={
                    "username": username,
                    "password": password
                }
            )
            logger.info("Credential stored successfully", vault_path=path)

        except Exception as e:
            logger.error("Failed to store credential", path=path, error=str(e))
            raise

    async def ensure_credential(
        self,
        path: str,
        username: str
    ) -> str:
        """
        Ensure credential exists, generate password if missing.

        Args:
            path: Secret path
            username: Username

        Returns:
            Password (existing or newly generated)
        """
        try:
            # Try to fetch existing password
            password = await self.fetch_secret(path, "password")
            logger.debug("Credential already exists", path=path)
            return password
        except Exception:
            # Generate new password and store
            from ..utils.crypto import generate_password
            password = generate_password()
            await self.store_credential(path, username, password)
            logger.info("Generated new credential", path=path)
            return password

    def _detect_mount(self, path: str) -> tuple:
        """
        Detect Vault mount point from path prefix.

        Args:
            path: Secret path (e.g., "infras/mysql/root")

        Returns:
            Tuple of (mount_point, secret_path)
        """
        parts = path.split('/', 1)

        if len(parts) < 2:
            # No mount prefix, use default
            return ("secret", path)

        mount = parts[0]

        # Known mounts
        if mount in ["infras", "apps", "secret"]:
            return (mount, parts[1])
        else:
            # Unknown mount, assume it's under 'secret'
            return ("secret", path)

    # ============================================================================
    # Policy Operations
    # ============================================================================

    async def create_app_policy(self, app_name: str) -> None:
        """
        Create read-only policy for an application.

        Policy allows reading:
        - apps/metadata/ (list)
        - apps/data/<app_name>/* (read)
        - infras/metadata/ (list)
        - infras/data/+/<app_name>/* (read)

        Args:
            app_name: Application name

        Raises:
            VaultError: If policy creation fails
        """
        policy_name = f"app-{app_name}"
        policy_hcl = self._generate_app_policy_hcl(app_name)

        logger.info("Creating app policy", app_name=app_name, policy_name=policy_name)

        try:
            self.client.sys.create_or_update_policy(
                name=policy_name,
                policy=policy_hcl
            )
            logger.info("App policy created successfully", policy_name=policy_name)
        except Exception as e:
            logger.error("Failed to create app policy", app_name=app_name, error=str(e))
            raise

    async def create_modify_policy(self, app_name: str) -> None:
        """
        Create write policy for an application.

        Policy allows writing:
        - apps/data/<app_name>/* (create, update, delete)

        Args:
            app_name: Application name

        Raises:
            VaultError: If policy creation fails
        """
        policy_name = f"modify-{app_name}"
        policy_hcl = self._generate_modify_policy_hcl(app_name)

        logger.info("Creating modify policy", app_name=app_name, policy_name=policy_name)

        try:
            self.client.sys.create_or_update_policy(
                name=policy_name,
                policy=policy_hcl
            )
            logger.info("Modify policy created successfully", policy_name=policy_name)
        except Exception as e:
            logger.error("Failed to create modify policy", app_name=app_name, error=str(e))
            raise

    def _generate_app_policy_hcl(self, app_name: str) -> str:
        """Generate HCL for read-only app policy."""
        return f'''# Allow UI to list top-level mounts (needed for Vault UI navigation)
path "apps/metadata/" {{
  capabilities = ["list"]
}}
path "infras/metadata/" {{
  capabilities = ["list"]
}}

# Allow listing and reading the specific app's secrets
path "apps/data/{app_name}" {{
  capabilities = ["read", "list"]
}}
path "apps/metadata/{app_name}" {{
  capabilities = ["read", "list"]
}}
path "apps/data/{app_name}/*" {{
  capabilities = ["read", "list"]
}}
path "apps/metadata/{app_name}/*" {{
  capabilities = ["read", "list"]
}}

# Allow reading infra secrets scoped to this app
path "infras/metadata/+/" {{
  capabilities = ["list"]
}}
path "infras/data/+/{app_name}" {{
  capabilities = ["read", "list"]
}}
path "infras/metadata/+/{app_name}" {{
  capabilities = ["read", "list"]
}}
path "infras/data/+/{app_name}/*" {{
  capabilities = ["read", "list"]
}}
path "infras/metadata/+/{app_name}/*" {{
  capabilities = ["read", "list"]
}}
'''

    def _generate_modify_policy_hcl(self, app_name: str) -> str:
        """Generate HCL for write app policy."""
        return f'''# Write access to app '{app_name}' secrets (for human users, not service tokens)
path "apps/data/{app_name}" {{
  capabilities = ["create", "update", "delete"]
}}
path "apps/data/{app_name}/*" {{
  capabilities = ["create", "update", "delete"]
}}
'''

    async def policy_exists(self, policy_name: str) -> bool:
        """
        Check if a policy exists.

        Args:
            policy_name: Policy name

        Returns:
            True if policy exists, False otherwise
        """
        try:
            self.client.sys.read_policy(name=policy_name)
            return True
        except Exception:
            return False

    # ============================================================================
    # Token Operations
    # ============================================================================

    async def create_token(
        self,
        app_name: str,
        policy_name: str,
        ttl: str = "24h"
    ) -> str:
        """
        Create a Vault token with specific policy.

        Args:
            app_name: Application name (for token metadata)
            policy_name: Policy name to attach
            ttl: Token time-to-live (default: 24h)

        Returns:
            Client token

        Raises:
            VaultError: If token creation fails
        """
        logger.info("Creating Vault token", app_name=app_name, policy=policy_name, ttl=ttl)

        try:
            response = self.client.auth.token.create(
                policies=[policy_name],
                ttl=ttl,
                renewable=True
            )

            token = response['auth']['client_token']
            logger.info("Token created successfully", app_name=app_name, token=token[:20] + "...")
            return token

        except Exception as e:
            logger.error("Failed to create token", app_name=app_name, error=str(e))
            raise

    # ============================================================================
    # User Management (userpass)
    # ============================================================================

    async def create_userpass_user(
        self,
        username: str,
        password: str,
        policies: List[str] = None
    ) -> None:
        """
        Create a Vault userpass user.

        Args:
            username: Username
            password: Password
            policies: List of policies to attach (optional)

        Raises:
            VaultError: If user creation fails
        """
        policies = policies or []

        logger.info("Creating userpass user", username=username, policies=policies)

        # Ensure userpass auth is enabled
        try:
            # Check if userpass exists
            self.client.sys.read_auth_method_mount("userpass")
        except Exception:
            # Enable userpass
            logger.info("Enabling userpass auth method")
            self.client.sys.enable_auth_method(
                method_type="userpass",
                path="userpass"
            )

        try:
            # Create or update user
            self.client.auth.userpass.create_or_update_user(
                username=username,
                password=password,
                policies=policies
            )
            logger.info("Userpass user created successfully", username=username)

        except Exception as e:
            logger.error("Failed to create userpass user", username=username, error=str(e))
            raise

    async def user_exists(self, username: str) -> bool:
        """
        Check if a userpass user exists.

        Args:
            username: Username

        Returns:
            True if user exists, False otherwise
        """
        try:
            self.client.auth.userpass.read_user(username=username)
            return True
        except Exception:
            return False

    async def list_users(self) -> list:
        """
        List userpass users with their attached policies.

        Returns:
            List of {"username": str, "policies": [str]}. Returns [] if the
            userpass auth method is absent or has no users.
        """
        try:
            resp = self.client.auth.userpass.list_user()
            usernames = resp.get("data", {}).get("keys", [])
        except Exception as e:
            logger.debug("List users returned nothing", error=str(e))
            return []

        out = []
        for u in usernames:
            policies = []
            try:
                info = self.client.auth.userpass.read_user(username=u)["data"]
                policies = info.get("token_policies") or info.get("policies") or []
            except Exception:
                pass
            out.append({"username": u, "policies": policies})
        return out

    async def assign_policies_to_user(
        self,
        username: str,
        policies: List[str]
    ) -> None:
        """
        Assign policies to a userpass user.

        Args:
            username: Username
            policies: List of policy names

        Raises:
            VaultError: If assignment fails
        """
        logger.info("Assigning policies to user", username=username, policies=policies)

        # First, fetch existing user to get current policies
        try:
            user = self.client.auth.userpass.read_user(username=username)
            existing_policies = user.get('policies', [])
        except Exception:
            existing_policies = []

        # Combine existing and new policies
        all_policies = list(set(existing_policies + policies))

        try:
            self.client.auth.userpass.create_or_update_user(
                username=username,
                policies=all_policies
            )
            logger.info("Policies assigned successfully", username=username, policies=all_policies)
        except Exception as e:
            logger.error("Failed to assign policies", username=username, error=str(e))
            raise

    async def update_user_policies(
        self,
        username: str,
        policies: List[str]
    ) -> None:
        """
        Update policies for a userpass user (alias for assign_policies_to_user).

        This method replaces all existing policies with the new list.

        Args:
            username: Username
            policies: List of policy names

        Raises:
            VaultError: If update fails
        """
        logger.info("Updating user policies", username=username, policies=policies)

        try:
            self.client.auth.userpass.create_or_update_user(
                username=username,
                password=None,  # Don't change password
                policies=policies
            )
            logger.info("User policies updated successfully", username=username, policies=policies)
        except Exception as e:
            logger.error("Failed to update user policies", username=username, error=str(e))
            raise


# Global Vault service instance
_vault_service: Optional[VaultService] = None


def get_vault_service() -> VaultService:
    """
    Get or create global Vault service instance.

    Returns:
        VaultService instance
    """
    global _vault_service
    if _vault_service is None:
        # Get Vault token from environment
        vault_token = settings.vault_token
        if not vault_token:
            # Try to get from environment variable
            import os
            vault_token = os.getenv("VAULT_TOKEN")

        if not vault_token:
            raise ValueError("VAULT_TOKEN environment variable is required")

        _vault_service = VaultService(vault_token=vault_token)
    return _vault_service
