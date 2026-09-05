"""Central Celery application configuration."""

from celery import Celery

from app.core.config import settings
from logger_manager import LoggerManager

celery_logger = LoggerManager(folder_name="celery")

celery_app = Celery(
    "doc_processing_service",
    broker=settings.celery_broker,
    backend=settings.celery_backend,
)

celery_app.conf.update(
    task_default_queue=settings.QUEUE_NAME,
    task_serializer="json",
    result_serializer="json",
    accept_content=["json"],
    timezone="UTC",
    enable_utc=True,
    task_acks_late=True,
    task_reject_on_worker_lost=True,
    worker_prefetch_multiplier=1,
    broker_connection_retry_on_startup=True,
)

celery_app.autodiscover_tasks(["app.tasks", "app.modules.documents"])

# Ensure tasks are registered immediately on module load
import app.tasks.document_tasks  # noqa: F401
