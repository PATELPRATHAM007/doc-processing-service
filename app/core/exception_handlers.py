from collections.abc import Mapping

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from app.core.logging_config import get_logger

logger = get_logger("api")


def _error_response(
    status_code: int,
    message: str,
    errors: list[dict[str, str]] | None = None,
    headers: Mapping[str, str] | None = None,
) -> JSONResponse:
    return JSONResponse(
        status_code=status_code,
        headers=dict(headers) if headers else None,
        content={
            "success": False,
            "statusCode": status_code,
            "message": message,
            "errors": errors or [],
            "data": {},
        },
    )


def register_exception_handlers(app: FastAPI) -> None:
    """Register application-wide exception handlers."""

    @app.exception_handler(RequestValidationError)
    async def validation_exception_handler(
        _: Request, exc: RequestValidationError
    ) -> JSONResponse:
        logger.warning(f"Validation error: {exc.errors()}")
        issues = [
            {
                "field": str(e.get("loc", ())[-1]) if e.get("loc") else "",
                "message": str(e.get("msg")),
            }
            for e in exc.errors()
        ]
        return _error_response(422, "Validation failed", issues)

    @app.exception_handler(HTTPException)
    async def http_exception_handler(_: Request, exc: HTTPException) -> JSONResponse:
        detail = exc.detail if isinstance(exc.detail, str) else str(exc.detail)
        return _error_response(exc.status_code, detail, headers=exc.headers)
