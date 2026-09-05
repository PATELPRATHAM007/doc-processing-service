"""Unit and integration tests for document processing service."""

from __future__ import annotations

import io
import uuid
from pathlib import Path
from typing import Any, cast
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient

from app.db.session import DatabaseService
from app.main import app
from app.modules.documents.models import (
    Document,
    DocumentStatus,
    Job,
    JobStatus,
    Result,
)
from app.services.document_processor import (
    DocumentProcessor,
    ExtractedTextResult,
    PermanentProcessingError,
    TransientProcessingError,
)
from app.services.gemini_service import set_document_processor
from app.tasks.document_tasks import process_document_task

client = TestClient(app)


class MockDocumentProcessor(DocumentProcessor):
    """Mock processor for deterministic testing without external API calls."""

    def __init__(
        self,
        text: str = "Extracted test document content.",
        provider: str = "mock-processor",
        fail_with: Exception | None = None,
    ) -> None:
        self.text = text
        self.provider = provider
        self.fail_with = fail_with
        self.call_count = 0

    def process(self, file_path: Path, content_type: str) -> ExtractedTextResult:
        self.call_count += 1
        if self.fail_with:
            raise self.fail_with
        return ExtractedTextResult(
            text=self.text,
            provider=self.provider,
            char_count=len(self.text),
            raw_metadata={"mock": True},
        )


@pytest.fixture(autouse=True)
def clean_processor():
    """Ensure document processor is reset after each test."""
    yield
    set_document_processor(None)


def test_upload_invalid_file_extension():
    """Verify that uploading files with forbidden extensions is rejected with 400."""
    file_content = b"fake binary content"
    response = client.post(
        "/api/v1/documents",
        files={
            "file": (
                "malicious.exe",
                io.BytesIO(file_content),
                "application/octet-stream",
            )
        },
    )
    assert response.status_code == 400
    body = response.json()
    assert body["success"] is False
    assert "Unsupported file extension" in body["message"]


def test_upload_invalid_mime_type():
    """Verify that uploading files with invalid MIME types is rejected with 400."""
    file_content = b"%PDF-1.4 dummy pdf header"
    response = client.post(
        "/api/v1/documents",
        files={
            "file": (
                "document.pdf",
                io.BytesIO(file_content),
                "application/x-shockwave-flash",
            )
        },
    )
    assert response.status_code == 400
    body = response.json()
    assert body["success"] is False
    assert "Unsupported content type" in body["message"]


def test_upload_empty_file():
    """Verify that uploading an empty file (0 bytes) is rejected with 400."""
    response = client.post(
        "/api/v1/documents",
        files={"file": ("empty.pdf", io.BytesIO(b""), "application/pdf")},
    )
    assert response.status_code == 400
    body = response.json()
    assert body["success"] is False
    assert "empty" in body["message"].lower()


def test_upload_valid_pdf_document():
    """Verify successful upload of a PDF document returning 202 Accepted and job_id."""
    pdf_bytes = b"%PDF-1.4 sample pdf content for unit testing"
    with patch(
        "app.modules.documents.router.process_document_task.delay"
    ) as mock_delay:
        response = client.post(
            "/api/v1/documents",
            files={
                "file": ("sample_test.pdf", io.BytesIO(pdf_bytes), "application/pdf")
            },
        )
        assert response.status_code == 202
        body = response.json()
        assert body["success"] is True
        data = body["data"]
        assert data["filename"] == "sample_test.pdf"
        assert data["content_type"] == "application/pdf"
        assert data["status"] == "uploaded"
        assert data["document_id"].startswith("doc_")
        assert data["job_id"].startswith("job_")
        mock_delay.assert_called_once_with(job_id=data["job_id"])


def test_get_document_by_id_and_not_found():
    """Verify document metadata lookup and 404 response for missing document."""
    pdf_bytes = b"%PDF-1.4 metadata test"
    with patch("app.modules.documents.router.process_document_task.delay"):
        upload_resp = client.post(
            "/api/v1/documents",
            files={
                "file": ("metadata_doc.pdf", io.BytesIO(pdf_bytes), "application/pdf")
            },
        )
        doc_id = upload_resp.json()["data"]["document_id"]

    # Valid lookup
    get_resp = client.get(f"/api/v1/documents/{doc_id}")
    assert get_resp.status_code == 200
    doc_data = get_resp.json()["data"]
    assert doc_data["id"] == doc_id
    assert doc_data["filename"] == "metadata_doc.pdf"
    assert len(doc_data["jobs"]) >= 1

    # Missing lookup
    missing_resp = client.get("/api/v1/documents/doc_nonexistent_id")
    assert missing_resp.status_code == 404


def test_get_job_status_and_in_progress_result():
    """Verify job status lookup and 202 response when checking result of pending job."""
    png_bytes = b"\x89PNG\r\n\x1a\n fake image content"
    with patch("app.modules.documents.router.process_document_task.delay"):
        upload_resp = client.post(
            "/api/v1/documents",
            files={"file": ("image.png", io.BytesIO(png_bytes), "image/png")},
        )
        job_id = upload_resp.json()["data"]["job_id"]

    # Job status
    job_resp = client.get(f"/api/v1/jobs/{job_id}")
    assert job_resp.status_code == 200
    job_data = job_resp.json()["data"]
    assert job_data["id"] == job_id
    assert job_data["status"] == "queued"

    # Job result while still queued/processing
    result_resp = client.get(f"/api/v1/jobs/{job_id}/result")
    assert result_resp.status_code == 202
    resp_body = result_resp.json()
    msg = resp_body.get("message") or (resp_body.get("data") or {}).get("message", "")
    assert "still in progress" in msg.lower()


def test_task_execution_success_and_result_retrieval():
    """Verify full asynchronous worker execution flow with mock processor and result retrieval."""
    unique_marker = uuid.uuid4().hex
    content = f"%PDF-1.4 worker flow test content {unique_marker}".encode()
    with patch("app.modules.documents.router.process_document_task.delay"):
        upload_resp = client.post(
            "/api/v1/documents",
            files={"file": ("flow_doc.pdf", io.BytesIO(content), "application/pdf")},
        )
        data = upload_resp.json()["data"]
        doc_id = data["document_id"]
        job_id = data["job_id"]

    mock_text = "Successfully extracted text from document using mock processor."
    mock_processor = MockDocumentProcessor(text=mock_text, provider="mock-gemini-v2")
    set_document_processor(mock_processor)

    # Run the task synchronously
    task_res = cast(Any, process_document_task).apply(args=[job_id]).get()
    assert task_res["status"] == "completed"
    assert task_res["char_count"] == len(mock_text)
    assert task_res["provider"] == "mock-gemini-v2"

    # Verify database state
    db = DatabaseService.get_session()
    try:
        db_job = db.query(Job).filter(Job.id == job_id).first()
        assert db_job is not None
        assert db_job.status == JobStatus.COMPLETED
        assert db_job.attempts == 1
        assert db_job.completed_at is not None

        db_doc = db.query(Document).filter(Document.id == doc_id).first()
        assert db_doc is not None
        assert db_doc.status == DocumentStatus.PROCESSED

        db_result = db.query(Result).filter(Result.job_id == job_id).first()
        assert db_result is not None
        assert db_result.extracted_text == mock_text
        assert db_result.char_count == len(mock_text)
    finally:
        db.close()

    # Verify GET /api/v1/jobs/{job_id}/result returns 200 with text
    result_resp = client.get(f"/api/v1/jobs/{job_id}/result")
    assert result_resp.status_code == 200
    res_data = result_resp.json()["data"]
    assert res_data["extracted_text"] == mock_text
    assert res_data["provider"] == "mock-gemini-v2"
    assert res_data["char_count"] == len(mock_text)


def test_task_permanent_error_handling():
    """Verify that permanent errors immediately mark job and document as failed."""
    content = f"%PDF-1.4 permanent error test {uuid.uuid4().hex}".encode()
    with patch("app.modules.documents.router.process_document_task.delay"):
        upload_resp = client.post(
            "/api/v1/documents",
            files={"file": ("corrupt.pdf", io.BytesIO(content), "application/pdf")},
        )
        job_id = upload_resp.json()["data"]["job_id"]

    mock_processor = MockDocumentProcessor(
        fail_with=PermanentProcessingError("Unrecoverable corrupt document")
    )
    set_document_processor(mock_processor)

    # Task raises and fails permanently
    with pytest.raises(PermanentProcessingError):
        cast(Any, process_document_task).apply(args=[job_id]).get()

    # Verify DB state
    db = DatabaseService.get_session()
    try:
        db_job = db.query(Job).filter(Job.id == job_id).first()
        assert db_job is not None
        assert db_job.status == JobStatus.FAILED
        assert "Unrecoverable corrupt document" in (db_job.error or "")
    finally:
        db.close()

    # Result endpoint returns 400 Bad Request
    result_resp = client.get(f"/api/v1/jobs/{job_id}/result")
    assert result_resp.status_code == 400
    assert "Job processing failed" in result_resp.json()["message"]


def test_task_transient_retry_success():
    """Verify that transient errors trigger retry and job succeeds upon recovery."""
    content = f"%PDF-1.4 transient recovery test {uuid.uuid4().hex}".encode()
    with patch("app.modules.documents.router.process_document_task.delay"):
        upload_resp = client.post(
            "/api/v1/documents",
            files={
                "file": (
                    "transient_recover.pdf",
                    io.BytesIO(content),
                    "application/pdf",
                )
            },
        )
        job_id = upload_resp.json()["data"]["job_id"]

    class TransientThenSuccessProcessor(DocumentProcessor):
        def __init__(self):
            self.attempts = 0

        def process(self, file_path: Path, content_type: str) -> ExtractedTextResult:
            self.attempts += 1
            if self.attempts == 1:
                raise TransientProcessingError("Temporary 503 upstream error")
            return ExtractedTextResult(
                text="Recovered text after retry",
                provider="mock-retry-success",
                char_count=len("Recovered text after retry"),
            )

    processor = TransientThenSuccessProcessor()
    set_document_processor(processor)

    task_res = cast(Any, process_document_task).apply(args=[job_id]).get()
    assert task_res["status"] == "completed"
    assert processor.attempts == 2

    db = DatabaseService.get_session()
    try:
        db_job = db.query(Job).filter(Job.id == job_id).first()
        assert db_job is not None
        assert db_job.status == JobStatus.COMPLETED
        assert db_job.attempts == 2
    finally:
        db.close()


def test_task_transient_error_exhaustion():
    """Verify that exceeding max retries for transient errors marks job as failed."""
    content = f"%PDF-1.4 transient exhaustion test {uuid.uuid4().hex}".encode()
    with patch("app.modules.documents.router.process_document_task.delay"):
        upload_resp = client.post(
            "/api/v1/documents",
            files={
                "file": ("transient_fail.pdf", io.BytesIO(content), "application/pdf")
            },
        )
        job_id = upload_resp.json()["data"]["job_id"]

    mock_processor = MockDocumentProcessor(
        fail_with=TransientProcessingError("429 Too Many Requests rate limit")
    )
    set_document_processor(mock_processor)

    with pytest.raises(TransientProcessingError):
        cast(Any, process_document_task).apply(args=[job_id]).get()

    # Check job updated with max retries exceeded and status FAILED
    db = DatabaseService.get_session()
    try:
        db_job = db.query(Job).filter(Job.id == job_id).first()
        assert db_job is not None
        assert db_job.status == JobStatus.FAILED
        assert db_job.attempts == 3
        assert "Max retries exceeded" in (db_job.error or "")
    finally:
        db.close()


def test_document_deduplication():
    """Verify that identical file uploads reuse cached extraction results without reprocessing."""
    marker = uuid.uuid4().hex
    identical_content = (
        f"%PDF-1.4 identical document for deduplication test {marker}".encode()
    )
    mock_processor = MockDocumentProcessor(text="Original extracted text from file 1")
    set_document_processor(mock_processor)

    # Upload document 1
    with patch("app.modules.documents.router.process_document_task.delay"):
        doc1_resp = client.post(
            "/api/v1/documents",
            files={
                "file": (
                    "doc_first.pdf",
                    io.BytesIO(identical_content),
                    "application/pdf",
                )
            },
        )
        job1_id = doc1_resp.json()["data"]["job_id"]

    # Process document 1
    cast(Any, process_document_task).apply(args=[job1_id]).get()
    assert mock_processor.call_count == 1

    # Upload identical document 2
    with patch("app.modules.documents.router.process_document_task.delay"):
        doc2_resp = client.post(
            "/api/v1/documents",
            files={
                "file": (
                    "doc_second.pdf",
                    io.BytesIO(identical_content),
                    "application/pdf",
                )
            },
        )
        job2_id = doc2_resp.json()["data"]["job_id"]

    # Process document 2
    res2 = cast(Any, process_document_task).apply(args=[job2_id]).get()
    assert res2["cached"] is True
    # Processor call_count should STILL be 1 because it reused cached result!
    assert mock_processor.call_count == 1


def test_task_authentication_failure_is_permanent():
    """Verify that a 401 unauthenticated error fails immediately without retrying."""
    content = f"%PDF-1.4 auth fail test {uuid.uuid4().hex}".encode()
    with patch("app.modules.documents.router.process_document_task.delay"):
        upload_resp = client.post(
            "/api/v1/documents",
            files={"file": ("auth_fail.pdf", io.BytesIO(content), "application/pdf")},
        )
        job_id = upload_resp.json()["data"]["job_id"]

    mock_processor = MockDocumentProcessor(
        fail_with=PermanentProcessingError(
            "Gemini authentication failed (401): Invalid API key or credentials. Please check GEMINI_API_KEY in .env."
        )
    )
    set_document_processor(mock_processor)

    with pytest.raises(PermanentProcessingError):
        cast(Any, process_document_task).apply(args=[job_id]).get()

    db = DatabaseService.get_session()
    try:
        db_job = db.query(Job).filter(Job.id == job_id).first()
        assert db_job is not None
        assert db_job.status == JobStatus.FAILED
        assert db_job.attempts == 1  # Exactly 1 attempt - NO RETRIES!
        assert "Invalid API key" in (db_job.error or "")
    finally:
        db.close()


def test_non_v1_endpoints_are_not_found():
    """Verify that old top-level endpoints without /api/v1 prefix return 404 Not Found."""
    assert client.post("/documents").status_code == 404
    assert client.get("/documents/doc_dummy").status_code == 404
    assert client.get("/jobs/job_dummy").status_code == 404
    assert client.get("/jobs/job_dummy/result").status_code == 404
    assert client.get("/health").status_code == 404
