from pathlib import Path
from typing import Any

from fastapi import APIRouter, Request
from fastapi.templating import Jinja2Templates

from app.core.config import settings

router = APIRouter(tags=["root"])

templates_dir = Path(__file__).resolve().parent.parent / "templates"
templates = Jinja2Templates(directory=str(templates_dir))


@router.get("/", tags=["root"])
def root(request: Request) -> Any:
    """Serve the modern document-processing web UI when accessed via browser,

    or return JSON service information for API clients.
    """
    accept = request.headers.get("accept", "")
    if "text/html" in accept and templates_dir.exists():
        return templates.TemplateResponse(
            request=request,
            name="index.html",
            context={
                "project_name": settings.PROJECT_NAME,
                "version": settings.VERSION,
                "max_file_size_mb": settings.MAX_UPLOAD_SIZE_BYTES // (1024 * 1024),
                "allowed_extensions": sorted(settings.ALLOWED_EXTENSIONS),
            },
        )
    return {
        "service": settings.PROJECT_NAME,
        "status": "running",
        "docs": "/docs",
    }
