from fastapi import APIRouter, status
from fastapi.responses import JSONResponse

from app.core.config import settings
from app.core.redis import RedisService
from app.db.session import DatabaseService

router = APIRouter()


@router.get("/health", tags=["health"])
def health_check():
    """Health check endpoint checking Database and Redis connectivity."""
    redis_alive = RedisService.check_health()
    db_alive = DatabaseService.check_health()

    is_healthy = redis_alive and db_alive

    status_code = (
        status.HTTP_200_OK if is_healthy else status.HTTP_503_SERVICE_UNAVAILABLE
    )
    return JSONResponse(
        status_code=status_code,
        content={
            "success": is_healthy,
            "statusCode": status_code,
            "message": "Service is healthy" if is_healthy else "Service is degraded",
            "errors": [],
            "data": {
                "status": "healthy" if is_healthy else "degraded",
                "database": "connected" if db_alive else "disconnected",
                "redis": "connected" if redis_alive else "disconnected",
                "environment": settings.ENVIRONMENT,
            },
        },
    )
