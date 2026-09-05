"""Router registration for the FastAPI application.

All route mounting is centralized here.
"""

from fastapi import FastAPI

from app.api.v1 import api_router
from app.core.config import settings
from app.modules.documents.router import router as documents_router
from app.routes import root_router


def setup_routers(app: FastAPI) -> None:
    """Mount all routers on the FastAPI application."""
    app.include_router(root_router)
    # Direct top-level endpoints as requested in take-home spec (/documents, /jobs)
    app.include_router(documents_router)
    app.include_router(api_router, prefix=settings.API_V1_STR)
