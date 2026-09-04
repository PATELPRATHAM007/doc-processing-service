from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.trustedhost import TrustedHostMiddleware

from app.core.config import settings
from app.core.middleware import RequestContextMiddleware, StandardResponseMiddleware


def setup_middleware(app: FastAPI) -> None:
    """Configure all middleware for the FastAPI application."""
    # Trusted Host Middleware - Protects against Host Header attacks
    app.add_middleware(
        TrustedHostMiddleware,
        allowed_hosts=settings.allowed_hosts_list,
    )

    # CORS Middleware - Handles Cross-Origin Resource Sharing
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins_list,
        allow_credentials=settings.CORS_ALLOW_CREDENTIALS,
        allow_methods=settings.cors_methods_list,
        allow_headers=settings.cors_headers_list,
    )

    # Custom Standard Response Middleware
    app.add_middleware(StandardResponseMiddleware)

    # Add as the outermost middleware.
    # Sets request ID/user context and logs all API requests and unhandled exceptions.
    app.add_middleware(RequestContextMiddleware)
