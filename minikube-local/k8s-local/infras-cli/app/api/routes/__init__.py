"""FastAPI route modules."""

from fastapi import APIRouter, Depends
from .health import router as health_router
from .acl import router as acl_router
from .users import router as users_router
from .auth import router as auth_router, require_auth

# Create main API router
api_router = APIRouter()

# Public routes: health probes (used by k8s) and login.
api_router.include_router(health_router, prefix="/health", tags=["Health"])
api_router.include_router(auth_router, prefix="/auth", tags=["Auth"])

# Protected routes: require a valid Vault token (Authorization: Bearer <token>).
api_router.include_router(
    acl_router, prefix="/acl", tags=["ACL"], dependencies=[Depends(require_auth)]
)
api_router.include_router(
    users_router, prefix="/users", tags=["Users"], dependencies=[Depends(require_auth)]
)

__all__ = ["api_router"]
