"""Logging Configuration — Copy-Paste Cheatsheet.

Complete matrix: Backend × Output Format × Use Case.

Quick-Reference Decision Table
==============================

| Pattern                    | Best For                        | Library           | Output          |
|----------------------------|---------------------------------|-------------------|-----------------|
| setup_basic                | Scripts, quick debugging        | stdlib logging    | Console text    |
| setup_basic_file           | Scripts with file persistence   | stdlib logging    | Console + file  |
| setup_dictconfig           | Production apps (stdlib only)   | stdlib logging    | Console + rot.  |
| setup_json_format          | Log aggregators (no deps)       | stdlib logging    | JSON lines      |
| setup_structlog_dev        | Dev-time colored output         | structlog         | Colored console |
| setup_structlog_prod       | Production structured logs      | structlog         | JSON lines      |
| setup_structlog_with_stdlib| Unify app + library logs        | structlog+stdlib  | JSON lines      |
| setup_rich_logging         | Pretty CLI / debug sessions     | rich              | Rich console    |
| setup_level_filter         | Split levels across handlers    | stdlib logging    | Console + file  |
| setup_context_vars         | Request/user tracking           | stdlib+contextvars| Console text    |

Usage:
    1. Copy the function you need into your project.
    2. Call it once at application startup (before any log calls).
    3. Use ``logging.getLogger(__name__)`` in every module.

Dependencies:
    pip install structlog rich
"""

import contextvars
import logging

# =============================================================================
# 1. stdlib logging — Basic
# =============================================================================


def setup_basic(level: int = logging.DEBUG) -> None:
    """Configure basicConfig with format, level, and stderr output.

    [Best for] Quick scripts, one-off debugging.
    [Note] Call once at the top of your script. Second calls are silently ignored.
    """
    import sys

    logging.basicConfig(
        level=level,
        format="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        stream=sys.stderr,
    )


def setup_basic_file(log_path: str = "app.log") -> None:
    """Configure logging to both console (stderr) and a file.

    [Best for] Scripts that need persistent logs without complex config.
    [Note] Uses explicit handlers because basicConfig only accepts one stream.
    """
    import logging
    import sys

    formatter = logging.Formatter(
        fmt="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    console_handler = logging.StreamHandler(sys.stderr)
    console_handler.setLevel(logging.DEBUG)
    console_handler.setFormatter(formatter)

    file_handler = logging.FileHandler(log_path, encoding="utf-8")
    file_handler.setLevel(logging.INFO)
    file_handler.setFormatter(formatter)

    root = logging.getLogger()
    root.setLevel(logging.DEBUG)
    root.addHandler(console_handler)
    root.addHandler(file_handler)


# =============================================================================
# 2. stdlib logging — Advanced
# =============================================================================


def setup_dictconfig(log_path: str = "app.log") -> None:
    """Configure logging via dictConfig — formatters, handlers, loggers.

    [Best for] Production apps that only use stdlib (no external deps).
    [Note] RotatingFileHandler prevents unbounded log growth.
           Adjust maxBytes/backupCount to your disk budget.
    """
    import logging.config

    config = {
        "version": 1,
        "disable_existing_loggers": False,
        "formatters": {
            "standard": {
                "format": "%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
                "datefmt": "%Y-%m-%d %H:%M:%S",
            },
        },
        "handlers": {
            "console": {
                "class": "logging.StreamHandler",
                "level": "DEBUG",
                "formatter": "standard",
                "stream": "ext://sys.stderr",
            },
            "file": {
                "class": "logging.handlers.RotatingFileHandler",
                "level": "INFO",
                "formatter": "standard",
                "filename": log_path,
                "maxBytes": 10_485_760,  # 10 MB
                "backupCount": 5,
                "encoding": "utf-8",
            },
        },
        "root": {
            "level": "DEBUG",
            "handlers": ["console", "file"],
        },
    }
    logging.config.dictConfig(config)


def setup_json_format() -> None:
    """Configure JSON-line log output — zero external dependencies.

    [Best for] Feeding logs into aggregators (ELK, Loki, CloudWatch).
    [Note] Override Formatter.format to emit one JSON object per line.
           Add extra fields (service, version) as needed.
    """
    import json
    import logging
    import sys
    from datetime import datetime, timezone

    class JSONFormatter(logging.Formatter):
        """Emit each log record as a single JSON line."""

        def format(self, record: logging.LogRecord) -> str:
            log_entry = {
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

    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(JSONFormatter())

    root = logging.getLogger()
    root.setLevel(logging.DEBUG)
    root.addHandler(handler)


# =============================================================================
# 3. structlog
# =============================================================================


def setup_structlog_dev() -> None:
    """Configure structlog for development — colored, human-readable output.

    [Best for] Local development, interactive debugging.
    [Note] ConsoleRenderer adds colors, padded levels, and key=value pairs.
    """
    import structlog

    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.processors.add_log_level,
            structlog.processors.StackInfoRenderer(),
            structlog.dev.set_exc_info,
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.dev.ConsoleRenderer(),
        ],
        wrapper_class=structlog.make_filtering_bound_logger(min_level=10),
        context_class=dict,
        logger_factory=structlog.PrintLoggerFactory(),
        cache_logger_on_first_use=True,
    )


def setup_structlog_prod() -> None:
    """Configure structlog for production — JSON output.

    [Best for] Production services feeding into log aggregators.
    [Note] JSONRenderer emits one JSON object per line, machine-parseable.
    """
    import structlog

    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.processors.add_log_level,
            structlog.processors.StackInfoRenderer(),
            structlog.processors.format_exc_info,
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.processors.JSONRenderer(),
        ],
        wrapper_class=structlog.make_filtering_bound_logger(min_level=20),
        context_class=dict,
        logger_factory=structlog.PrintLoggerFactory(),
        cache_logger_on_first_use=True,
    )


def setup_structlog_with_stdlib(log_level: int = 20) -> None:
    """Bridge structlog to stdlib logging — unifies app + library logs.

    [Best for] Apps using structlog that also need library logs (urllib3, sqlalchemy)
               to flow through the same pipeline.
    [Note] stdlib loggers are captured by structlog's ProcessorFormatter,
           so everything gets the same structured output.
    """
    import logging
    import sys

    import structlog

    # Shared processors for both structlog and stdlib log records
    shared_processors: list[structlog.types.Processor] = [
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
        structlog.processors.TimeStamper(fmt="iso"),
    ]

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

    # Configure stdlib to use structlog's formatter
    formatter = structlog.stdlib.ProcessorFormatter(
        processors=[
            structlog.stdlib.ProcessorFormatter.remove_processors_meta,
            structlog.processors.JSONRenderer(),
        ],
        foreign_pre_chain=shared_processors,
    )

    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(formatter)

    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(log_level)


# =============================================================================
# 4. rich
# =============================================================================


def setup_rich_logging(log_level: int = 10) -> None:
    """Configure stdlib logging with Rich — pretty tracebacks and markup.

    [Best for] CLI tools, dev servers, anything user-facing in the terminal.
    [Note] RichHandler renders tracebacks in color and supports [markup].
           Set rich_tracebacks=False if you parse logs downstream.
    """
    import logging

    from rich.logging import RichHandler

    handler = RichHandler(
        level=log_level,
        show_time=True,
        show_path=True,
        rich_tracebacks=True,
        tracebacks_show_locals=True,
        markup=True,
    )

    root = logging.getLogger()
    root.setLevel(log_level)
    root.handlers.clear()
    root.addHandler(handler)


# =============================================================================
# 5. Patterns
# =============================================================================


def setup_level_filter() -> None:
    """Route log levels to different handlers — WARNING+ to file, all to console.

    [Best for] Separating noisy debug output from actionable warnings/errors.
    [Note] Custom Filter on the file handler rejects records below WARNING.
    """
    import logging
    import sys

    class MinLevelFilter(logging.Filter):
        """Only allow records at or above the given level."""

        def __init__(self, level: int) -> None:
            super().__init__()
            self.min_level = level

        def filter(self, record: logging.LogRecord) -> bool:
            return record.levelno >= self.min_level

    formatter = logging.Formatter(
        fmt="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    console_handler = logging.StreamHandler(sys.stderr)
    console_handler.setLevel(logging.DEBUG)
    console_handler.setFormatter(formatter)

    file_handler = logging.FileHandler("warnings.log", encoding="utf-8")
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(formatter)
    file_handler.addFilter(MinLevelFilter(logging.WARNING))

    root = logging.getLogger()
    root.setLevel(logging.DEBUG)
    root.addHandler(console_handler)
    root.addHandler(file_handler)


request_id_var: contextvars.ContextVar[str] = contextvars.ContextVar(
    "request_id", default="-"
)
user_id_var: contextvars.ContextVar[str] = contextvars.ContextVar(
    "user_id", default="-"
)


def setup_context_vars() -> tuple[
    contextvars.ContextVar[str], contextvars.ContextVar[str]
]:
    """Inject request_id / user_id into every log record via contextvars.

    [Best for] Web apps / async services that need per-request tracing.
    [Note] Set the context vars at the start of each request (middleware).
           The Filter reads them and attaches to every log record automatically.

    Returns:
        Tuple of ``(request_id_var, user_id_var)`` so callers can ``.set()``
        values in middleware or request handlers.

    Example::

        req_var, user_var = setup_context_vars()
        req_var.set("abc-123")
        user_var.set("user_42")
    """
    import logging
    import sys

    class ContextVarsFilter(logging.Filter):
        """Attach contextvars values to every log record."""

        def filter(self, record: logging.LogRecord) -> bool:
            record.request_id = request_id_var.get()
            record.user_id = user_id_var.get()
            return True

    formatter = logging.Formatter(
        fmt=(
            "%(asctime)s | %(levelname)-8s | %(name)s "
            "| req=%(request_id)s user=%(user_id)s | %(message)s"
        ),
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(formatter)
    handler.addFilter(ContextVarsFilter())

    root = logging.getLogger()
    root.setLevel(logging.DEBUG)
    root.addHandler(handler)

    return request_id_var, user_id_var


# =============================================================================
# Quick Sanity Check
# =============================================================================

if __name__ == "__main__":
    import logging

    def _reset_logging() -> None:
        """Reset root logger between demos so handlers don't stack."""
        root = logging.getLogger()
        root.handlers.clear()
        root.setLevel(logging.WARNING)
        # Reset structlog if loaded
        try:
            import structlog

            structlog.reset_defaults()
        except ImportError:
            pass

    def _demo_logs(label: str) -> None:
        """Emit sample log records at every level."""
        log = logging.getLogger("demo")
        print(f"\n{'=' * 60}")
        print(f"  {label}")
        print(f"{'=' * 60}")
        log.debug("This is a DEBUG message")
        log.info("This is an INFO message")
        log.warning("This is a WARNING message")
        log.error("This is an ERROR message, value=%d", 42)

    def _demo_structlog(label: str) -> None:
        """Emit sample structlog records."""
        import structlog

        log = structlog.get_logger("demo")
        print(f"\n{'=' * 60}")
        print(f"  {label}")
        print(f"{'=' * 60}")
        log.debug("structlog debug", key="value")
        log.info("structlog info", count=42)
        log.warning("structlog warning")
        log.error("structlog error", err="something broke")

    # --- 1. Basic ---
    _reset_logging()
    setup_basic()
    _demo_logs("setup_basic — basicConfig to stderr")

    # --- 2. Basic File ---
    _reset_logging()
    setup_basic_file(log_path="demo.log")
    _demo_logs("setup_basic_file — console + file")

    # --- 3. dictConfig ---
    _reset_logging()
    setup_dictconfig(log_path="demo_dict.log")
    _demo_logs("setup_dictconfig — dictConfig with rotating file")

    # --- 4. JSON format ---
    _reset_logging()
    setup_json_format()
    _demo_logs("setup_json_format — JSON lines (no deps)")

    # --- 5. structlog dev ---
    _reset_logging()
    try:
        setup_structlog_dev()
        _demo_structlog("setup_structlog_dev — colored console")
    except ImportError:
        print("\n  [SKIP] structlog not installed")

    # --- 6. structlog prod ---
    _reset_logging()
    try:
        setup_structlog_prod()
        _demo_structlog("setup_structlog_prod — JSON output")
    except ImportError:
        print("\n  [SKIP] structlog not installed")

    # --- 7. structlog + stdlib ---
    _reset_logging()
    try:
        setup_structlog_with_stdlib()
        _demo_logs("setup_structlog_with_stdlib — bridged to stdlib")
    except ImportError:
        print("\n  [SKIP] structlog not installed")

    # --- 8. Rich ---
    _reset_logging()
    try:
        setup_rich_logging()
        _demo_logs("setup_rich_logging — pretty console")
    except ImportError:
        print("\n  [SKIP] rich not installed")

    # --- 9. Level filter ---
    _reset_logging()
    setup_level_filter()
    _demo_logs("setup_level_filter — WARNING+ to file")

    # --- 10. Context vars ---
    _reset_logging()
    setup_context_vars()
    _demo_logs("setup_context_vars — request_id/user_id injection")

    # --- Cleanup temp files ---
    import pathlib

    for f in ("demo.log", "demo_dict.log", "warnings.log"):
        pathlib.Path(f).unlink(missing_ok=True)

    print(f"\n{'=' * 60}")
    print("  All sanity checks passed.")
    print(f"{'=' * 60}")
