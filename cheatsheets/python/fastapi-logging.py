"""FastAPI + Uvicorn Logging — Copy-Paste Cheatsheet.

Configure logging so that FastAPI app logs and Uvicorn access/error logs
coexist without duplicates or missing lines.

Key Insight
===========
Unless you pass ``log_config=``, ``uvicorn.run()`` applies its own
``LOGGING_CONFIG`` with ``dictConfig``. That config has no ``"root"`` key, so
your root handlers stay; it configures only the ``uvicorn``,
``uvicorn.error`` and ``uvicorn.access`` loggers, with handlers on
``uvicorn`` and ``uvicorn.access``, neither of which propagates. uvicorn's
lines therefore never reach your root handlers, and whatever you attached to
those three loggers before ``uvicorn.run()`` is replaced.

With ``reload=True`` or ``workers>1`` the server runs in freshly spawned
processes. Each one applies ``log_config`` again and imports your app module,
but none runs your ``if __name__ == "__main__":`` block: logging set up only
there is missing exactly where the requests are served.

Solutions:
    1. Pass ``log_config=`` to ``uvicorn.run()`` with your own dictConfig
       (Option A); uvicorn applies it in every server process.
    2. Pass ``log_config=None`` and call a ``setup_*`` function inside the
       server process: in an app factory (``create_app`` below, run with
       ``factory=True``) or at import time of the module that defines ``app``.

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
    2. Option A: pass the returned dict as ``log_config=``. Options B-E: call
       it once in the server process (app factory or app-module scope, see
       Key Insight), never only under ``if __name__ == "__main__":``.
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
           Call it in the server process (see the module Key Insight).

    Example::

        # app.py: imported by every server process, reload and workers too
        setup_uvicorn_json()
        app = FastAPI()

        # launcher
        uvicorn.run("app:app", log_config=None, workers=2)
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


def setup_uvicorn_structlog(
    dev_mode: bool = True, log_level: str | None = None
) -> None:
    """Wire structlog for both app logs and uvicorn logs.

    [Best for] Teams that use structlog and want unified structured logging.
    [Note] Pass ``log_config=None`` to ``uvicorn.run()`` so uvicorn does not
           overwrite the config set here, and call it in the server process
           (see the module Key Insight).

           Dev mode  → colored, human-readable console output.
           Prod mode → JSON lines for log aggregators.

           ``log_level`` defaults to "debug" in dev mode and "info" in prod
           mode. In prod mode the chatty HTTP clients (urllib3, httpx,
           httpcore, botocore) are pinned to WARNING: their DEBUG/INFO
           records carry whole request URLs, query-string secrets included.

    Example::

        # app.py: imported by every server process, reload and workers too
        setup_uvicorn_structlog(dev_mode=False)
        app = FastAPI()

        # launcher
        uvicorn.run("app:app", log_config=None, workers=2)
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
    root.setLevel((log_level or ("debug" if dev_mode else "info")).upper())
    if not dev_mode:
        for name in ("urllib3", "httpx", "httpcore", "botocore"):
            logging.getLogger(name).setLevel(logging.WARNING)

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
           Call it in the server process (see the module Key Insight). With
           ``workers>1`` every worker rotates the same files on its own and
           they clobber each other: give each worker its own file (e.g. put
           ``os.getpid()`` in the name) or rotate externally with
           ``WatchedFileHandler`` + logrotate.

    Example::

        # app.py: imported by every server process, reload and workers too
        setup_uvicorn_file(app_log_path="/var/log/myapp/app.log")
        app = FastAPI()

        # launcher
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
# Example app - Wiring It All Together
# =============================================================================


def create_app() -> object:
    """Build the demo app, setting up logging in the process that serves it.

    [Note] With ``log_config=None`` (Options B-E) the setup call belongs here:
           uvicorn calls the factory (``factory=True``) in every server
           process, including the spawned ones behind ``reload=True`` and
           ``workers>1``. Module scope of your ``app.py`` works the same way.
           Option A needs no call here: uvicorn applies a ``log_config`` dict
           in every process itself.

    Example::

        uvicorn.run("app:create_app", factory=True, log_config=None, workers=2)
    """
    from fastapi import FastAPI, HTTPException

    # ------------------------------------------------------------------
    # Options B-E: uncomment ONE, and pass log_config=None to uvicorn.run().
    # ------------------------------------------------------------------
    # setup_uvicorn_json(log_level="info")  # B: JSON (production, no deps)
    # setup_uvicorn_structlog(dev_mode=True)  # C: structlog (dev colored)
    # setup_uvicorn_structlog(dev_mode=False)  # D: structlog (prod JSON)
    # setup_uvicorn_file(app_log_path="app.log", access_log_path="access.log")  # E

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
        logger.warning("About to raise an error")
        raise HTTPException(status_code=500, detail="demo error")

    return app


if __name__ == "__main__":
    import uvicorn

    # --- Option A: Basic text (dev) ---
    # A log_config dict is applied by uvicorn in every server process.
    log_config = setup_uvicorn_basic(log_level="debug")

    # --- Options B-E: uncomment ONE setup call in create_app(), then ---
    # log_config = None

    # This file's name has a hyphen, so the demo hands uvicorn the app object
    # (one process). In your project pass an import string, which reload and
    # workers need:
    #   uvicorn.run("app:create_app", factory=True, log_config=log_config, workers=2)
    uvicorn.run(
        create_app(),
        host="0.0.0.0",
        port=8000,
        log_config=log_config,
        log_level="debug",
    )
