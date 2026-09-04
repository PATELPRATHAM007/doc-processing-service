from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # App settings
    PROJECT_NAME: str = "Async Document Processing Service"
    API_V1_STR: str = "/api/v1"
    VERSION: str = "0.1.0"
    ENVIRONMENT: str = "development"
    DEBUG: bool = True
    HOST: str = "0.0.0.0"
    PORT: int = 8000

    # Allowed Hosts & CORS
    ALLOWED_HOSTS: str = "*"
    BACKEND_CORS_ORIGINS: str = "*"
    CORS_ALLOW_CREDENTIALS: bool = True
    CORS_ALLOW_METHODS: str = "*"
    CORS_ALLOW_HEADERS: str = "*"

    # PostgreSQL Database
    DATABASE_URL: str = (
        "postgresql+psycopg2://postgres:postgres@localhost:5432/doc_processing_db"
    )
    DB_POOL_SIZE: int = 20
    DB_MAX_OVERFLOW: int = 10

    # Redis Broker
    REDIS_URL: str = "redis://localhost:6379/0"
    QUEUE_NAME: str = "document_processing_queue"

    @property
    def allowed_hosts_list(self) -> list[str]:
        if not self.ALLOWED_HOSTS or self.ALLOWED_HOSTS == "*":
            return ["*"]
        return [h.strip() for h in self.ALLOWED_HOSTS.split(",") if h.strip()]

    @property
    def cors_origins_list(self) -> list[str]:
        if not self.BACKEND_CORS_ORIGINS or self.BACKEND_CORS_ORIGINS == "*":
            return ["*"]
        return [i.strip() for i in self.BACKEND_CORS_ORIGINS.split(",") if i.strip()]

    @property
    def cors_methods_list(self) -> list[str]:
        if self.CORS_ALLOW_METHODS == "*":
            return ["*"]
        return [i.strip() for i in self.CORS_ALLOW_METHODS.split(",") if i.strip()]

    @property
    def cors_headers_list(self) -> list[str]:
        if self.CORS_ALLOW_HEADERS == "*":
            return ["*"]
        return [i.strip() for i in self.CORS_ALLOW_HEADERS.split(",") if i.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
