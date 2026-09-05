from fastapi import APIRouter

from app.api.v1.endpoints import health
from app.modules.documents.router import router as documents_router

api_router = APIRouter()

# Health check endpoints
api_router.include_router(health.router)
api_router.include_router(documents_router)
