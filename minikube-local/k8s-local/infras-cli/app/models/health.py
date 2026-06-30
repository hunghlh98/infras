"""Pydantic models for health check operations."""

from pydantic import BaseModel, Field
from typing import Optional


class HealthResponse(BaseModel):
    """Response model for health checks.

    Attributes:
        status: Overall health status ("healthy" or "unhealthy")
        vault_connected: Whether Vault is reachable (unauthenticated health ping)
        vault_token_valid: Whether the service's Vault token actually authenticates
            (token lookup-self succeeds). None if it could not be determined.
        kubernetes_connected: Whether Kubernetes API is accessible
    """
    status: str = Field(..., description="Overall health status: healthy or unhealthy")
    vault_connected: bool = Field(..., description="Whether Vault is reachable")
    vault_token_valid: Optional[bool] = Field(
        None,
        description="Whether the service's Vault token authenticates (lookup-self). "
                    "False indicates stale/invalid credentials even if Vault is reachable.",
    )
    kubernetes_connected: bool = Field(..., description="Whether Kubernetes API is accessible")

    model_config = {
        "json_schema_extra": {
            "examples": [
                {
                    "status": "healthy",
                    "vault_connected": True,
                    "vault_token_valid": True,
                    "kubernetes_connected": True
                },
                {
                    "status": "unhealthy",
                    "vault_connected": True,
                    "vault_token_valid": False,
                    "kubernetes_connected": True
                }
            ]
        }
    }
