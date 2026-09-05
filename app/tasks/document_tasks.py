"""Celery background tasks for document text extraction and OCR."""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from celery import Task

from app.core.celery_app import celery_app
from app.core.config import settings
from app.db.session import DatabaseService
from app.modules.documents.models import (
    Document,
    DocumentStatus,
    Job,
    JobStatus,
    Result,
)
from app.services.document_processor import (
    PermanentProcessingError,
    TransientProcessingError,
)
from app.services.gemini_service import get_document_processor
from logger_manager import LoggerManager

task_logger = LoggerManager(folder_name="celery")


@celery_app.task(
    bind=True,
    max_retries=2,
    default_retry_delay=5,
    name="app.tasks.document_tasks.process_document_task",
)
def process_document_task(self: Task, job_id: str) -> dict[str, Any]:
    """Background task to extract text from a document using the configured DocumentProcessor.

    Handles retries for transient errors (up to 3 total attempts) with exponential backoff.
    Permanent errors immediately mark the job and document as failed without retrying.
    """
    task_logger.info(
        "Celery worker received document processing task (job_id=%s, attempt=%d/%d)",
        job_id,
        self.request.retries + 1,
        self.max_retries + 1,
    )

    db = DatabaseService.get_session()
    try:
        query = db.query(Job).filter(Job.id == job_id)
        if not settings.DATABASE_URL.startswith("sqlite"):
            query = query.with_for_update()
        job = query.first()

        if not job:
            task_logger.error("Job record not found for id: %s", job_id)
            raise PermanentProcessingError(f"Job not found: {job_id}")

        # Idempotency check: if job already succeeded, return immediately
        if job.status == JobStatus.COMPLETED:
            task_logger.info("Job %s is already completed. Skipping redundant processing.", job_id)
            return {
                "job_id": job.id,
                "document_id": job.document_id,
                "status": job.status,
                "attempts": job.attempts,
            }

        # Transition job and document to processing state
        job.status = JobStatus.PROCESSING
        job.attempts += 1
        if not job.started_at:
            job.started_at = datetime.now(timezone.utc)

        document = db.query(Document).filter(Document.id == job.document_id).first()
        if not document:
            err_msg = f"Document not found for id: {job.document_id}"
            task_logger.error(err_msg)
            job.status = JobStatus.FAILED
            job.completed_at = datetime.now(timezone.utc)
            job.error = err_msg
            db.commit()
            raise PermanentProcessingError(err_msg)

        document.status = DocumentStatus.PROCESSING
        db.commit()

        # Check if identical document content was already processed successfully (deduplication)
        cached_result = (
            db.query(Result)
            .join(Document, Result.document_id == Document.id)
            .filter(
                Document.file_hash == document.file_hash,
                Document.id != document.id,
                Document.status == DocumentStatus.PROCESSED,
            )
            .first()
        )

        if cached_result:
            task_logger.info(
                "Document %s matched existing hash %s; reusing cached extraction result from document %s",
                document.id,
                document.file_hash,
                cached_result.document_id,
            )
            existing_result = db.query(Result).filter(Result.job_id == job.id).first()
            if existing_result:
                existing_result.extracted_text = cached_result.extracted_text
                existing_result.char_count = cached_result.char_count
                existing_result.provider = f"{cached_result.provider} (deduplicated)"
            else:
                result = Result(
                    job_id=job.id,
                    document_id=document.id,
                    extracted_text=cached_result.extracted_text,
                    provider=f"{cached_result.provider} (deduplicated)",
                    char_count=cached_result.char_count,
                )
                db.add(result)

            job.status = JobStatus.COMPLETED
            job.completed_at = datetime.now(timezone.utc)
            job.error = None
            document.status = DocumentStatus.PROCESSED
            db.commit()

            return {
                "job_id": job.id,
                "document_id": document.id,
                "status": job.status,
                "char_count": cached_result.char_count,
                "provider": f"{cached_result.provider} (deduplicated)",
                "attempts": job.attempts,
                "cached": True,
            }

        # Execute OCR / document processing
        file_path = Path(document.file_path)
        processor = get_document_processor()
        task_logger.info(
            "Starting extraction for document %s (file=%s, type=%s, size=%d bytes)",
            document.id,
            document.filename,
            document.content_type,
            document.size_bytes,
        )

        extracted = processor.process(file_path=file_path, content_type=document.content_type)

        # Persist result idempotently
        existing_result = db.query(Result).filter(Result.job_id == job.id).first()
        if existing_result:
            existing_result.extracted_text = extracted.text
            existing_result.char_count = extracted.char_count
            existing_result.provider = extracted.provider
        else:
            result = Result(
                job_id=job.id,
                document_id=document.id,
                extracted_text=extracted.text,
                provider=extracted.provider,
                char_count=extracted.char_count,
            )
            db.add(result)

        job.status = JobStatus.COMPLETED
        job.completed_at = datetime.now(timezone.utc)
        job.error = None
        document.status = DocumentStatus.PROCESSED
        db.commit()

        task_logger.info(
            "Job %s completed successfully (document_id=%s, chars=%d, attempts=%d)",
            job.id,
            document.id,
            extracted.char_count,
            job.attempts,
        )

        return {
            "job_id": job.id,
            "document_id": document.id,
            "status": job.status,
            "char_count": extracted.char_count,
            "provider": extracted.provider,
            "attempts": job.attempts,
        }

    except TransientProcessingError as exc:
        task_logger.warning(
            "Transient error in job %s (attempt %d/%d): %s",
            job_id,
            self.request.retries + 1,
            self.max_retries + 1,
            exc,
        )
        if self.request.retries < self.max_retries:
            countdown = min(300, (2**self.request.retries) * 5)
            job = db.query(Job).filter(Job.id == job_id).first()
            if job:
                job.error = f"Transient failure (retry in {countdown}s): {exc}"
                db.commit()
            raise self.retry(exc=exc, countdown=countdown) from exc

        # All retries exhausted
        task_logger.error("Job %s exhausted all %d retries: %s", job_id, self.max_retries + 1, exc)
        job = db.query(Job).filter(Job.id == job_id).first()
        if job:
            job.status = JobStatus.FAILED
            job.completed_at = datetime.now(timezone.utc)
            job.error = f"Max retries exceeded ({self.max_retries + 1} attempts): {exc}"
        doc = db.query(Document).filter(Document.id == (job.document_id if job else "")).first()
        if doc:
            doc.status = DocumentStatus.FAILED
        db.commit()
        raise

    except (PermanentProcessingError, Exception) as exc:
        task_logger.error("Permanent failure in job %s: %s", job_id, exc)
        job = db.query(Job).filter(Job.id == job_id).first()
        if job:
            job.status = JobStatus.FAILED
            job.completed_at = datetime.now(timezone.utc)
            job.error = str(exc)
        doc = db.query(Document).filter(Document.id == (job.document_id if job else "")).first()
        if doc:
            doc.status = DocumentStatus.FAILED
        db.commit()
        raise

    finally:
        db.close()
