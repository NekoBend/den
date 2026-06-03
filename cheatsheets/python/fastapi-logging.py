"""FastAPI + Uvicorn Logging — Copy-Paste Cheatsheet.

Configure logging so that FastAPI app logs and Uvicorn access/error logs
coexist without duplicates or missing lines.

Key Insight
===========
``uvicorn.run()`` **reconfigures the root logger by default**. If you set up
logging before calling ``uvicorn.run()``, your config is silently overwritten.

Solutions:
    1. Pass ``log_config=`` to ``uvicorn.run()`` with your own dictConfig.
    2. Pass ``log_config=None`` to disable uvicorn's reconfiguration,
       then configure logging yourself.

Quick-Reference Decision Table
==============================

| Pattern                   | Best For                        | Output          | Deps             |
|---------------------------|---------------------------------|-----------------|------------------|
| setup_uvicorn_basic       | Dev / quick start               | Console text    | uvicorn          |
| setup_uvicorn_json        | Log aggregators (ELK, Loki)     | JSON lines      | uvicorn          |
| setup_uvicorn_structlog   | Dev (colored) + prod (JSON)     | Colored / JSON  | uvicorn+structlog|
| setup_uvicorn_file        | File persistence + console      | Console + rot.  | uvicorn          |
| setup_middleware_logging   | Per-request metrics             | (any)           | fastapi          |

Usage:
    1. Copy the function you need into your project.
    2. Call it once **at application startup** (lifespan or before uvicorn.run).
    3. Use ``logging.getLogger(__name__)`` in every module for app logs.

Dependencies:
    pip install fastapi uvicorn[standard] structlog
"""

import logging

# =============================================================================
# 1. Basic — Console Text
# =============================================================================


def setup_uvicorn_basic(log_level: str = "info") -> dict[str, object]:
    """Return a uvicorn-compatible log_config dict with readable text output.

    [Best for] Development, quick debugging with readable console output.
    [Note] Pass the returned dict as ``log_config=`` to ``uvicorn.run()``.
           This replaces uvicorn's default config so your format is honored.
           App loggers (``logging.getLogger(__name__)``) inherit from root.

    Example::

        config = setup_uvicorn_basic()
        uvicorn.run("app:app", log_config=config)
    """
    log_config: dict[str, object] = {
        "version": 1,
        "disable_existing_loggers": False,
        "formatters": {
            "default": {
                "format": "%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
                "datefmt": "%Y-%m-%d %H:%M:%S",
            },
            "access": {
                "format": "%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
                "datefmt": "%Y-%m-%d %H:%M:%S",
            },
        },
        "handlers": {
            "default": {
                "class": "logging.StreamHandler",
                "formatter": "default",
                "stream": "ext://sys.stderr",
            },
            "access": {
                "class": "logging.StreamHandler",
                "formatter": "access",
                "stream": "ext://sys.stderr",
            },
        },
        "loggers": {
            "uvicorn": {
                "handlers": ["default"],
                "level": log_level.upper(),
                "propagate": False,
            },
            "uvicorn.error": {
                "handlers": ["default"],
                "level": log_level.upper(),
                "propagate": False,
            },
            "uvicorn.access": {
                "handlers": ["access"],
                "level": log_level.upper(),
                "propagate": False,
            },
        },
        "root": {
            "level": log_level.upper(),
            "handlers": ["default"],
        },
    }
    return log_config


# =============================================================================
# 2. Production JSON — Zero External Dependencies
# =============================================================================


def setup_uvicorn_json(log_level: str = "info") -> None:
    """Configure JSON-line logging and disable uvicorn's own log setup.

    [Best for] Feeding logs into aggregators (ELK, Loki, CloudWatch, Datadog).
    [Note] Both app logs and uvicorn access logs are emitted as JSON.
           Configures loggers directly and returns ``None`` so that
           ``uvicorn.run(log_config=None)`` skips its own reconfiguration.

    Example::

        setup_uvicorn_json()
        uvicorn.run("app:app", log_config=None)
    """
    import json
    import sys
    from datetime import datetime, timezone

    class JSONFormatter(logging.Formatter):
        """Emit each log record as a single JSON line."""

        def format(self, record: logging.LogRecord) -> str:
            log_entry: dict[str, str] = {
                "timestamp": datetime.fromtimestamp(
                    record.created, tz=timezone.utc
                ).isoformat(),
                "level": record.levelname,
                "logger": record.name,
                "message": record.getMessage(),
            }
            if record.exc_info and record.exc_info[0] is not None:
                log_entry["exception"] = self.formatException(record.exc_info)
            return json.dumps(log_entry, ensure_ascii=False)

    class AccessJSONFormatter(logging.Formatter):
        """Emit uvicorn access log records as JSON with request details.

        Note: uvicorn passes access info as positional args to ``%s`` format,
        so we use ``getMessage()`` which resolves the full access line.
        """

        def format(self, record: logging.LogRecord) -> str:
            log_entry: dict[str, str] = {
                "timestamp": datetime.fromtimestamp(
                    record.created, tz=timezone.utc
                ).isoformat(),
                "level": record.levelname,
                "logger": record.name,
                "message": record.getMessage(),
            }
            return json.dumps(log_entry, ensure_ascii=False)

    # Register formatters on the module so dictConfig can reference them
    _json_fmt = JSONFormatter()
    _access_json_fmt = AccessJSONFormatter()

    # Build handlers manually because dictConfig cannot reference local classes
    json_handler = logging.StreamHandler(sys.stderr)
    json_handler.setFormatter(_json_fmt)

    access_handler = logging.StreamHandler(sys.stderr)
    access_handler.setFormatter(_access_json_fmt)

    # Configure loggers directly; tell uvicorn not to reconfigure
    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(json_handler)
    root.setLevel(log_level.upper())

    uv_logger = logging.getLogger("uvicorn")
    uv_logger.handlers.clear()
    uv_logger.addHandler(json_handler)
    uv_logger.propagate = False

    uv_error = logging.getLogger("uvicorn.error")
    uv_error.handlers.clear()
    uv_error.addHandler(json_handler)
    uv_error.propagate = False

    uv_access = logging.getLogger("uvicorn.access")
    uv_access.handlers.clear()
    uv_access.addHandler(access_handler)
    uv_access.propagate = False

    # Return None to tell uvicorn.run() to skip its own log setup
    return None


# =============================================================================
# 3. structlog — Dev (Colored) + Prod (JSON)
# =============================================================================


def setup_uvicorn_structlog(dev_mode: bool = True) -> None:
    """Wire structlog for both app logs and uvicorn logs.

    [Best for] Teams that use structlog and want unified structured logging.
    [Note] Pass ``log_config=None`` to ``uvicorn.run()`` so uvicorn does not
           overwrite the config set here.

           Dev mode  → colored, human-readable console output.
           Prod mode → JSON lines for log aggregators.

    Example::

        setup_uvicorn_structlog(dev_mode=False)
        uvicorn.run("app:app", log_config=None)
    """
    import sys

    import structlog

    # Shared processors applied to both structlog and stdlib records
    shared_processors: list[structlog.types.Processor] = [
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
        structlog.processors.TimeStamper(fmt="iso"),
    ]

    # Final renderer depends on environment
    if dev_mode:
        renderer: structlog.types.Processor = structlog.dev.ConsoleRenderer()
    else:
        renderer = structlog.processors.JSONRenderer()

    # Configure structlog to route through stdlib
    structlog.configure(
        processors=[
            *shared_processors,
            structlog.stdlib.ProcessorFormatter.wrap_for_formatter,
        ],
        wrapper_class=structlog.stdlib.BoundLogger,
        context_class=dict,
        logger_factory=structlog.stdlib.LoggerFactory(),
        cache_logger_on_first_use=True,
    )

    # Build a ProcessorFormatter that handles both structlog and stdlib records
    formatter = structlog.stdlib.ProcessorFormatter(
        processors=[
            structlog.stdlib.ProcessorFormatter.remove_processors_meta,
            renderer,
        ],
        foreign_pre_chain=shared_processors,
    )

    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(formatter)

    # Wire root logger (catches app + library logs)
    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(logging.DEBUG)

    # Wire uvicorn loggers so they flow through structlog's formatter
    for logger_name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        uv_logger = logging.getLogger(logger_name)
        uv_logger.handlers.clear()
        uv_logger.addHandler(handler)
        uv_logger.propagate = False


# =============================================================================
# 4. File + Console — Rotating Logs
# =============================================================================


def setup_uvicorn_file(
    app_log_path: str = "app.log",
    access_log_path: str = "access.log",
    log_level: str = "info",
) -> None:
    """Configure app logs and access logs to separate rotating files + console.

    [Best for] Deployments that log to disk (VMs, on-prem, Docker volumes).
    [Note] Pass ``log_config=None`` to ``uvicorn.run()`` so uvicorn does not
           overwrite the config set here. Files rotate at 10 MB, keeping 5 backups.

    Example::

        setup_uvicorn_file(app_log_path="/var/log/myapp/app.log")
        uvicorn.run("app:app", log_config=None)
    """
    import sys
    from logging.handlers import RotatingFileHandler

    level = getattr(logging, log_level.upper(), logging.INFO)

    default_fmt = logging.Formatter(
        fmt="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    access_fmt = logging.Formatter(
        fmt="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    # --- Console handler (stderr) ---
    console_handler = logging.StreamHandler(sys.stderr)
    console_handler.setLevel(level)
    console_handler.setFormatter(default_fmt)

    # --- App file handler (rotating) ---
    app_file_handler = RotatingFileHandler(
        app_log_path,
        maxBytes=10_485_760,  # 10 MB
        backupCount=5,
        encoding="utf-8",
    )
    app_file_handler.setLevel(level)
    app_file_handler.setFormatter(default_fmt)

    # --- Access file handler (rotating) ---
    access_file_handler = RotatingFileHandler(
        access_log_path,
        maxBytes=10_485_760,
        backupCount=5,
        encoding="utf-8",
    )
    access_file_handler.setLevel(level)
    access_file_handler.setFormatter(access_fmt)

    # Root logger — app logs go here
    root = logging.getLogger()
    root.handlers.clear()
    root.setLevel(level)
    root.addHandler(console_handler)
    root.addHandler(app_file_handler)

    # Uvicorn error logger
    uv_error = logging.getLogger("uvicorn.error")
    uv_error.handlers.clear()
    uv_error.addHandler(console_handler)
    uv_error.addHandler(app_file_handler)
    uv_error.propagate = False

    # Uvicorn access logger — separate file
    uv_access = logging.getLogger("uvicorn.access")
    uv_access.handlers.clear()
    uv_access.addHandler(console_handler)
    uv_access.addHandler(access_file_handler)
    uv_access.propagate = False


# =============================================================================
# 5. Middleware — Request/Response Logging
# =============================================================================


def setup_middleware_logging(app: object) -> None:
    """Add request/response logging middleware to a FastAPI app.

    [Best for] Observability: log method, path, status code, and duration
               for every request. Works with any logging config above.
    [Note] This adds an ASGI middleware. Apply it once at startup.
           For lifespan apps, add it after creating the FastAPI instance.

    Example::

        from fastapi import FastAPI
        app = FastAPI()
        setup_middleware_logging(app)
    """
    import time

    from fastapi import FastAPI, Request, Response

    if not isinstance(app, FastAPI):
        raise TypeError(f"Expected FastAPI instance, got {type(app).__name__}")

    logger = logging.getLogger("middleware.access")

    @app.middleware("http")
    async def log_requests(request: Request, call_next) -> Response:
        start = time.perf_counter()
        response: Response = Response(status_code=500)
        try:
            response = await call_next(request)
        except Exception:
            logger.exception(
                "Unhandled exception | %s %s",
                request.method,
                request.url.path,
            )
            raise
        finally:
            duration_ms = (time.perf_counter() - start) * 1000
            logger.info(
                "%s %s → %d (%.1fms)",
                request.method,
                request.url.path,
                response.status_code,
                duration_ms,
            )
        return response


# =============================================================================
# Example main.py — Wiring It All Together
# =============================================================================

if __name__ == "__main__":
    import logging

    import uvicorn
    from fastapi import FastAPI

    # ------------------------------------------------------------------
    # Pick ONE of the setups below. Uncomment the one you want.
    # ------------------------------------------------------------------

    # --- Option A: Basic text (dev) ---
    log_config = setup_uvicorn_basic(log_level="debug")
    # Pass log_config to uvicorn.run() below.

    # --- Option B: JSON (production, no deps) ---
    # setup_uvicorn_json(log_level="info")
    # log_config = None  # Tell uvicorn not to reconfigure

    # --- Option C: structlog (dev colored) ---
    # setup_uvicorn_structlog(dev_mode=True)
    # log_config = None

    # --- Option D: structlog (prod JSON) ---
    # setup_uvicorn_structlog(dev_mode=False)
    # log_config = None

    # --- Option E: File + console ---
    # setup_uvicorn_file(app_log_path="app.log", access_log_path="access.log")
    # log_config = None

    # ------------------------------------------------------------------
    # Build app
    # ------------------------------------------------------------------
    app = FastAPI(title="Logging Demo")

    # Add request/response middleware (works with any config above)
    setup_middleware_logging(app)

    logger = logging.getLogger(__name__)

    @app.get("/")
    async def root() -> dict[str, str]:
        logger.info("Handling root request")
        return {"message": "hello"}

    @app.get("/error")
    async def error_demo() -> dict[str, str]:
        from fastapi import HTTPException

        logger.warning("About to raise an error")
        raise HTTPException(status_code=500, detail="demo error")

    # ------------------------------------------------------------------
    # Run uvicorn
    # ------------------------------------------------------------------
    # Key: log_config controls whether uvicorn reconfigures logging.
    #   - dict   → uvicorn uses YOUR config (Option A)
    #   - None   → uvicorn skips reconfiguration (Options B–E)
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=8000,
        log_config=log_config,
        log_level="debug",
    )
