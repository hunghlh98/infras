"""Configuration settings using Pydantic."""

from pydantic_settings import BaseSettings
from typing import Optional


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    # Vault Configuration
    vault_addr: str = "http://vault.infras-vault.svc.cluster.local:8200"
    vault_token: str = ""

    # Application Settings
    log_level: str = "INFO"
    log_format: str = "json"  # json or console
    max_retries: int = 3
    retry_delay: int = 1

    # Metrics Configuration
    metrics_enabled: bool = True
    metrics_path: str = "/metrics"

    # Service Connection Settings (for reference, actual connections via kubectl exec)
    mysql_host: str = "mysql.infras-mysql.svc.cluster.local"
    mysql_port: int = 3306
    postgres_host: str = "postgres.infras-postgres.svc.cluster.local"
    postgres_port: int = 5432
    redis_host: str = "redis-0.redis-headless.infras-redis.svc.cluster.local"
    redis_port: int = 6379
    kafka_bootstrap_servers: str = "kafka-0.kafka-headless.infras-kafka.svc.cluster.local:29092"
    keycloak_host: str = "keycloak.infras-keycloak.svc.cluster.local"
    keycloak_port: int = 8080
    minio_endpoint: str = "minio.infras-minio.svc.cluster.local:80"
    minio_secure: bool = False

    class Config:
        env_file = ".env"
        case_sensitive = False
        extra = "ignore"


# Global settings instance
settings = Settings()
