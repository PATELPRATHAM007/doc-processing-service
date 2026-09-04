from fastapi import APIRouter

from app.api.v1.endpoints import health

api_router = APIRouter()

# Health check endpoints
api_router.include_router(health.router)
