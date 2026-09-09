"""PaddleOCR-VL-1.6 document text extraction service."""

from __future__ import annotations

import base64
import io
import re
from pathlib import Path
from typing import Any

import httpx
from PIL import Image

from app.core.config import settings
from app.services.document_processor import (
    DocumentProcessor,
    ExtractedTextResult,
    PermanentProcessingError,
    TransientProcessingError,
)
from logger_manager import LoggerManager

paddleocr_logger = LoggerManager(folder_name="paddleocr")


class PaddleOCRVLDocumentProcessor(DocumentProcessor):
    """Document text extraction provider using PaddlePaddle's PaddleOCR-VL-1.6 model.

    Supports two primary execution modes:
    1. 'vllm-server': Sends inference requests to a remote or containerized vLLM / GenAI server.
    2. 'local': Runs the PaddleOCRVL pipeline in-process using local CPU/GPU hardware.
    """

    DEFAULT_PROMPT = "OCR:"

    def __init__(
        self,
        pipeline_version: str | None = None,
        model_name: str | None = None,
        backend: str | None = None,
        server_url: str | None = None,
        device: str | None = None,
        timeout_seconds: int | None = None,
        client: httpx.Client | None = None,
        pipeline: Any | None = None,
    ) -> None:
        self.pipeline_version = (
            pipeline_version or settings.PADDLEOCR_VL_PIPELINE_VERSION
        )
        self.model_name = model_name or settings.PADDLEOCR_VL_MODEL_NAME
        self.backend = (backend or settings.PADDLEOCR_VL_BACKEND).lower().strip()
        self.server_url = (server_url or settings.PADDLEOCR_VL_SERVER_URL).rstrip("/")
        self.device = device or settings.PADDLEOCR_VL_DEVICE
        self.timeout_seconds = timeout_seconds or settings.PADDLEOCR_VL_TIMEOUT_SECONDS
        self._client = client
        self._pipeline = pipeline

    @property
    def provider_name(self) -> str:
        ver = self.pipeline_version.lstrip("v") if self.pipeline_version else "1.6"
        return f"paddleocr-vl-{ver}"

    def _get_http_client(self) -> httpx.Client:
        if self._client is not None:
            return self._client
        return httpx.Client(timeout=float(self.timeout_seconds))

    def _get_chat_endpoint_url(self) -> str:
        """Resolve the full chat completions endpoint from the configured server URL."""
        url = self.server_url
        if url.endswith("/chat/completions"):
            return url
        if url.endswith("/v1"):
            return f"{url}/chat/completions"
        return f"{url}/v1/chat/completions"

    def process(self, file_path: Path, content_type: str) -> ExtractedTextResult:
        """Extract readable text and layout-preserving Markdown from a document using PaddleOCR-VL-1.6."""
        path = Path(file_path)
        if not path.exists() or not path.is_file():
            paddleocr_logger.error("Document file not found on disk: %s", path)
            raise PermanentProcessingError(f"Document file not found: {path}")

        paddleocr_logger.info(
            "Processing document with PaddleOCR-VL (file=%s, mime=%s, backend=%s, model=%s)",
            path.name,
            content_type,
            self.backend,
            self.model_name,
        )

        if self.backend == "local":
            return self._process_local(path, content_type)
        return self._process_vllm(path, content_type)

    def _process_local(self, path: Path, content_type: str) -> ExtractedTextResult:
        """Execute inference using local PaddleOCRVL pipeline."""
        pipeline = self._pipeline
        if pipeline is None:
            try:
                if self.device:
                    try:
                        import paddle  # type: ignore[import-untyped]

                        paddle.device.set_device(self.device)
                    except Exception as dev_err:
                        paddleocr_logger.warning(
                            "Could not set paddle device to %s: %s",
                            self.device,
                            dev_err,
                        )

                from paddleocr import PaddleOCRVL  # type: ignore[import-untyped]

                pipeline = PaddleOCRVL(
                    pipeline_version=self.pipeline_version,
                    device=self.device,
                )
                self._pipeline = pipeline
            except ImportError as exc:
                paddleocr_logger.error(
                    "paddleocr package not found for local backend: %s", exc
                )
                raise PermanentProcessingError(
                    "PaddleOCR is not installed in the local environment. "
                    "Install paddlepaddle and 'paddleocr[doc-parser]>=3.6.0', or set PADDLEOCR_VL_BACKEND='vllm-server'."
                ) from exc
            except Exception as exc:
                paddleocr_logger.error(
                    "Failed to initialize local PaddleOCRVL pipeline: %s", exc
                )
                raise PermanentProcessingError(
                    f"Failed to initialize local PaddleOCR-VL pipeline: {exc}"
                ) from exc

        try:
            output = pipeline.predict(str(path))
        except Exception as exc:
            paddleocr_logger.error("Local PaddleOCR-VL prediction failed: %s", exc)
            err_msg = str(exc)
            if (
                "PDFium: Data format error" in err_msg
                or "Failed to load document" in err_msg
            ):
                raise PermanentProcessingError(
                    "The uploaded document is corrupt or invalid. PDFium could not parse the document structure."
                ) from exc
            raise PermanentProcessingError(
                f"PaddleOCR-VL inference error: {exc}"
            ) from exc

        page_texts: list[str] = []
        for res in output:
            cleaned_page = self._extract_clean_text_from_result(res)
            if cleaned_page:
                page_texts.append(cleaned_page)

        extracted_text = (
            "\n\n---\n\n".join(page_texts)
            if len(page_texts) > 1
            else (page_texts[0] if page_texts else "")
        )
        char_count = len(extracted_text)

        paddleocr_logger.info(
            "Local PaddleOCR-VL extraction finished (file=%s, chars=%d, pages=%d)",
            path.name,
            char_count,
            len(page_texts),
        )

        return ExtractedTextResult(
            text=extracted_text,
            provider=self.provider_name,
            char_count=char_count,
            raw_metadata={
                "backend": "local",
                "model": self.model_name,
                "pipeline_version": self.pipeline_version,
                "pages": len(page_texts),
            },
        )

    def _process_vllm(self, path: Path, content_type: str) -> ExtractedTextResult:
        """Execute inference by sending pages/images to a vLLM or PaddleOCR GenAI server."""
        if not self.server_url:
            raise PermanentProcessingError(
                "PaddleOCR-VL server URL is not configured. Set PADDLEOCR_VL_SERVER_URL in .env."
            )

        # 1. Prepare images to process (handles both PDFs and images)
        images: list[Image.Image] = []
        is_pdf = content_type == "application/pdf" or path.suffix.lower() == ".pdf"

        try:
            if is_pdf:
                images = self._render_pdf_to_images(path)
            else:
                images = [Image.open(path).convert("RGB")]
        except Exception as exc:
            paddleocr_logger.error("Failed to load/render document '%s': %s", path, exc)
            raise PermanentProcessingError(
                f"Could not load document file: {exc}"
            ) from exc

        if not images:
            raise PermanentProcessingError(
                "No readable pages or images found in document."
            )

        endpoint = self._get_chat_endpoint_url()
        client = self._get_http_client()
        page_results: list[str] = []

        paddleocr_logger.info(
            "Dispatching %d page(s) to PaddleOCR-VL vLLM server: %s",
            len(images),
            endpoint,
        )

        for _page_idx, img in enumerate(images, start=1):
            buf = io.BytesIO()
            img.save(buf, format="PNG")
            b64_img = base64.b64encode(buf.getvalue()).decode("utf-8")
            data_uri = f"data:image/png;base64,{b64_img}"

            payload = {
                "model": self.model_name,
                "messages": [
                    {
                        "role": "user",
                        "content": [
                            {"type": "image_url", "image_url": {"url": data_uri}},
                            {"type": "text", "text": self.DEFAULT_PROMPT},
                        ],
                    }
                ],
                "max_tokens": 4096,
                "temperature": 0.0,
            }

            try:
                response = client.post(endpoint, json=payload)
            except (httpx.TimeoutException, httpx.NetworkError) as exc:
                paddleocr_logger.warning(
                    "Network failure contacting PaddleOCR-VL server: %s", exc
                )
                raise TransientProcessingError(
                    f"Network error contacting PaddleOCR-VL inference server: {exc}"
                ) from exc
            except Exception as exc:
                paddleocr_logger.error(
                    "Unexpected error contacting PaddleOCR-VL server: %s", exc
                )
                raise PermanentProcessingError(
                    f"Failed to communicate with PaddleOCR-VL server: {exc}"
                ) from exc

            # Error handling for HTTP status codes
            if response.status_code != 200:
                status = response.status_code
                err_text = response.text[:500]
                if status in (429, 500, 502, 503, 504):
                    paddleocr_logger.warning(
                        "PaddleOCR-VL server transient status %d: %s", status, err_text
                    )
                    raise TransientProcessingError(
                        f"PaddleOCR-VL server returned transient error {status}: {err_text}"
                    )

                paddleocr_logger.error(
                    "PaddleOCR-VL server rejected request with status %d: %s",
                    status,
                    err_text,
                )
                raise PermanentProcessingError(
                    f"PaddleOCR-VL server error {status}: {err_text}"
                )

            try:
                res_data = response.json()
                content = res_data["choices"][0]["message"]["content"]
                page_results.append(content.strip())
            except (KeyError, IndexError, ValueError) as exc:
                paddleocr_logger.error(
                    "Malformed response from PaddleOCR-VL server: %s",
                    response.text[:500],
                )
                raise PermanentProcessingError(
                    f"Malformed response received from PaddleOCR-VL server: {exc}"
                ) from exc

        extracted_text = (
            "\n\n---\n\n".join(page_results)
            if len(page_results) > 1
            else (page_results[0] if page_results else "")
        )
        char_count = len(extracted_text)

        paddleocr_logger.info(
            "PaddleOCR-VL extraction completed (file=%s, pages=%d, chars=%d)",
            path.name,
            len(page_results),
            char_count,
        )

        return ExtractedTextResult(
            text=extracted_text,
            provider=self.provider_name,
            char_count=char_count,
            raw_metadata={
                "backend": "vllm-server",
                "server_url": self.server_url,
                "model": self.model_name,
                "pages": len(page_results),
            },
        )

    def _render_pdf_to_images(self, path: Path) -> list[Image.Image]:
        """Convert a PDF file into a list of PIL Images, one per page."""
        try:
            import pypdfium2 as pdfium  # type: ignore[import-untyped]

            pdf = pdfium.PdfDocument(path)
            images: list[Image.Image] = []
            for i in range(len(pdf)):
                page = pdf[i]
                # Render at 150 DPI for balanced speed & OCR clarity
                bitmap = page.render(scale=150 / 72)
                pil_image = bitmap.to_pil().convert("RGB")
                images.append(pil_image)
            return images
        except ImportError:
            paddleocr_logger.warning(
                "pypdfium2 not found, falling back to PIL image check"
            )
            try:
                img = Image.open(path)
                return [img.convert("RGB")]
            except Exception as exc:
                raise PermanentProcessingError(
                    "pypdfium2 is required for PDF page rendering with PaddleOCR-VL. "
                    "Install pypdfium2 or ensure paddleocr handles PDF locally."
                ) from exc

    def _extract_clean_text_from_result(self, res: Any) -> str:
        """Extract clean, properly ordered text from a PaddleOCR-VL prediction result.

        Filters out all internal OCR metadata (bboxes, coordinates, confidence scores,
        polygon points, image arrays, labels) while preserving headings, section numbers,
        bullet points, paragraphs, and reading order.
        """
        if res is None:
            return ""

        blocks = None
        # 1. Extract parsing_res_list from dict or object attribute
        if isinstance(res, dict) or hasattr(res, "__getitem__"):
            try:
                blocks = res.get("parsing_res_list")
            except Exception:
                blocks = None
        if blocks is None and hasattr(res, "parsing_res_list"):
            blocks = getattr(res, "parsing_res_list", None)

        if blocks and isinstance(blocks, (list, tuple)):
            extracted_blocks: list[tuple[bool, str]] = []
            TITLE_LABELS = {
                "paragraph_title",
                "title",
                "header",
                "section_title",
                "table",
            }

            for block in blocks:
                if isinstance(block, dict):
                    raw_content = (
                        block.get("content")
                        or block.get("block_content")
                        or block.get("text")
                        or ""
                    )
                    raw_label = block.get("label") or block.get("block_label") or "text"
                else:
                    raw_content = (
                        getattr(block, "content", None)
                        or getattr(block, "block_content", None)
                        or getattr(block, "text", None)
                        or ""
                    )
                    raw_label = (
                        getattr(block, "label", None)
                        or getattr(block, "block_label", None)
                        or "text"
                    )

                content_str = str(raw_content).strip()
                if not content_str:
                    continue

                # Strip internal OCR debug artifacts if present
                cleaned_lines: list[str] = []
                for line in content_str.split("\n"):
                    stripped = line.strip()
                    if (
                        stripped.startswith("#################")
                        or stripped.startswith("bbox:")
                        or stripped.startswith("score:")
                        or stripped.startswith("coordinate:")
                        or stripped.startswith("polygon_points:")
                        or stripped.startswith("cls_id:")
                        or stripped.startswith("model_settings:")
                    ):
                        continue
                    if stripped.startswith("label:") or stripped.startswith("content:"):
                        if stripped.startswith("content:"):
                            line = line.split("content:", 1)[1].lstrip()
                        else:
                            continue
                    cleaned_lines.append(line)

                cleaned_text = "\n".join(cleaned_lines).strip()
                if not cleaned_text:
                    continue

                # Identify if block is a title, heading, or numbered section header (e.g., '1. Personal Information:')
                is_title = str(raw_label).lower() in TITLE_LABELS or bool(
                    re.match(r"^\d+[\.\)]\s+[A-Z]", cleaned_text)
                )
                extracted_blocks.append((is_title, cleaned_text))

            if extracted_blocks:
                result_parts: list[str] = []
                for i, (is_title, text) in enumerate(extracted_blocks):
                    if i == 0:
                        result_parts.append(text)
                    else:
                        prev_is_title, _ = extracted_blocks[i - 1]
                        if is_title or prev_is_title:
                            result_parts.append("\n\n" + text)
                        else:
                            result_parts.append("\n" + text)
                return "".join(result_parts).strip()

        # 2. Check for markdown or text attributes/keys
        if isinstance(res, dict):
            if "markdown" in res and res["markdown"]:
                return str(res["markdown"]).strip()
            if "markdown_texts" in res and res["markdown_texts"]:
                return str(res["markdown_texts"]).strip()
            if "text" in res and res["text"]:
                return str(res["text"]).strip()
        elif hasattr(res, "markdown") and res.markdown:
            return str(res.markdown).strip()
        elif hasattr(res, "text") and res.text:
            return str(res.text).strip()

        # 3. String representation fallback with artifact filtering
        text_val = str(res).strip()
        if text_val.startswith("{") and (
            "parsing_res_list" in text_val or "layout_det_res" in text_val
        ):
            # Extract content using regex from stringified dicts
            matches = re.findall(
                r"content:\s*(.*?)(?=\n#{3,}|\nlabel:|\Z)", text_val, re.DOTALL
            )
            if matches:
                clean_matches = [m.strip() for m in matches if m.strip()]
                if clean_matches:
                    return "\n\n".join(clean_matches)
            return ""

        return text_val
