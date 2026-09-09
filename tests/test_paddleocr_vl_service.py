"""Unit and integration tests for PaddleOCR-VL-1.6 document processor service."""

from __future__ import annotations

import io
import uuid
from pathlib import Path
from unittest.mock import MagicMock, patch

import httpx
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.core.config import settings
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
    ExtractedTextResult,
    PermanentProcessingError,
    TransientProcessingError,
    get_document_processor,
    set_document_processor,
)
from app.services.gemini_service import GeminiDocumentProcessor
from app.services.paddleocr_vl_service import PaddleOCRVLDocumentProcessor
from app.tasks.document_tasks import process_document_task

client = TestClient(app)


@pytest.fixture(autouse=True)
def reset_processor_singleton():
    """Ensure document processor singleton is cleared between tests."""
    yield
    set_document_processor(None)


def test_paddleocr_vl_initialization_defaults():
    """Verify PaddleOCRVLDocumentProcessor initializes with default settings."""
    processor = PaddleOCRVLDocumentProcessor()
    assert processor.pipeline_version == settings.PADDLEOCR_VL_PIPELINE_VERSION
    assert processor.model_name == settings.PADDLEOCR_VL_MODEL_NAME
    assert processor.backend == settings.PADDLEOCR_VL_BACKEND.lower()
    expected_ver = settings.PADDLEOCR_VL_PIPELINE_VERSION.lstrip("v")
    assert processor.provider_name == f"paddleocr-vl-{expected_ver}"


def test_paddleocr_vl_endpoint_url_resolution():
    """Verify chat endpoint URL normalization across different base URL formats."""
    p1 = PaddleOCRVLDocumentProcessor(server_url="http://localhost:8080/v1")
    assert p1._get_chat_endpoint_url() == "http://localhost:8080/v1/chat/completions"

    p2 = PaddleOCRVLDocumentProcessor(server_url="http://localhost:8080")
    assert p2._get_chat_endpoint_url() == "http://localhost:8080/v1/chat/completions"

    p3 = PaddleOCRVLDocumentProcessor(
        server_url="http://localhost:8080/v1/chat/completions"
    )
    assert p3._get_chat_endpoint_url() == "http://localhost:8080/v1/chat/completions"


def test_paddleocr_vl_file_not_found_raises_permanent_error(tmp_path: Path):
    """Verify non-existent file raises PermanentProcessingError."""
    processor = PaddleOCRVLDocumentProcessor()
    non_existent = tmp_path / "missing.png"
    with pytest.raises(PermanentProcessingError, match="Document file not found"):
        processor.process(non_existent, "image/png")


def test_paddleocr_vl_vllm_image_success(tmp_path: Path):
    """Verify successful vLLM inference on an image file."""
    # Create a test image
    img_path = tmp_path / "sample.png"
    img = Image.new("RGB", (100, 100), color="white")
    img.save(img_path)

    # Mock HTTP client
    mock_response = MagicMock(spec=httpx.Response)
    mock_response.status_code = 200
    mock_response.json.return_value = {
        "choices": [
            {
                "message": {
                    "content": "# Invoice\n\n| Item | Cost |\n| --- | --- |\n| License | $100 |"
                }
            }
        ]
    }
    mock_http_client = MagicMock(spec=httpx.Client)
    mock_http_client.post.return_value = mock_response

    processor = PaddleOCRVLDocumentProcessor(
        backend="vllm-server",
        server_url="http://fake-vllm:8080/v1",
        client=mock_http_client,
    )

    result = processor.process(img_path, "image/png")

    assert isinstance(result, ExtractedTextResult)
    assert "# Invoice" in result.text
    assert "| Item | Cost |" in result.text
    assert result.provider == "paddleocr-vl-1.6"
    assert result.char_count == len(result.text)
    assert result.raw_metadata["backend"] == "vllm-server"
    assert result.raw_metadata["pages"] == 1


def test_paddleocr_vl_vllm_pdf_multi_page(tmp_path: Path):
    """Verify PDF multi-page handling and markdown aggregation."""
    pdf_path = tmp_path / "multi.pdf"

    # Create dummy multi-page PDF using pypdfium2 or PIL
    import pypdfium2 as pdfium

    pdf = pdfium.PdfDocument.new()
    pdf.new_page(width=200, height=200)
    pdf.new_page(width=200, height=200)
    pdf.save(str(pdf_path))

    # Mock HTTP response
    call_count = 0

    def mock_post(*args, **kwargs):
        nonlocal call_count
        call_count += 1
        resp = MagicMock(spec=httpx.Response)
        resp.status_code = 200
        resp.json.return_value = {
            "choices": [{"message": {"content": f"## Page {call_count} Content"}}]
        }
        return resp

    mock_http_client = MagicMock(spec=httpx.Client)
    mock_http_client.post.side_effect = mock_post

    processor = PaddleOCRVLDocumentProcessor(
        backend="vllm-server",
        server_url="http://fake-vllm:8080/v1",
        client=mock_http_client,
    )

    result = processor.process(pdf_path, "application/pdf")

    assert call_count == 2
    assert "## Page 1 Content" in result.text
    assert "## Page 2 Content" in result.text
    assert "---" in result.text
    assert result.raw_metadata["pages"] == 2


@pytest.mark.parametrize("status_code", [429, 500, 502, 503, 504])
def test_paddleocr_vl_vllm_transient_http_errors(tmp_path: Path, status_code: int):
    """Verify that 429 and 5xx status codes raise TransientProcessingError for Celery retry."""
    img_path = tmp_path / "doc.png"
    Image.new("RGB", (50, 50), color="blue").save(img_path)

    mock_resp = MagicMock(spec=httpx.Response)
    mock_resp.status_code = status_code
    mock_resp.text = f"Server busy or error {status_code}"

    mock_http = MagicMock(spec=httpx.Client)
    mock_http.post.return_value = mock_resp

    processor = PaddleOCRVLDocumentProcessor(
        backend="vllm-server",
        server_url="http://fake-vllm:8080/v1",
        client=mock_http,
    )

    with pytest.raises(
        TransientProcessingError, match=f"returned transient error {status_code}"
    ):
        processor.process(img_path, "image/png")


def test_paddleocr_vl_vllm_network_timeout_transient(tmp_path: Path):
    """Verify network timeout raises TransientProcessingError."""
    img_path = tmp_path / "doc.png"
    Image.new("RGB", (50, 50), color="blue").save(img_path)

    mock_http = MagicMock(spec=httpx.Client)
    mock_http.post.side_effect = httpx.TimeoutException("Read timed out")

    processor = PaddleOCRVLDocumentProcessor(
        backend="vllm-server",
        server_url="http://fake-vllm:8080/v1",
        client=mock_http,
    )

    with pytest.raises(TransientProcessingError, match="Network error contacting"):
        processor.process(img_path, "image/png")


def test_paddleocr_vl_vllm_bad_request_permanent(tmp_path: Path):
    """Verify HTTP 400 Bad Request raises PermanentProcessingError."""
    img_path = tmp_path / "doc.png"
    Image.new("RGB", (50, 50), color="blue").save(img_path)

    mock_resp = MagicMock(spec=httpx.Response)
    mock_resp.status_code = 400
    mock_resp.text = "Bad Request: Invalid model parameters"

    mock_http = MagicMock(spec=httpx.Client)
    mock_http.post.return_value = mock_resp

    processor = PaddleOCRVLDocumentProcessor(
        backend="vllm-server",
        server_url="http://fake-vllm:8080/v1",
        client=mock_http,
    )

    with pytest.raises(PermanentProcessingError, match="server error 400"):
        processor.process(img_path, "image/png")


def test_paddleocr_vl_local_backend_success(tmp_path: Path):
    """Verify local PaddleOCRVL pipeline execution with mocked pipeline."""
    img_path = tmp_path / "receipt.png"
    Image.new("RGB", (80, 80), color="red").save(img_path)

    # Mock pipeline object returned by PaddleOCRVL
    mock_res = MagicMock()
    mock_res.markdown = "# Scanned Receipt\nTotal: $42.00"
    mock_pipeline = MagicMock()
    mock_pipeline.predict.return_value = [mock_res]

    processor = PaddleOCRVLDocumentProcessor(
        backend="local",
        pipeline=mock_pipeline,
    )

    result = processor.process(img_path, "image/png")
    assert result.text == "# Scanned Receipt\nTotal: $42.00"
    assert result.provider == "paddleocr-vl-1.6"
    assert result.raw_metadata["backend"] == "local"


def test_paddleocr_vl_local_backend_missing_package(tmp_path: Path):
    """Verify missing paddleocr in local backend raises PermanentProcessingError."""
    img_path = tmp_path / "receipt.png"
    Image.new("RGB", (80, 80), color="red").save(img_path)

    processor = PaddleOCRVLDocumentProcessor(backend="local")

    with patch.dict("sys.modules", {"paddleocr": None}):
        with pytest.raises(
            PermanentProcessingError, match="PaddleOCR is not installed"
        ):
            processor.process(img_path, "image/png")


def test_get_document_processor_factory():
    """Verify factory returns appropriate processor based on requested provider."""
    # Explicit gemini
    proc_gemini = get_document_processor("gemini")
    assert isinstance(proc_gemini, GeminiDocumentProcessor)

    # Explicit paddleocr_vl
    proc_paddle = get_document_processor("paddleocr_vl")
    assert isinstance(proc_paddle, PaddleOCRVLDocumentProcessor)

    # Alias paddleocr
    proc_paddle_alias = get_document_processor("paddleocr")
    assert isinstance(proc_paddle_alias, PaddleOCRVLDocumentProcessor)

    # Default fallback to settings.OCR_PROVIDER
    with patch.object(settings, "OCR_PROVIDER", "paddleocr_vl"):
        proc_default = get_document_processor()
        assert isinstance(proc_default, PaddleOCRVLDocumentProcessor)


def test_upload_document_with_paddleocr_provider():
    """Verify API accepts provider='paddleocr_vl' and stores it on the Job record."""
    file_bytes = b"%PDF-1.4 sample pdf content for provider test"
    response = client.post(
        "/api/v1/documents",
        files={"file": ("sample.pdf", io.BytesIO(file_bytes), "application/pdf")},
        data={"provider": "paddleocr_vl"},
    )
    assert response.status_code == 202
    data = response.json()["data"]
    assert data["provider"] == "paddleocr_vl"

    # Verify Job record in database has provider set
    db = DatabaseService.get_session()
    try:
        job = db.query(Job).filter(Job.id == data["job_id"]).first()
        assert job is not None
        assert job.provider == "paddleocr_vl"
    finally:
        db.close()


def test_upload_document_with_invalid_provider():
    """Verify API rejects invalid provider with 400 Bad Request."""
    file_bytes = b"%PDF-1.4 dummy pdf"
    response = client.post(
        "/api/v1/documents",
        files={"file": ("sample.pdf", io.BytesIO(file_bytes), "application/pdf")},
        data={"provider": "invalid_engine"},
    )
    assert response.status_code == 400
    assert "Unsupported OCR provider" in response.json()["message"]


def test_celery_task_executes_with_paddleocr_processor(tmp_path: Path):
    """Verify process_document_task uses the requested paddleocr provider and persists result."""
    # Create test document file
    doc_file = tmp_path / "test_paddle_doc.png"
    Image.new("RGB", (60, 60), color="green").save(doc_file)

    db = DatabaseService.get_session()
    test_uid = uuid.uuid4().hex[:8]
    doc_id = f"doc_paddle_{test_uid}"
    job_id = f"job_paddle_{test_uid}"

    db = DatabaseService.get_session()
    try:
        doc = Document(
            id=doc_id,
            filename="test_paddle_doc.png",
            file_path=str(doc_file),
            content_type="image/png",
            size_bytes=doc_file.stat().st_size,
            file_hash=f"hash_paddle_{test_uid}",
            status=DocumentStatus.UPLOADED,
        )
        job = Job(
            id=job_id,
            document_id=doc.id,
            status=JobStatus.QUEUED,
            provider="paddleocr_vl",
            attempts=0,
        )
        db.add(doc)
        db.add(job)
        db.commit()
    finally:
        db.close()

    # Create mock processor returning paddleocr result
    mock_processor = MagicMock(spec=PaddleOCRVLDocumentProcessor)
    mock_processor.process.return_value = ExtractedTextResult(
        text="# PaddleOCR Extracted Text\nFormula: $E=mc^2$",
        provider="paddleocr-vl-1.6",
        char_count=43,
        raw_metadata={"model": "PaddlePaddle/PaddleOCR-VL-1.6"},
    )
    set_document_processor(mock_processor)

    task_result = process_document_task.apply(args=[job_id]).get()

    assert task_result["status"] == "completed"
    assert task_result["provider"] == "paddleocr-vl-1.6"
    assert task_result["char_count"] == 43

    # Check database Result
    db = DatabaseService.get_session()
    try:
        saved_result = db.query(Result).filter(Result.job_id == job_id).first()
        assert saved_result is not None
        assert saved_result.provider == "paddleocr-vl-1.6"
        assert "Formula: $E=mc^2$" in saved_result.extracted_text
    finally:
        db.close()
