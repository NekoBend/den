"""cheatsheets/python/{logging-config,fastapi-logging}.py: safe production defaults.

The sheets' names have hyphens, so they are loaded from their paths. Every test
restores the root logger (and the loggers the recipes touch) afterwards.
"""

import ast
import importlib.util
import io
import logging
from collections.abc import Iterator
from pathlib import Path
from types import ModuleType

import pytest

SHEETS = Path(__file__).resolve().parents[2] / "cheatsheets" / "python"
NOISY = ("urllib3", "httpx", "httpcore", "botocore")
TOUCHED = (*NOISY, "app", "uvicorn", "uvicorn.error", "uvicorn.access")


def _load(filename: str) -> ModuleType:
    name = "cheatsheet_" + filename.removesuffix(".py").replace("-", "_")
    spec = importlib.util.spec_from_file_location(name, SHEETS / filename)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def restore_logging() -> Iterator[None]:
    root = logging.getLogger()
    saved_root = (root.level, root.handlers[:])
    saved = {
        name: (logger.level, logger.handlers[:], logger.propagate)
        for name in TOUCHED
        for logger in [logging.getLogger(name)]
    }
    yield
    for handler in root.handlers:
        if handler not in saved_root[1]:
            handler.close()
    root.setLevel(saved_root[0])
    root.handlers[:] = saved_root[1]
    for name, (level, handlers, propagate) in saved.items():
        logger = logging.getLogger(name)
        for handler in logger.handlers:
            if handler not in handlers:
                handler.close()
        logger.setLevel(level)
        logger.handlers[:] = handlers
        logger.propagate = propagate


def _emit_sample() -> None:
    logging.getLogger("urllib3.connectionpool").debug(
        'http://127.0.0.1 "GET /v1/geocode?key=SECRET-KEY HTTP/1.1" 200 None'
    )
    logging.getLogger("httpx").info("HTTP Request: GET /?sig=SECRET-SIG 200 OK")
    logging.getLogger("thirdparty").debug("library chatter")
    logging.getLogger("app").info("app info line")


# --- logging-config.py: production recipes ------------------------------------


def test_setup_json_format_keeps_library_debug_and_url_secrets_out(
    restore_logging, capsys
):
    sheet = _load("logging-config.py")
    sheet.setup_json_format()
    _emit_sample()
    err = capsys.readouterr().err
    assert "app info line" in err
    assert "SECRET" not in err
    assert "library chatter" not in err
    assert logging.getLogger().level == logging.INFO


def test_setup_json_format_lets_the_app_logger_opt_into_debug(restore_logging, capsys):
    sheet = _load("logging-config.py")
    sheet.setup_json_format()
    logging.getLogger("app").setLevel(logging.DEBUG)
    logging.getLogger("app").debug("app debug line")
    assert "app debug line" in capsys.readouterr().err


def test_setup_dictconfig_keeps_library_debug_and_url_secrets_out(
    restore_logging, capsys, tmp_path
):
    sheet = _load("logging-config.py")
    sheet.setup_dictconfig(log_path=str(tmp_path / "app.log"))
    _emit_sample()
    logging.getLogger("app").setLevel(logging.DEBUG)
    logging.getLogger("app").debug("app debug line")
    err = capsys.readouterr().err
    assert "app info line" in err
    assert "app debug line" in err
    assert "SECRET" not in err
    assert "library chatter" not in err


@pytest.mark.parametrize(
    ("filename", "recipe"),
    [
        ("fastapi-logging.py", "setup_uvicorn_json"),
        ("fastapi-logging.py", "setup_uvicorn_file"),
        ("logging-config.py", "setup_structlog_with_stdlib"),
    ],
)
def test_info_level_recipes_keep_http_client_urls_out(
    restore_logging, capsys, tmp_path, monkeypatch, filename, recipe
):
    # These run at INFO, where httpx logs every request with the whole URL:
    # the query-string secret reached stderr and the log files.
    structlog = None
    if recipe == "setup_structlog_with_stdlib":
        structlog = pytest.importorskip("structlog")
    monkeypatch.chdir(tmp_path)  # setup_uvicorn_file writes app.log, access.log
    sheet = _load(filename)
    try:
        getattr(sheet, recipe)()
        _emit_sample()
    finally:
        if structlog is not None:
            structlog.reset_defaults()
    err = capsys.readouterr().err
    assert "app info line" in err
    assert "SECRET" not in err
    for log in tmp_path.glob("*.log"):
        assert "SECRET" not in log.read_text(encoding="utf-8")
    for name in NOISY:
        assert logging.getLogger(name).level == logging.WARNING


def _rich_handler_output(sheet: ModuleType) -> io.StringIO:
    pytest.importorskip("rich")
    from rich.console import Console
    from rich.logging import RichHandler

    sheet.setup_rich_logging()
    (handler,) = [h for h in logging.getLogger().handlers if isinstance(h, RichHandler)]
    sink = io.StringIO()
    handler.console = Console(file=sink, width=200)
    return sink


def test_setup_rich_logging_prints_bracketed_text_as_is(restore_logging):
    # markup=True made "[/admin]" raise MarkupError out of the logging call and
    # made tag-like text such as SQLAlchemy's "[generated in ...]" vanish.
    sheet = _load("logging-config.py")
    sink = _rich_handler_output(sheet)
    logging.getLogger("app").warning("user supplied tag: %s", "[/admin]")
    logging.getLogger("sqlalchemy.engine.Engine").info("[generated in 0.00015s] x")
    out = sink.getvalue()
    assert "user supplied tag: [/admin]" in out
    assert "[generated in 0.00015s] x" in out


def _connect_with_a_credential() -> None:
    # Built at run time: the traceback's source excerpt must not contain the
    # value, only a locals panel would.
    db_credential = "-".join(["hunter2", "S3cr3t", "Pa55"])
    raise ConnectionError("db down: " + str(len(db_credential)))


def test_setup_rich_logging_does_not_print_frame_locals(restore_logging):
    sheet = _load("logging-config.py")
    sink = _rich_handler_output(sheet)
    try:
        _connect_with_a_credential()
    except ConnectionError:
        logging.getLogger("app").exception("db connect failed")
    out = sink.getvalue()
    assert "db connect failed" in out
    assert "hunter2-S3cr3t-Pa55" not in out


# --- fastapi-logging.py ---------------------------------------------------------


@pytest.mark.parametrize(
    ("kwargs", "level"),
    [
        ({"dev_mode": False}, logging.INFO),
        ({"dev_mode": True}, logging.DEBUG),
        ({"dev_mode": False, "log_level": "warning"}, logging.WARNING),
    ],
)
def test_setup_uvicorn_structlog_root_level(restore_logging, kwargs, level):
    structlog = pytest.importorskip("structlog")
    sheet = _load("fastapi-logging.py")
    try:
        sheet.setup_uvicorn_structlog(**kwargs)
        assert logging.getLogger().level == level
        if not kwargs["dev_mode"]:
            for name in NOISY:
                assert logging.getLogger(name).level == logging.WARNING
    finally:
        structlog.reset_defaults()


def _module_function(tree: ast.Module, name: str) -> ast.FunctionDef:
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    raise AssertionError(f"{name} is missing")


def test_fastapi_sheet_sets_up_logging_inside_the_server_process():
    # uvicorn's reload and workers>1 serve from spawned processes that import
    # the app module but never run the launcher's `if __name__ == "__main__":`,
    # so Options B-E (log_config=None) must not set up logging only there.
    path = SHEETS / "fastapi-logging.py"
    source = path.read_text(encoding="utf-8")
    tree = ast.parse(source)
    (main_guard,) = [
        node
        for node in tree.body
        if isinstance(node, ast.If) and "__main__" in ast.unparse(node.test)
    ]
    main_source = ast.get_source_segment(source, main_guard) or ""
    factory_source = (
        ast.get_source_segment(source, _module_function(tree, "create_app")) or ""
    )
    for call in (
        "setup_uvicorn_json(",
        "setup_uvicorn_structlog(",
        "setup_uvicorn_file(",
    ):
        assert call not in main_source
        assert call in factory_source
    assert "factory=True" in main_source


def test_fastapi_key_insight_matches_uvicorn():
    # uvicorn's LOGGING_CONFIG has no "root" key; it never reconfigured root.
    doc = ast.get_docstring(
        ast.parse((SHEETS / "fastapi-logging.py").read_text("utf-8"))
    )
    assert doc is not None
    assert "reconfigures the root logger" not in doc
    assert "workers>1" in doc
