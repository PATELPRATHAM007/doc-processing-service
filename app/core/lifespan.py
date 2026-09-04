import time
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.core.database import DatabaseService
from app.core.logging_config import adopt_foreign_loggers, get_logger
from app.core.redis import RedisService
from app.core.startup import log_ready, log_startup_report

logger = get_logger("system")


@asynccontextmanager
async def lifespan(app: FastAPI):
    """FastAPI lifespan context manager for startup and shutdown events."""
    startup_began_at = time.perf_counter()
    adopt_foreign_loggers()

    # 1. Structured startup report
    log_startup_report(app)

    # 2. Ready notification
    log_ready(startup_began_at)

    yield

    # Shutdown logic
    logger.info("Shutting down application: %s", app.title)
    DatabaseService.close()
    RedisService.close()
