"""Pydantic schemas for document and job API requests and responses."""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field


class JobSummary(BaseModel):
    """Concise representation of a processing job."""

    model_config = ConfigDict(from_attributes=True)

    id: str
    status: str
    attempts: int
    error: str | None = None
    created_at: datetime
    started_at: datetime | None = None
    completed_at: datetime | None = None


class DocumentUploadResponse(BaseModel):
    """Response returned upon successful document upload and task enqueue."""

    model_config = ConfigDict(from_attributes=True)

    document_id: str = Field(..., description="Unique document identifier")
    filename: str = Field(..., description="Original filename")
    content_type: str = Field(..., description="MIME content type")
    size_bytes: int = Field(..., description="File size in bytes")
    status: str = Field(..., description="Document processing status")
    job_id: str = Field(..., description="ID of the background processing job")
    message: str = Field(
        default="Document uploaded and queued for processing.",
        description="Informational status message",
    )
    created_at: datetime


class DocumentResponse(BaseModel):
    """Detailed document record including associated processing jobs."""

    model_config = ConfigDict(from_attributes=True)

    id: str
    filename: str
    content_type: str
    size_bytes: int
    file_hash: str
    status: str
    created_at: datetime
    updated_at: datetime
    jobs: list[JobSummary] = Field(default_factory=list)


class JobResponse(BaseModel):
    """Processing job status details."""

    model_config = ConfigDict(from_attributes=True)

    id: str
    document_id: str
    status: str
    attempts: int
    error: str | None = None
    created_at: datetime
    started_at: datetime | None = None
    completed_at: datetime | None = None


class ResultResponse(BaseModel):
    """Extracted text output of a completed processing job."""

    model_config = ConfigDict(from_attributes=True)

    job_id: str
    document_id: str
    status: str
    provider: str
    char_count: int
    extracted_text: str
    created_at: datetime
