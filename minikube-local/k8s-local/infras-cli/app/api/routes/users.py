"""User management endpoints for creating Vault users and assigning policies."""

from fastapi import APIRouter, HTTPException, status
from app.models import UserCreateRequest, UserCreateResponse, PolicyAssignRequest, PolicyAssignResponse
from app.services.vault_service import VaultService
from app.utils.crypto import generate_password
import structlog

logger = structlog.get_logger(__name__)
router = APIRouter()


@router.post("/", response_model=UserCreateResponse, status_code=status.HTTP_201_CREATED)
async def create_user(request: UserCreateRequest):
    """
    Create a Vault userpass user.

    Creates a new Vault user with userpass authentication method.
    The user's password is automatically generated and stored in Vault.

    Args:
        request: User creation request with username

    Returns:
        UserCreateResponse with username, vault_path, and auto-generated password

    Raises:
        HTTPException 400: Invalid username
        HTTPException 500: Internal error during user creation
    """
    try:
        logger.info("Creating Vault user", username=request.username)

        vault = VaultService()

        # Check if user already exists
        if await vault.user_exists(request.username):
            logger.warning("User already exists", username=request.username)
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"User '{request.username}' already exists"
            )

        # Generate password
        password = generate_password()

        # Create userpass user with empty policy list
        await vault.create_userpass_user(
            username=request.username,
            password=password,
            policies=[]
        )

        # Store password in Vault
        vault_path = f"infras/vault/users/{request.username}"
        await vault.store_credential(vault_path, request.username, password)

        logger.info("User created successfully", username=request.username, vault_path=vault_path)

        return UserCreateResponse(
            success=True,
            message=f"User '{request.username}' created successfully",
            username=request.username,
            vault_path=vault_path,
            password=password
        )

    except HTTPException:
        # Re-raise HTTP exceptions as-is
        raise
    except Exception as e:
        logger.error("User creation failed", username=request.username, error=str(e))
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"User creation failed: {str(e)}"
        )


@router.get("/")
async def list_users():
    """
    List all Vault userpass users with their attached policies.

    Returns:
        Dictionary with the list of users and a count.
    """
    try:
        vault = VaultService()
        users = await vault.list_users()
        return {"users": users, "count": len(users)}
    except Exception as e:
        logger.error("Failed to list users", error=str(e))
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to list users: {str(e)}"
        )


@router.post("/token", response_model=dict, status_code=status.HTTP_201_CREATED)
async def generate_token(
    app_name: str,
    policy_name: str = None,
    ttl: str = "24h"
):
    """
    Generate a Vault token for an application.

    Creates a Vault token with the specified policy.
    If the policy doesn't exist, it will be created automatically.

    Args:
        app_name: Application name
        policy_name: Policy name (default: app-<app_name>)
        ttl: Token time-to-live (default: 24h)

    Returns:
        Dictionary with app_name, policy_name, ttl, and token

    Raises:
        HTTPException 500: Internal error during token generation
    """
    try:
        logger.info("Generating token", app_name=app_name, policy_name=policy_name, ttl=ttl)

        vault = VaultService()

        # Use provided policy or default to app-<name>
        actual_policy = policy_name or f"app-{app_name}"

        # Create policy if it doesn't exist
        if not await vault.policy_exists(actual_policy):
            logger.info("Creating policy for token generation", policy_name=actual_policy)
            # Check if it's an app policy
            if actual_policy.startswith("app-"):
                name = actual_policy.replace("app-", "")
                await vault.create_app_policy(name)
            elif actual_policy.startswith("modify-"):
                name = actual_policy.replace("modify-", "")
                await vault.create_modify_policy(name)

        # Generate token
        token = await vault.create_token(
            app_name=app_name,
            policy_name=actual_policy,
            ttl=ttl
        )

        logger.info("Token generated successfully", app_name=app_name, policy_name=actual_policy)

        return {
            "success": True,
            "app_name": app_name,
            "policy_name": actual_policy,
            "ttl": ttl,
            "token": token,
            "message": f"Token generated for {app_name}"
        }

    except Exception as e:
        logger.error("Token generation failed", app_name=app_name, error=str(e))
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Token generation failed: {str(e)}"
        )


@router.post("/{username}/policies", response_model=PolicyAssignResponse, status_code=status.HTTP_201_CREATED)
async def assign_policy(username: str, request: PolicyAssignRequest):
    """
    Assign app policies to a user.

    Creates Vault policies (app-<name> and modify-<name>) if they don't exist,
    then assigns them to the specified user.

    Args:
        username: Username to assign policies to
        request: Policy assignment request with app_name

    Returns:
        PolicyAssignResponse with username and list of assigned policies

    Raises:
        HTTPException 400: User doesn't exist
        HTTPException 500: Internal error during policy assignment
    """
    try:
        logger.info(
            "Assigning policies to user",
            username=username,
            app_name=request.app_name
        )

        vault = VaultService()

        # Check if user exists
        if not await vault.user_exists(username):
            logger.warning("User not found", username=username)
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"User '{username}' not found"
            )

        # Create policies if they don't exist
        app_policy = f"app-{request.app_name}"
        modify_policy = f"modify-{request.app_name}"

        if not await vault.policy_exists(app_policy):
            logger.info("Creating app policy", app_name=request.app_name)
            await vault.create_app_policy(request.app_name)

        if not await vault.policy_exists(modify_policy):
            logger.info("Creating modify policy", app_name=request.app_name)
            await vault.create_modify_policy(request.app_name)

        # Assign policies to user
        policies = [app_policy, modify_policy]
        await vault.update_user_policies(username, policies)

        logger.info(
            "Policies assigned successfully",
            username=username,
            policies=policies
        )

        return PolicyAssignResponse(
            success=True,
            message=f"Policies assigned to '{username}'",
            username=username,
            policies=policies
        )

    except HTTPException:
        # Re-raise HTTP exceptions as-is
        raise
    except Exception as e:
        logger.error("Policy assignment failed", username=username, error=str(e))
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Policy assignment failed: {str(e)}"
        )


@router.get("/{username}", response_model=dict)
async def get_user(username: str):
    """
    Get user information including assigned policies.

    Args:
        username: Username to query

    Returns:
        Dictionary with user information

    Raises:
        HTTPException 404: User doesn't exist
        HTTPException 500: Internal error
    """
    try:
        vault = VaultService()

        # Check if user exists
        if not await vault.user_exists(username):
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"User '{username}' not found"
            )

        # Get user info
        user = vault.client.auth.userpass.read_user(username=username)

        return {
            "username": username,
            "policies": user.get("policies", []),
            "token_policies": user.get("token_policies", [])
        }

    except HTTPException:
        raise
    except Exception as e:
        logger.error("Failed to get user info", username=username, error=str(e))
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to get user info: {str(e)}"
        )
