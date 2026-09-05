"""Google Gemini document text extraction service."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from google import genai
from google.genai import types
from google.genai.errors import APIError

from app.core.config import settings
from app.services.document_processor import (
    DocumentProcessor,
    ExtractedTextResult,
    PermanentProcessingError,
    TransientProcessingError,
)
from app.services.prompts import EXTRACTION_PROMPT
from logger_manager import LoggerManager

gemini_logger = LoggerManager(folder_name="gemini")


class GeminiDocumentProcessor(DocumentProcessor):
    """Document text extraction provider using Google Gemini Multimodal API."""

    EXTRACTION_PROMPT = EXTRACTION_PROMPT

    def __init__(
        self,
        api_key: str | None = None,
        model_name: str | None = None,
        client: genai.Client | None = None,
    ) -> None:
        self.api_key = api_key or settings.GEMINI_API_KEY
        self.model_name = model_name or settings.GEMINI_MODEL
        self._client = client

    def _get_client(self) -> genai.Client:
        if self._client is not None:
            return self._client
        if not self.api_key:
            raise PermanentProcessingError(
                "Gemini API key is not configured. Set GEMINI_API_KEY in .env."
            )
        return genai.Client(api_key=self.api_key)

    def process(self, file_path: Path, content_type: str) -> ExtractedTextResult:
        """Extract text from a file using Gemini Multimodal OCR."""
        path = Path(file_path)
        if not path.exists() or not path.is_file():
            gemini_logger.error("Document file not found on disk: %s", path)
            raise PermanentProcessingError(f"Document file not found: {path}")

        try:
            file_bytes = path.read_bytes()
        except OSError as exc:
            gemini_logger.error("Failed to read file %s: %s", path, exc)
            raise PermanentProcessingError(
                f"Could not read document file: {exc}"
            ) from exc

        gemini_logger.info(
            "Sending document to Gemini for OCR (file=%s, mime=%s, size=%d bytes, model=%s)",
            path.name,
            content_type,
            len(file_bytes),
            self.model_name,
        )

        client = self._get_client()
        contents: list[Any] = [
            types.Part.from_bytes(data=file_bytes, mime_type=content_type),
            self.EXTRACTION_PROMPT,
        ]

        try:
            response = client.models.generate_content(
                model=self.model_name,
                contents=contents,
            )
        except APIError as exc:
            err_msg = str(exc)
            status_code = getattr(exc, "code", None)

            # Authentication / permission errors are permanent and should never retry
            if (
                status_code in (401, 403)
                or "unauthenticated" in err_msg.lower()
                or "permission_denied" in err_msg.lower()
            ):
                gemini_logger.error(
                    "Gemini API authentication failed (status=%s): %s",
                    status_code,
                    err_msg,
                )
                raise PermanentProcessingError(
                    f"Gemini authentication failed ({status_code or '401'}): Invalid API key or credentials. Please check GEMINI_API_KEY in .env."
                ) from exc

            is_transient = (
                status_code in (429, 500, 502, 503, 504)
                or "rate limit" in err_msg.lower()
                or "too many requests" in err_msg.lower()
                or "resource exhausted" in err_msg.lower()
                or "quota" in err_msg.lower()
                or "timeout" in err_msg.lower()
            )
            if is_transient:
                gemini_logger.warning(
                    "Gemini API transient failure (status=%s): %s", status_code, err_msg
                )
                raise TransientProcessingError(
                    f"Gemini API transient failure: {err_msg}"
                ) from exc

            gemini_logger.error(
                "Gemini API permanent rejection (status=%s): %s", status_code, err_msg
            )
            raise PermanentProcessingError(
                f"Gemini API permanent error: {err_msg}"
            ) from exc
        except Exception as exc:
            err_msg = str(exc).lower()
            if "timeout" in err_msg or "connection" in err_msg:
                gemini_logger.warning("Gemini network error: %s", exc)
                raise TransientProcessingError(
                    f"Network error contacting Gemini: {exc}"
                ) from exc

            gemini_logger.error("Unexpected Gemini error: %s", exc)
            raise PermanentProcessingError(
                f"Unexpected error processing document: {exc}"
            ) from exc

        extracted_text = (response.text or "").strip()
        char_count = len(extracted_text)

        gemini_logger.info(
            "Gemini OCR completed successfully (file=%s, chars=%d, model=%s)",
            path.name,
            char_count,
            self.model_name,
        )

        return ExtractedTextResult(
            text=extracted_text,
            provider=self.model_name,
            char_count=char_count,
            raw_metadata={"model": self.model_name},
        )


_default_processor: DocumentProcessor | None = None


def get_document_processor() -> DocumentProcessor:
    """Return the configured DocumentProcessor instance."""
    global _default_processor
    if _default_processor is None:
        _default_processor = GeminiDocumentProcessor()
    return _default_processor


def set_document_processor(processor: DocumentProcessor | None) -> None:
    """Override the document processor (useful for dependency injection in unit tests)."""
    global _default_processor
    _default_processor = processor
