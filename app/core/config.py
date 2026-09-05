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

    # Redis Broker & Celery
    REDIS_URL: str = "redis://localhost:6379/0"
    QUEUE_NAME: str = "document_processing_queue"
    CELERY_BROKER_URL: str = ""
    CELERY_RESULT_BACKEND: str = ""

    # Document Upload & Storage
    UPLOAD_DIR: str = "uploads"
    MAX_UPLOAD_SIZE_BYTES: int = 10 * 1024 * 1024  # 10 MiB
    ALLOWED_EXTENSIONS: set[str] = {
        "pdf",
        "png",
        "jpg",
        "jpeg",
        "webp",
        "tiff",
        "bmp",
    }
    ALLOWED_MIME_TYPES: set[str] = {
        "application/pdf",
        "image/png",
        "image/jpeg",
        "image/webp",
        "image/tiff",
        "image/bmp",
    }

    # Google Gemini OCR Provider
    GEMINI_API_KEY: str = ""
    GEMINI_MODEL: str = "gemini-3.6-flash"

    @property
    def celery_broker(self) -> str:
        return self.CELERY_BROKER_URL or self.REDIS_URL

    @property
    def celery_backend(self) -> str:
        return self.CELERY_RESULT_BACKEND or self.REDIS_URL

    @property
    def upload_path(self):
        from pathlib import Path

        root = Path(__file__).resolve().parent.parent.parent
        target = root / self.UPLOAD_DIR
        target.mkdir(parents=True, exist_ok=True)
        return target

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
