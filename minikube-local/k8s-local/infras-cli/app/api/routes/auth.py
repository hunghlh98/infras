"""Authentication endpoints backed by Vault userpass.

The UI authenticates operators against the *same* Vault that the rest of the
service already uses. Login performs a Vault `userpass` login and returns the
resulting client token; protected endpoints then require that token in the
`Authorization: Bearer <token>` header and validate it via token lookup-self.

Note: infrastructure operations still execute server-side with the service's
configured (root) token. Login here is an access gate for the UI/API, not a
re-scoping of what the operations themselves are allowed to do.
"""

from fastapi import APIRouter, HTTPException, status, Header, Depends
from pydantic import BaseModel, Field
from typing import Optional
import structlog

from hvac import Client as VaultClient

from app.config import settings

logger = structlog.get_logger(__name__)
router = APIRouter()


class LoginRequest(BaseModel):
    """Login request using Vault userpass credentials."""
    username: str = Field(..., description="Vault userpass username", min_length=1)
    password: str = Field(..., description="Vault userpass password", min_length=1)


@router.post("/login")
async def login(request: LoginRequest):
    """
    Authenticate an operator against Vault (userpass) and return a token.

    Returns the Vault client token plus its attached policies and lease
    duration. The UI stores the token and presents it on subsequent calls.
    """
    client = VaultClient(url=settings.vault_addr)

    try:
        resp = client.auth.userpass.login(
            username=request.username,
            password=request.password,
            use_token=False,
        )
        auth = resp["auth"]
        token = auth["client_token"]

        logger.info("Operator logged in", username=request.username)

        return {
            "success": True,
            "username": request.username,
            "token": token,
            "policies": auth.get("policies", []),
            "lease_duration": auth.get("lease_duration", 0),
            "renewable": auth.get("renewable", False),
        }
    except HTTPException:
        raise
    except Exception as e:
        logger.warning("Login failed", username=request.username, error=str(e))
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid username or password",
        )


async def require_auth(authorization: Optional[str] = Header(None)) -> dict:
    """
    FastAPI dependency: require a valid Vault token.

    Reads the `Authorization: Bearer <token>` header and validates the token
    via Vault token lookup-self. Returns the token's identity info on success.
    """
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing or invalid Authorization header",
            headers={"WWW-Authenticate": "Bearer"},
        )

    token = authorization.split(" ", 1)[1].strip()
    client = VaultClient(url=settings.vault_addr, token=token)

    try:
        info = client.auth.token.lookup_self()
        data = info["data"]
        return {
            "token": token,
            "display_name": data.get("display_name"),
            "policies": data.get("policies", []),
            "ttl": data.get("ttl"),
        }
    except Exception as e:
        logger.warning("Token validation failed", error=str(e))
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired token",
            headers={"WWW-Authenticate": "Bearer"},
        )


@router.get("/me")
async def me(identity: dict = Depends(require_auth)):
    """Return the identity tied to the presented token (for session checks)."""
    return {
        "display_name": identity.get("display_name"),
        "policies": identity.get("policies", []),
        "ttl": identity.get("ttl"),
    }
