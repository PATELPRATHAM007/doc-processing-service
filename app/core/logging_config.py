import logging
import sys
import threading
from contextvars import ContextVar

from app.core.config import settings

NO_CONTEXT = "-"
LOGGER_NAMESPACE = "docservice"

request_id_var: ContextVar[str] = ContextVar("request_id", default=NO_CONTEXT)
user_id_var: ContextVar[str] = ContextVar("user_id", default=NO_CONTEXT)

_configured = False
_config_lock = threading.Lock()
_FOREIGN_LOGGERS = ("uvicorn", "uvicorn.error", "uvicorn.access", "uvicorn.asgi")


class ContextFilter(logging.Filter):
    """Adds request_id, user_id, and short_name context to log records."""

    def filter(self, record: logging.LogRecord) -> bool:
        req_id = request_id_var.get()
        u_id = user_id_var.get()
        record.context = (
            f" [req={req_id} user={u_id}]"
            if (req_id != NO_CONTEXT or u_id != NO_CONTEXT)
            else ""
        )
        prefix = f"{LOGGER_NAMESPACE}."
        record.short_name = (
            record.name[len(prefix) :]
            if record.name.startswith(prefix)
            else record.name
        )
        return True


def setup_logging() -> None:
    """Configure root logging for the process."""
    global _configured
    if _configured:
        return

    with _config_lock:
        if _configured:
            return

        log_level = logging.DEBUG if settings.DEBUG else logging.INFO
        handler = logging.StreamHandler(sys.stdout)
        handler.addFilter(ContextFilter())
        handler.setFormatter(
            logging.Formatter(
                "[%(asctime)s] [%(levelname)s] [%(short_name)s]%(context)s %(message)s"
            )
        )

        root = logging.getLogger()
        root.setLevel(log_level)
        root.handlers.clear()
        root.addHandler(handler)

        _configured = True


def adopt_foreign_loggers() -> None:
    """Redirect foreign/third-party loggers (like uvicorn) into the unified handler."""
    setup_logging()
    for name in _FOREIGN_LOGGERS:
        logger = logging.getLogger(name)
        logger.handlers.clear()
        logger.propagate = True


def get_logger(category: str = "system") -> logging.Logger:
    """Get a named logger, configuring root logging if not yet initialized."""
    setup_logging()
    name = f"docservice.{category}" if category else "docservice.system"
    return logging.getLogger(name)
