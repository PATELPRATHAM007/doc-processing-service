"""Services package."""

from app.services.document_processor import (
    DocumentProcessor,
    ExtractedTextResult,
    PermanentProcessingError,
    TransientProcessingError,
    get_document_processor,
    set_document_processor,
)
from app.services.gemini_service import GeminiDocumentProcessor
from app.services.paddleocr_vl_service import PaddleOCRVLDocumentProcessor
from app.services.prompts import DOCUMENT_EXTRACTION_PROMPT, EXTRACTION_PROMPT

__all__ = [
    "DOCUMENT_EXTRACTION_PROMPT",
    "EXTRACTION_PROMPT",
    "DocumentProcessor",
    "ExtractedTextResult",
    "GeminiDocumentProcessor",
    "PaddleOCRVLDocumentProcessor",
    "PermanentProcessingError",
    "TransientProcessingError",
    "get_document_processor",
    "set_document_processor",
]
