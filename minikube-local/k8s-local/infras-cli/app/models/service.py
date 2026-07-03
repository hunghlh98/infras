"""Pydantic models for ACL setup and verification operations."""

from pydantic import BaseModel, Field
from typing import Optional, Dict, Any


class ACLSetupRequest(BaseModel):
    """Request model for ACL setup.

    Attributes:
        service_name: Name of the service to create ACL for
        infra_type: Infrastructure type (mysql, postgres, redis, kafka, keycloak)
        owner_username: Owner username (required for keycloak, optional for others)
    """
    service_name: str = Field(..., description="Name of the service", min_length=1)
    infra_type: str = Field(..., description="Infrastructure type: mysql, postgres, redis, kafka, keycloak, minio")
    owner_username: Optional[str] = Field(None, description="Owner username (required for keycloak)")

    model_config = {
        "json_schema_extra": {
            "examples": [
                {
                    "service_name": "myapp",
                    "infra_type": "mysql"
                },
                {
                    "service_name": "myapp",
                    "infra_type": "keycloak",
                    "owner_username": "myrealm"
                }
            ]
        }
    }


class ACLSetupResponse(BaseModel):
    """Response model for ACL setup.

    Attributes:
        success: Whether the ACL was created successfully
        message: Human-readable message describing the result
        vault_path: Path where credentials are stored in Vault
        connection_details: Dictionary with connection information (host, port, username, etc.)
        token: Vault token for accessing the credential (optional)
    """
    success: bool = Field(..., description="Whether the operation was successful")
    message: str = Field(..., description="Human-readable message")
    vault_path: str = Field(..., description="Vault path where credentials are stored")
    connection_details: Dict[str, Any] = Field(..., description="Connection information")
    token: Optional[str] = Field(None, description="Vault token for credential access")


class ACLVerifyRequest(BaseModel):
    """Request model for ACL verification.

    Attributes:
        service_name: Name of the service to verify
        infra_type: Infrastructure type
        owner_username: Owner username (required for keycloak verification)
    """
    service_name: str = Field(..., description="Name of the service", min_length=1)
    infra_type: str = Field(..., description="Infrastructure type")
    owner_username: Optional[str] = Field(None, description="Owner username (required for keycloak)")


class ACLVerifyResponse(BaseModel):
    """Response model for ACL verification.

    Attributes:
        success: Whether the ACL exists and is valid
        message: Human-readable verification result
    """
    success: bool = Field(..., description="Whether the ACL exists and is valid")
    message: str = Field(..., description="Verification result message")
