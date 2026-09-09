"""Abstract interface and common exceptions for document text extraction."""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


class DocumentProcessingError(Exception):
    """Base exception for document processing errors."""

    def __init__(self, message: str, is_transient: bool = False) -> None:
        super().__init__(message)
        self.message = message
        self.is_transient = is_transient


class TransientProcessingError(DocumentProcessingError):
    """Temporary failure suitable for worker retry (e.g. rate limit, network timeout, 503)."""

    def __init__(self, message: str) -> None:
        super().__init__(message, is_transient=True)


class PermanentProcessingError(DocumentProcessingError):
    """Terminal failure that should not be retried (e.g. corrupt file, invalid API key)."""

    def __init__(self, message: str) -> None:
        super().__init__(message, is_transient=False)


@dataclass
class ExtractedTextResult:
    """Standard payload returned by any document processor implementation."""

    text: str
    provider: str
    char_count: int
    raw_metadata: dict[str, Any] = field(default_factory=dict)


class DocumentProcessor(ABC):
    """Abstract base class for OCR and document text extraction providers."""

    @abstractmethod
    def process(self, file_path: Path, content_type: str) -> ExtractedTextResult:
        """Extract readable text from a local document or image file.

        Args:
            file_path: Path to the stored document file.
            content_type: MIME type of the document (e.g. 'application/pdf', 'image/png').

        Returns:
            ExtractedTextResult containing extracted text and metadata.

        Raises:
            TransientProcessingError: On temporary errors (retryable).
            PermanentProcessingError: On non-recoverable errors (terminal).
        """
        raise NotImplementedError


_default_processor: DocumentProcessor | None = None


def get_document_processor(provider: str | None = None) -> DocumentProcessor:
    """Return the configured DocumentProcessor instance for the specified or default provider.

    Args:
        provider: 'gemini', 'paddleocr_vl', or None (falls back to settings.OCR_PROVIDER).
    """
    global _default_processor
    if _default_processor is not None:
        return _default_processor

    from app.core.config import settings

    target_provider = (provider or settings.OCR_PROVIDER).lower().strip()

    if target_provider in (
        "paddleocr",
        "paddleocr_vl",
        "paddleocr-vl",
        "paddleocr-vl-1.6",
    ):
        from app.services.paddleocr_vl_service import PaddleOCRVLDocumentProcessor

        return PaddleOCRVLDocumentProcessor()

    from app.services.gemini_service import GeminiDocumentProcessor

    return GeminiDocumentProcessor()


def set_document_processor(processor: DocumentProcessor | None) -> None:
    """Override the document processor (useful for dependency injection in unit tests)."""
    global _default_processor
    _default_processor = processor
