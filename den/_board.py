"""den board - a per-project localhost board for user-side debug reports.

`den board` serves a single page where the user records observations while
exercising the thing under test (a game, a build, a device): press a button,
optionally attach a note. Each report is appended as one JSON line
({ts, button, text}) to <project>/.den/board/reports.jsonl. Agents never
talk to the server - they read that file directly - so the board replaces
the chat round-trips of "run it again and tell me what happened".

Multiple boards coexist by design: every project has its own server, file,
and lock. The preferred port (8484) falls back to the next free one, a
second `den board` in the same project finds the live instance and just
reprints its URL, and the page titles itself after the project so parallel
tabs stay distinguishable.

Usage:
  den board [--port N] [--open] [--dir PATH]

Files under <project>/.den/board/:
  board.json     title, preferred port, button set (edit freely)
  reports.jsonl  one JSON line per report - the agent-facing surface
  server.json    pid + port of the live server (removed on exit)
"""

from __future__ import annotations

import http.client
import json
import os
import sys
import threading
import webbrowser
from contextlib import suppress
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import cast
from urllib.parse import parse_qs, urlparse

from . import __version__
from ._memory import _find_den_dir

_PREFERRED_PORT = 8484
_PORT_TRIES = 20
_PING_TIMEOUT_S = 0.6
_MAX_BODY_BYTES = 64 * 1024
_MAX_BUTTON_LEN = 64
_MAX_TEXT_LEN = 16000
_MAX_LIST_LIMIT = 500
_MAX_LIST_BYTES = 512 * 1024
_MAX_PORT = 65535

_DEFAULT_CONFIG: dict[str, object] = {
    "title": None,
    "port": _PREFERRED_PORT,
    "buttons": [
        {"id": "bug", "label": "Bug", "color": "#d03b3b"},
        {"id": "odd", "label": "Odd", "color": "#b8860b"},
        {"id": "idea", "label": "Idea", "color": "#2a78d6"},
        {"id": "note", "label": "Note", "color": "#6e6d66"},
        {"id": "ok", "label": "OK", "color": "#0ca30c"},
    ],
}


def _board_dir(root: Path) -> Path:
    return root / ".den" / "board"


def _reports_path(root: Path) -> Path:
    return _board_dir(root) / "reports.jsonl"


def _lock_path(root: Path) -> Path:
    return _board_dir(root) / "server.json"


def ensure_scaffold(root: Path) -> dict[str, object]:
    """Create .den/board/board.json with defaults; never clobber edits."""
    cfg_path = _board_dir(root) / "board.json"
    if not cfg_path.is_file():
        cfg_path.parent.mkdir(parents=True, exist_ok=True)
        cfg_path.write_text(
            json.dumps(_DEFAULT_CONFIG, indent=2) + "\n", encoding="utf-8"
        )
    try:
        loaded = json.loads(cfg_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"den board: unreadable {cfg_path}: {exc}", file=sys.stderr)
        return dict(_DEFAULT_CONFIG)
    if not isinstance(loaded, dict):
        print(f"den board: {cfg_path} is not a JSON object", file=sys.stderr)
        return dict(_DEFAULT_CONFIG)
    return {**_DEFAULT_CONFIG, **loaded}


def _tail_lines(path: Path, max_bytes: int) -> list[str]:
    """Last complete lines within the trailing max_bytes of the file, so a
    long-lived board never loads an unbounded file per 5s poll."""
    try:
        with path.open("rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - max_bytes))
            data = f.read()
    except OSError:
        return []
    lines = data.decode("utf-8", errors="replace").splitlines()
    if size > max_bytes and lines:
        return lines[1:]  # the first line in the window is a partial one
    return lines


def _title(root: Path, config: dict[str, object]) -> str:
    title = config.get("title")
    return title if isinstance(title, str) and title.strip() else root.name


def _existing_instance(root: Path) -> str | None:
    """URL of a live server for this root, else None (clearing stale locks)."""
    lock = _lock_path(root)
    try:
        info = json.loads(lock.read_text(encoding="utf-8"))
        port = int(info["port"])
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
        return None
    with suppress(OSError, ValueError, json.JSONDecodeError):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=_PING_TIMEOUT_S)
        try:
            conn.request("GET", "/api/ping")
            resp = conn.getresponse()
            data = json.loads(resp.read().decode("utf-8"))
        finally:
            conn.close()
        if data.get("den_board") and data.get("root") == str(root):
            return f"http://127.0.0.1:{port}/"
    with suppress(OSError):
        lock.unlink()
    return None


def _release_lock(root: Path) -> None:
    """Remove the lock only if this process owns it (a concurrent start may
    have overwritten it; deleting a twin's lock would orphan that server)."""
    lock = _lock_path(root)
    with suppress(OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
        info = json.loads(lock.read_text(encoding="utf-8"))
        if int(info.get("pid", -1)) == os.getpid():
            lock.unlink()


class _BoardServer(ThreadingHTTPServer):
    """ThreadingHTTPServer carrying the per-project state handlers need."""

    daemon_threads = True
    # On Windows SO_REUSEADDR lets a second bind seize a port that is in
    # active use (unlike POSIX, where it only relaxes TIME_WAIT), so the
    # busy-port fallback would never fire and two boards would fight over
    # one port. Bind exclusively there; POSIX keeps quick restarts.
    allow_reuse_address = os.name != "nt"

    def __init__(self, root: Path, config: dict[str, object], port: int) -> None:
        super().__init__(("127.0.0.1", port), _Handler)
        self.board_root = root
        self.board_config = config
        self.board_html = (Path(__file__).parent / "board.html").read_bytes()
        self.append_lock = threading.Lock()


def make_server(
    root: Path, config: dict[str, object], preferred_port: int
) -> _BoardServer:
    """Bind the preferred port, else the next free one, else an OS-picked one."""
    candidates = [preferred_port]
    if preferred_port != 0:
        candidates += [*range(preferred_port + 1, preferred_port + _PORT_TRIES), 0]
    for port in candidates:
        try:
            return _BoardServer(root, config, port)
        except OSError:
            continue
    msg = "no free port found"
    raise OSError(msg)


class _Handler(BaseHTTPRequestHandler):
    server_version = f"den-board/{__version__}"

    @property
    def board(self) -> _BoardServer:
        return cast("_BoardServer", self.server)

    def log_message(self, format: str, *args: object) -> None:  # ruff: ignore[builtin-argument-shadowing]  # stdlib signature
        """Silence the default per-request stderr line."""

    def _host_ok(self) -> bool:
        """Reject DNS-rebinding: the Host header must be a loopback name."""
        host = self.headers.get("Host", "")
        hostname = host.rsplit(":", 1)[0] if not host.startswith("[") else "[::1]"
        return hostname in {"127.0.0.1", "localhost", "[::1]"}

    def _origin_ok(self) -> bool:
        """Reject cross-site writes. A browser sends Origin on every fetch
        POST; a foreign page's POST (a no-preflight text/plain "simple
        request" included) carries its own origin and is refused. Requests
        without Origin (curl, scripts) are local tools, not browsers."""
        origin = self.headers.get("Origin")
        return origin is None or origin == f"http://{self.headers.get('Host', '')}"

    def _send_json(self, code: int, obj: dict[str, object]) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if not self._host_ok():
            self._send_json(403, {"error": "bad host"})
            return
        url = urlparse(self.path)
        if url.path == "/":
            body = self.board.board_html
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif url.path == "/api/config":
            root = self.board.board_root
            self._send_json(
                200,
                {
                    "title": _title(root, self.board.board_config),
                    "buttons": self.board.board_config.get("buttons"),
                    "root": str(root),
                    "reports_path": str(_reports_path(root)),
                },
            )
        elif url.path == "/api/reports":
            self._send_json(200, self._list_reports(url.query))
        elif url.path == "/api/ping":
            self._send_json(
                200,
                {
                    "den_board": __version__,
                    "root": str(self.board.board_root),
                    "pid": os.getpid(),
                },
            )
        else:
            self._send_json(404, {"error": "not found"})

    def _list_reports(self, query: str) -> dict[str, object]:
        raw_limit = parse_qs(query).get("limit", ["100"])[0]
        try:
            limit = max(1, min(int(raw_limit), _MAX_LIST_LIMIT))
        except ValueError:
            limit = 100
        lines = _tail_lines(_reports_path(self.board.board_root), _MAX_LIST_BYTES)
        reports: list[object] = []
        for line in lines[-limit:]:
            with suppress(json.JSONDecodeError):
                reports.append(json.loads(line))
        return {"reports": reports, "total": len(lines)}

    def do_POST(self) -> None:
        if not self._host_ok() or not self._origin_ok():
            self._send_json(403, {"error": "cross-site request refused"})
            return
        if urlparse(self.path).path != "/api/report":
            self._send_json(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > _MAX_BODY_BYTES:
            self._send_json(413, {"error": "body size"})
            return
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._send_json(400, {"error": "invalid JSON"})
            return
        button = payload.get("button") if isinstance(payload, dict) else None
        text = payload.get("text", "") if isinstance(payload, dict) else ""
        if (
            not isinstance(button, str)
            or not button.strip()
            or len(button) > _MAX_BUTTON_LEN
            or not isinstance(text, str)
            or len(text) > _MAX_TEXT_LEN
        ):
            self._send_json(400, {"error": "expected {button: str, text?: str}"})
            return
        entry = {
            "ts": datetime.now(UTC).isoformat(timespec="seconds"),
            "button": button.strip(),
            "text": text.strip(),
        }
        line = json.dumps(entry, ensure_ascii=False) + "\n"
        path = _reports_path(self.board.board_root)
        with self.board.append_lock:
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("a", encoding="utf-8") as f:
                f.write(line)
        note = f" {entry['text']}" if entry["text"] else ""
        print(f"[den board] {entry['ts']} [{entry['button']}]{note}", flush=True)
        self._send_json(200, {"ok": True})


def _usage() -> None:
    print(
        "usage: den board [--port N] [--open] [--dir PATH]\n"
        "\n"
        "Serve the project's report board (http://127.0.0.1:8484 by default;\n"
        "falls back to the next free port). The user files reports from the\n"
        "page; each lands as one JSON line in .den/board/reports.jsonl,\n"
        "which agents read directly. Edit .den/board/board.json to rename\n"
        "the board or change its buttons.\n"
        "\n"
        '  --port N    preferred port (default 8484, or "port" in board.json)\n'
        "  --open      also open the URL in the default browser\n"
        "  --dir PATH  project root (default: nearest .den ancestor, else cwd)"
    )


def _parse_args(args: list[str]) -> tuple[int | None, bool, Path | None] | None:
    """Return (port, open_browser, root) or None on a usage error."""
    port: int | None = None
    open_browser = False
    root: Path | None = None
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--open":
            open_browser = True
        elif arg == "--port" and i + 1 < len(args):
            try:
                port = int(args[i + 1])
            except ValueError:
                return None
            if not 0 <= port <= _MAX_PORT:
                return None
            i += 1
        elif arg == "--dir" and i + 1 < len(args):
            root = Path(args[i + 1]).expanduser()
            i += 1
        else:
            return None
        i += 1
    return port, open_browser, root


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if args and args[0] in {"-h", "--help", "help"}:
        _usage()
        return 0
    parsed = _parse_args(args)
    if parsed is None:
        _usage()
        return 2
    port_arg, open_browser, root_arg = parsed

    root = (root_arg or _find_den_dir(Path.cwd()).parent).resolve()
    config = ensure_scaffold(root)

    existing = _existing_instance(root)
    if existing is not None:
        print(f"den board: already running for {root.name}: {existing}")
        if open_browser:
            with suppress(webbrowser.Error):
                webbrowser.open(existing)
        return 0

    cfg_port = config.get("port")
    preferred = (
        port_arg
        if port_arg is not None
        else cfg_port
        if isinstance(cfg_port, int) and 0 <= cfg_port <= _MAX_PORT
        else _PREFERRED_PORT
    )
    try:
        server = make_server(root, config, preferred)
    except OSError as exc:
        print(f"den board: cannot bind a port: {exc}", file=sys.stderr)
        return 1

    port = server.server_address[1]
    url = f"http://127.0.0.1:{port}/"
    lock = _lock_path(root)
    lock.write_text(
        json.dumps(
            {
                "pid": os.getpid(),
                "port": port,
                "root": str(root),
                "started": datetime.now(UTC).isoformat(timespec="seconds"),
            }
        )
        + "\n",
        encoding="utf-8",
    )
    print(
        f"den board: serving {_title(root, config)}\n"
        f"  url      {url}\n"
        f"  reports  {_reports_path(root)}\n"
        "Ctrl-C to stop."
    )
    if open_browser:
        with suppress(webbrowser.Error):
            webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        _release_lock(root)
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
