"""Celery background tasks package."""

from app.tasks.document_tasks import process_document_task

__all__ = ["process_document_task"]
