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
