"""FastAPI router for documents and asynchronous processing jobs."""

from __future__ import annotations

import hashlib
import uuid
from pathlib import Path
from typing import Annotated, Any

from fastapi import APIRouter, Depends, File, HTTPException, Query, UploadFile, status
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session

from app.core.config import settings
from app.db.session import get_db
from app.modules.documents.models import (
    Document,
    DocumentStatus,
    Job,
    JobStatus,
    Result,
)
from app.modules.documents.schemas import (
    DocumentResponse,
    DocumentUploadResponse,
    JobResponse,
    ResultResponse,
)
from app.tasks.document_tasks import process_document_task
from logger_manager import LoggerManager

api_logger = LoggerManager(folder_name="api")

router = APIRouter(tags=["documents"])


@router.post(
    "/documents",
    response_model=DocumentUploadResponse,
    status_code=status.HTTP_202_ACCEPTED,
    summary="Upload a document for asynchronous processing",
)
async def upload_document(
    file: Annotated[UploadFile, File(description="PDF or image file to extract text from")],
    db: Annotated[Session, Depends(get_db)],
) -> Any:
    """Accept a document upload, persist metadata, create a processing job,

    and dispatch an asynchronous extraction task to Celery workers.
    """
    api_logger.info("Received document upload request (filename=%s)", file.filename)

    if not file.filename:
        api_logger.warning("Upload rejected: filename is empty")
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Uploaded file must have a valid filename.",
        )

    # Validate file extension
    raw_ext = Path(file.filename).suffix.lower()
    ext = raw_ext.lstrip(".")
    if not ext or ext not in settings.ALLOWED_EXTENSIONS:
        allowed = ", ".join(sorted(settings.ALLOWED_EXTENSIONS))
        api_logger.warning(
            "Upload rejected: unsupported extension '%s' (filename=%s)",
            raw_ext,
            file.filename,
        )
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unsupported file extension '{raw_ext}'. Allowed: {allowed}",
        )

    # Validate MIME type
    content_type = file.content_type or "application/octet-stream"
    if content_type not in settings.ALLOWED_MIME_TYPES:
        allowed_mimes = ", ".join(sorted(settings.ALLOWED_MIME_TYPES))
        api_logger.warning(
            "Upload rejected: unsupported MIME type '%s' (filename=%s)",
            content_type,
            file.filename,
        )
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unsupported content type '{content_type}'. Allowed: {allowed_mimes}",
        )

    # Stream file to disk while calculating SHA-256 and checking file size
    doc_id = f"doc_{uuid.uuid4().hex[:12]}"
    upload_dir = settings.upload_path
    upload_dir.mkdir(parents=True, exist_ok=True)
    destination_path = upload_dir / f"{doc_id}{raw_ext}"

    hasher = hashlib.sha256()
    total_bytes = 0
    chunk_size = 64 * 1024  # 64 KB

    try:
        with destination_path.open("wb") as out_file:
            while chunk := await file.read(chunk_size):
                total_bytes += len(chunk)
                if total_bytes > settings.MAX_UPLOAD_SIZE_BYTES:
                    destination_path.unlink(missing_ok=True)
                    max_mb = settings.MAX_UPLOAD_SIZE_BYTES / (1024 * 1024)
                    api_logger.warning(
                        "Upload rejected: size exceeds limit (bytes=%d, max=%.1fMB)",
                        total_bytes,
                        max_mb,
                    )
                    raise HTTPException(
                        status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                        detail=f"File size exceeds maximum allowed limit of {max_mb:.0f} MB.",
                    )
                hasher.update(chunk)
                out_file.write(chunk)
    except HTTPException:
        raise
    except Exception as exc:
        destination_path.unlink(missing_ok=True)
        api_logger.error("Failed to save uploaded file: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to persist uploaded document file to storage.",
        ) from exc

    if total_bytes == 0:
        destination_path.unlink(missing_ok=True)
        api_logger.warning("Upload rejected: file is 0 bytes")
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Uploaded file is empty (0 bytes).",
        )

    file_hash = hasher.hexdigest()
    api_logger.info(
        "File stored successfully (doc_id=%s, size=%d bytes, hash=%s)",
        doc_id,
        total_bytes,
        file_hash,
    )

    # Create Document record
    document = Document(
        id=doc_id,
        filename=file.filename,
        file_path=str(destination_path),
        content_type=content_type,
        size_bytes=total_bytes,
        file_hash=file_hash,
        status=DocumentStatus.UPLOADED,
    )
    db.add(document)

    # Create Job record
    job_id = f"job_{uuid.uuid4().hex[:12]}"
    job = Job(
        id=job_id,
        document_id=doc_id,
        status=JobStatus.QUEUED,
        attempts=0,
    )
    db.add(job)
    db.commit()
    db.refresh(document)
    db.refresh(job)

    # Dispatch Celery background task
    try:
        process_document_task.delay(job_id=job.id)
        api_logger.info("Dispatched Celery task for job_id=%s", job.id)
    except Exception as exc:
        api_logger.error("Failed to enqueue Celery task for job_id=%s: %s", job.id, exc)
        job.status = JobStatus.FAILED
        job.error = f"Failed to enqueue task: {exc}"
        db.commit()
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Failed to enqueue background processing job. Please retry later.",
        ) from exc

    return DocumentUploadResponse(
        document_id=document.id,
        filename=document.filename,
        content_type=document.content_type,
        size_bytes=document.size_bytes,
        status=document.status,
        job_id=job.id,
        message="Document uploaded and queued for processing.",
        created_at=document.created_at,
    )


@router.get(
    "/documents/{document_id}",
    response_model=DocumentResponse,
    summary="Get document details and processing jobs",
)
def get_document(
    document_id: str,
    db: Annotated[Session, Depends(get_db)],
) -> Any:
    """Retrieve document metadata along with all associated processing jobs."""
    document = db.query(Document).filter(Document.id == document_id).first()
    if not document:
        api_logger.warning("Document not found: %s", document_id)
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Document with id '{document_id}' not found.",
        )
    return document


@router.get(
    "/documents",
    response_model=list[DocumentResponse],
    summary="List uploaded documents",
)
def list_documents(
    db: Annotated[Session, Depends(get_db)],
    skip: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
) -> Any:
    """List documents with pagination."""
    return db.query(Document).order_by(Document.created_at.desc()).offset(skip).limit(limit).all()


@router.get(
    "/jobs/{job_id}",
    response_model=JobResponse,
    summary="Get status of a processing job",
)
def get_job_status(
    job_id: str,
    db: Annotated[Session, Depends(get_db)],
) -> Any:
    """Retrieve current status, attempt count, and error information for a job."""
    job = db.query(Job).filter(Job.id == job_id).first()
    if not job:
        api_logger.warning("Job not found: %s", job_id)
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Job with id '{job_id}' not found.",
        )
    return job


@router.get(
    "/jobs/{job_id}/result",
    response_model=ResultResponse,
    summary="Get extracted text result for a completed job",
)
def get_job_result(
    job_id: str,
    db: Annotated[Session, Depends(get_db)],
) -> Any:
    """Retrieve extracted text result.

    Returns:
    - 200 OK with extracted text if completed
    - 202 Accepted if processing is still in progress
    - 400 Bad Request if the job failed
    - 404 Not Found if the job does not exist
    """
    job = db.query(Job).filter(Job.id == job_id).first()
    if not job:
        api_logger.warning("Job not found for result request: %s", job_id)
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Job with id '{job_id}' not found.",
        )

    if job.status in (JobStatus.QUEUED, JobStatus.PROCESSING):
        return JSONResponse(
            status_code=status.HTTP_202_ACCEPTED,
            content={
                "job_id": job.id,
                "document_id": job.document_id,
                "status": job.status,
                "message": "Document processing is still in progress.",
            },
        )

    if job.status == JobStatus.FAILED:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Job processing failed: {job.error or 'Unknown error'}",
        )

    # Job is completed
    result = db.query(Result).filter(Result.job_id == job.id).first()
    if not result:
        api_logger.error("Job %s is completed but result record is missing", job_id)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Processing completed but result record could not be found.",
        )

    return ResultResponse(
        job_id=job.id,
        document_id=job.document_id,
        status=job.status,
        provider=result.provider,
        char_count=result.char_count,
        extracted_text=result.extracted_text,
        created_at=result.created_at,
    )
