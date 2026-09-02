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

The channel is two-way, but each file has exactly one writer. The server
appends the user's reports; agents append tasks and replies to their own
file (via `den board task` / `den board reply`, which generate the ids),
and the page renders both: tasks get Done / Can't buttons whose reaction
lands in reports.jsonl carrying re=<task id>, and replies thread under
the report they name. Agents still never talk to the server.

Usage:
  den board [--port N] [--open] [--dir PATH]
  den board task  [--dir PATH] <text>              agent files a task
  den board reply [--dir PATH] <report-id> <text>  agent answers a report

Files under <project>/.den/board/:
  board.json     title, preferred port, button set (edit freely)
  reports.jsonl  server-appended: user reports and task reactions
  agent.jsonl    agent-appended: tasks and replies (the page displays it)
  server.json    pid + port of the live server (removed on exit)
"""

from __future__ import annotations

import hashlib
import http.client
import json
import os
import secrets
import sys
import threading
import time
import webbrowser
from contextlib import suppress
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import cast
from urllib.parse import parse_qs, urlparse

from . import __version__
from ._memory import (
    _find_den_dir,
    _read_guarded,
    _symlink_component,
    _write_guarded,
)

_PREFERRED_PORT = 8484
_PORT_TRIES = 20
_PING_TIMEOUT_S = 0.6
_MAX_BODY_BYTES = 64 * 1024
_MAX_BUTTON_LEN = 64
_MAX_TEXT_LEN = 16000
_MAX_LIST_LIMIT = 500
_MAX_LIST_BYTES = 512 * 1024
_MAX_DRAIN_BYTES = 2 * 1024 * 1024
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


def _agent_path(root: Path) -> Path:
    return _board_dir(root) / "agent.jsonl"


_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


def _refuse_symlink(root: Path, path: Path) -> bool:
    """True (after one line on stderr) when a symlink at `.den`, `.den/board` or
    the board file itself makes `path` unusable.

    A cloned repo ships `.den/board/`, so a symlink planted there would turn every
    board append into an append to a file outside the workspace (and every read
    into serving one over localhost). den never follows one.
    """
    bad = _symlink_component(root / ".den", path)
    if bad is None:
        return False
    print(f"den board: refusing {path}: {bad} is a symlink", file=sys.stderr)
    return True


_ERR = "den board"


def _read_lock(root: Path) -> dict | None:
    """The parsed server.json, or None when it is absent, unreadable, symlinked,
    or not a JSON object. The lock is a board file like any other: a repo can
    ship `.den/board/server.json` as a symlink, and following it would let a
    planted file name the port `den board` probes and the pid it trusts."""
    data = _read_guarded(root / ".den", _lock_path(root), _ERR)
    if not isinstance(data, bytes):
        return None
    # Decode INSIDE the suppress. Routing this through the guard moved it out of
    # the old handler, so a non-UTF-8 server.json -- a byte a repo can plant --
    # raised UnicodeDecodeError out of `den board` instead of reading, as it
    # always did, as one more invalid lock.
    with suppress(ValueError):  # UnicodeDecodeError and JSONDecodeError both
        info = json.loads(data.decode("utf-8"))
        if isinstance(info, dict):
            return info
    return None


def _write_lock(root: Path, info: dict) -> bool:
    """Write server.json through the guard. False when refused (it said why)."""
    data = (json.dumps(info) + "\n").encode("utf-8")
    return _write_guarded(root / ".den", _lock_path(root), data, _ERR)


def _unlink_lock(root: Path) -> None:
    """Drop server.json, never through a symlink. Unlink would only remove the
    link itself, but a lock den refuses to read is not one it may clear either."""
    if _refuse_symlink(root, _lock_path(root)):
        return
    with suppress(OSError):
        _lock_path(root).unlink()


def _append_line(root: Path, path: Path, line: str) -> bool:
    """Append one line to a board file, refusing symlinks. False when refused.

    One O_APPEND write: atomic on POSIX. On Windows the CRT emulates append
    with seek+write, so two simultaneous appends can still race; accepted for
    a personal tool - the reader drops a torn line rather than crashing.
    O_NOFOLLOW narrows the check-to-open window where the platform has it
    (Windows does not; there the is_symlink check above is the whole guard).
    """
    if _refuse_symlink(root, path):
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    # 0o666 (umask applies): os.open's default mode is 0o777, which would make
    # every new reports.jsonl / agent.jsonl executable. _write_guarded already
    # passes the same mode.
    fd = os.open(path, os.O_CREAT | os.O_APPEND | os.O_WRONLY | _NOFOLLOW, 0o666)
    try:
        os.write(fd, line.encode("utf-8"))
    finally:
        os.close(fd)
    return True


def _new_id() -> str:
    return secrets.token_hex(4)


def _derived_id(line: str) -> str:
    """Stable fallback id for an agent line that carries none: the same
    line always maps to the same id, so reactions stay attributable even
    when an agent appended raw JSON without an id field."""
    digest = hashlib.sha1(line.encode("utf-8"), usedforsecurity=False)
    return digest.hexdigest()[:8]


def ensure_scaffold(root: Path) -> dict[str, object]:
    """Create .den/board/board.json with defaults; never clobber edits."""
    cfg_path = _board_dir(root) / "board.json"
    if _refuse_symlink(root, cfg_path):
        return dict(_DEFAULT_CONFIG)
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


def _split_jsonl(data: bytes) -> list[str]:
    """Split on real newlines ONLY. str.splitlines() would also break on
    U+2028/U+2029/U+0085, which json.dumps(ensure_ascii=False) writes raw
    inside a line - splitting there shreds a valid entry into fragments
    that json.loads rejects, making the entry silently invisible."""
    lines = [ln.rstrip("\r") for ln in data.decode("utf-8", "replace").split("\n")]
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def _tail_lines(root: Path, path: Path, max_bytes: int) -> list[str]:
    """Last complete lines within the trailing max_bytes of the file, so a
    long-lived board never loads an unbounded file per 5s poll. A symlinked
    board file reads as empty: the page must not serve an outside file. Silent,
    because the page polls this every 5s; the appends report instead."""
    if _symlink_component(root / ".den", path) is not None:
        return []
    try:
        with path.open("rb") as f:
            f.seek(0, 2)
            size = f.tell()
            if size <= max_bytes:
                f.seek(0)
                return _split_jsonl(f.read())
            # Read ONE extra byte before the window: splitting on it makes
            # the first split-line the partial (or, when the extra byte is a
            # newline, an empty marker), so dropping lines[0] is exact even
            # when the window happens to start at a line boundary.
            f.seek(size - max_bytes - 1)
            data = f.read()
    except OSError:
        return []
    return _split_jsonl(data)[1:]


def _valid_report(button: object, text: object, re_id: object) -> bool:
    if not isinstance(button, str) or not button.strip():
        return False
    if len(button) > _MAX_BUTTON_LEN:
        return False
    if not isinstance(text, str) or len(text) > _MAX_TEXT_LEN:
        return False
    return re_id is None or (isinstance(re_id, str) and len(re_id) <= 64)


def _title(root: Path, config: dict[str, object]) -> str:
    title = config.get("title")
    return title if isinstance(title, str) and title.strip() else root.name


def _existing_instance(root: Path) -> str | None:
    """URL of a live server for this root, else None (clearing stale locks)."""
    info = _read_lock(root)
    if info is None:
        return None
    try:
        port = int(info["port"])
    except (ValueError, KeyError, TypeError):
        return None
    with suppress(OSError, ValueError, json.JSONDecodeError):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=_PING_TIMEOUT_S)
        try:
            conn.request("GET", "/api/ping")
            resp = conn.getresponse()
            data = json.loads(resp.read().decode("utf-8"))
        finally:
            conn.close()
        if (
            isinstance(data, dict)
            and data.get("den_board")
            and data.get("root") == str(root)
        ):
            return f"http://127.0.0.1:{port}/"
    _unlink_lock(root)
    return None


def _release_lock(root: Path) -> None:
    """Remove the lock only if this process owns it (a concurrent start may
    have overwritten it; deleting a twin's lock would orphan that server)."""
    info = _read_lock(root)
    if info is None:
        return
    with suppress(ValueError, TypeError):
        if int(info.get("pid", -1)) == os.getpid():
            _unlink_lock(root)


def _claim_lock(root: Path) -> bool:
    """Atomically create the lock file; False when another process holds it.

    The O_EXCL create is what makes two simultaneous `den board` launches
    safe: exactly one wins the claim and binds, the other finds the winner
    (or a stale claim) and never starts a shadow server.
    """
    lock = _lock_path(root)
    if _refuse_symlink(root, lock):
        return False
    lock.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.close(os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY | _NOFOLLOW, 0o666))
    except FileExistsError:
        return False
    return True


class _BoardServer(ThreadingHTTPServer):
    """ThreadingHTTPServer carrying the per-project state handlers need."""

    daemon_threads = True
    # On Windows SO_REUSEADDR lets a second bind seize a port that is in
    # active use (unlike POSIX, where it only relaxes TIME_WAIT), so the
    # busy-port fallback would never fire and two boards would fight over
    # one port. Bind exclusively there; POSIX keeps quick restarts.
    allow_reuse_address = os.name != "nt"

    def __init__(
        self, root: Path, config: dict[str, object], html: bytes, port: int
    ) -> None:
        super().__init__(("127.0.0.1", port), _Handler)
        self.board_root = root
        self.board_config = config
        self.board_html = html
        self.append_lock = threading.Lock()


_PAGE_PATH = Path(__file__).parent / "board.html"


def make_server(
    root: Path, config: dict[str, object], preferred_port: int
) -> _BoardServer:
    """Bind the preferred port, else the next free one, else an OS-picked one."""
    # Read the page before the bind loop: a missing board.html raises its own
    # FileNotFoundError here instead of being swallowed as 21 "port busy"
    # OSErrors and misreported as "no free port found".
    html = _PAGE_PATH.read_bytes()
    candidates = [preferred_port]
    if preferred_port != 0:
        upper = min(preferred_port + _PORT_TRIES, _MAX_PORT + 1)
        candidates += [*range(preferred_port + 1, upper), 0]
    for port in candidates:
        try:
            return _BoardServer(root, config, html, port)
        except OSError:
            continue
    msg = "no free port found"
    raise OSError(msg)


class _Handler(BaseHTTPRequestHandler):
    server_version = f"den-board/{__version__}"
    timeout = 10  # a stalled or lying client must not pin a handler thread

    @property
    def board(self) -> _BoardServer:
        return cast("_BoardServer", self.server)

    def log_message(self, format: str, *args: object) -> None:  # ruff: ignore[builtin-argument-shadowing]  # stdlib signature
        """Silence the default per-request stderr line."""

    def _host_ok(self) -> bool:
        """Reject DNS-rebinding: the Host header must be a loopback name."""
        host = self.headers.get("Host", "")
        if host.startswith("["):
            end = host.find("]")
            return end > 0 and host[1:end] == "::1"
        return host.rsplit(":", 1)[0] in {"127.0.0.1", "localhost"}

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
            # A framed board could be clickjacked into fabricated task
            # reactions that an agent would read as the user's answer.
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Content-Security-Policy", "frame-ancestors 'none'")
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
        elif url.path == "/api/agent":
            self._send_json(200, self._list_agent())
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
        root = self.board.board_root
        lines = _tail_lines(root, _reports_path(root), _MAX_LIST_BYTES)
        reports: list[object] = []
        for line in lines[-limit:]:
            with suppress(json.JSONDecodeError):
                reports.append(json.loads(line))
        return {"reports": reports, "total": len(lines)}

    def _list_agent(self) -> dict[str, object]:
        root = self.board.board_root
        lines = _tail_lines(root, _agent_path(root), _MAX_LIST_BYTES)
        # Settlement is joined HERE, over the full reports tail window - the
        # page's 100-report slice must never decide whether a task is open
        # (a reaction older than 100 reports would "reopen" it and invite a
        # second, conflicting reaction).
        reactions: dict[str, dict[str, object]] = {}
        for line in _tail_lines(root, _reports_path(root), _MAX_LIST_BYTES):
            with suppress(json.JSONDecodeError):
                rep = json.loads(line)
                if (
                    isinstance(rep, dict)
                    and isinstance(rep.get("re"), str)
                    and isinstance(rep.get("button"), str)
                    and rep["button"].startswith("task-")
                ):
                    reactions[rep["re"]] = rep
        entries: list[object] = []
        seen: dict[str, int] = {}
        for line in lines:
            with suppress(json.JSONDecodeError):
                entry = json.loads(line)
                if not isinstance(entry, dict):
                    continue
                if not isinstance(entry.get("id"), str) or not entry["id"]:
                    # Occurrence-salted so duplicate id-less lines stay
                    # distinct; append-only order keeps the salt stable.
                    n = seen.get(line, 0)
                    seen[line] = n + 1
                    entry["id"] = _derived_id(line if n == 0 else f"{line}#{n}")
                if entry.get("type") == "task" and entry["id"] in reactions:
                    r = reactions[entry["id"]]
                    entry["reaction"] = {
                        "button": r.get("button"),
                        "ts": r.get("ts"),
                        "text": r.get("text"),
                    }
                entries.append(entry)
        return {"entries": entries, "total": len(lines)}

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
            # Drain a bounded amount before answering: rejecting mid-upload
            # aborts the connection on Windows (WinError 10053) and the
            # client never sees the 413 - it would misread a healthy server
            # as offline. Past the drain cap the connection is desynced, so
            # close it.
            remaining = min(max(length, 0), _MAX_DRAIN_BYTES)
            with suppress(OSError):
                while remaining > 0:
                    chunk = self.rfile.read(min(65536, remaining))
                    if not chunk:
                        break
                    remaining -= len(chunk)
            self.close_connection = True
            self._send_json(413, {"error": "body size"})
            return
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._send_json(400, {"error": "invalid JSON"})
            return
        button = payload.get("button") if isinstance(payload, dict) else None
        text = payload.get("text", "") if isinstance(payload, dict) else ""
        re_id = payload.get("re") if isinstance(payload, dict) else None
        if not isinstance(button, str) or not _valid_report(button, text, re_id):
            self._send_json(
                400, {"error": "expected {button: str, text?: str, re?: str}"}
            )
            return
        entry: dict[str, object] = {
            "ts": datetime.now(UTC).isoformat(timespec="seconds"),
            "id": _new_id(),
            "button": button.strip(),
            "text": text.strip(),
        }
        if isinstance(re_id, str) and re_id.strip():
            entry["re"] = re_id.strip()
        line = json.dumps(entry, ensure_ascii=False) + "\n"
        root = self.board.board_root
        with self.board.append_lock:
            stored = _append_line(root, _reports_path(root), line)
        if not stored:
            self._send_json(500, {"error": "report file refused"})
            return
        note = f" {entry['text']}" if entry["text"] else ""
        print(f"[den board] {entry['ts']} [{entry['button']}]{note}", flush=True)
        self._send_json(200, {"ok": True, "id": entry["id"]})


def _usage() -> None:
    print(
        "usage: den board [--port N] [--open] [--dir PATH]\n"
        "       den board task  [--dir PATH] <text>\n"
        "       den board reply [--dir PATH] <report-id> <text>\n"
        "\n"
        "Serve the project's report board (http://127.0.0.1:8484 by default;\n"
        "falls back to the next free port). The user files reports from the\n"
        "page; each lands as one JSON line in .den/board/reports.jsonl,\n"
        "which agents read directly. Edit .den/board/board.json to rename\n"
        "the board or change its buttons.\n"
        "\n"
        "task / reply are for AGENTS: they append one line to\n"
        ".den/board/agent.jsonl and print its generated id. The page shows\n"
        "tasks with Done / Can't buttons; the user's reaction lands in\n"
        "reports.jsonl with re=<that id>. reply threads a note under the\n"
        "user's report named by <report-id>.\n"
        "\n"
        '  --port N    preferred port (default 8484, or "port" in board.json)\n'
        "  --open      also open the URL in the default browser\n"
        "  --dir PATH  project root (default: nearest .den ancestor, else cwd)"
    )


def _append_agent(
    root: Path, entry_type: str, text: str, re_id: str | None
) -> str | None:
    entry_id = _new_id()
    # Lone surrogates (surrogateescape-decoded argv bytes) survive
    # json.dumps but explode at the strict utf-8 file write - scrub first.
    entry: dict[str, object] = {
        "ts": datetime.now(UTC).isoformat(timespec="seconds"),
        "id": entry_id,
        "type": entry_type,
        "text": text.strip().encode("utf-8", "replace").decode("utf-8"),
    }
    if re_id is not None:
        entry["re"] = re_id.encode("utf-8", "replace").decode("utf-8")
    line = json.dumps(entry, ensure_ascii=False) + "\n"
    if not _append_line(root, _agent_path(root), line):
        return None
    return entry_id


def _cmd_agent(entry_type: str, args: list[str]) -> int:  # ruff: ignore[too-many-return-statements]  # arg validation
    """`den board task <text>` / `den board reply <report-id> <text>`."""
    root: Path | None = None
    rest: list[str] = []
    literal = False
    i = 0
    while i < len(args):
        arg = args[i]
        if not literal and arg in {"-h", "--help", "help"}:
            _usage()
            return 0
        if not literal and arg == "--":
            literal = True
        elif not literal and arg == "--dir":
            if i + 1 >= len(args):
                _usage()
                return 2
            root = Path(args[i + 1]).expanduser()
            i += 1
        elif not literal and arg.startswith("-"):
            # An unrecognized flag must not silently become task text (an
            # agent probing `task --port 9000 x` would file garbage and
            # believe it succeeded). Literal dash-leading text goes after
            # a `--` terminator.
            _usage()
            return 2
        else:
            rest.append(arg)
        i += 1
    re_id: str | None = None
    if entry_type == "reply":
        if not rest:
            _usage()
            return 2
        re_id = rest.pop(0)
        if not re_id.strip() or len(re_id) > 64:
            _usage()
            return 2
    text = " ".join(rest).strip()
    if not text or len(text) > _MAX_TEXT_LEN:
        _usage()
        return 2
    resolved = (root or _find_den_dir(Path.cwd()).parent).resolve()
    entry_id = _append_agent(resolved, entry_type, text, re_id)
    if entry_id is None:  # symlinked board file: nothing was appended
        return 1
    print(entry_id)
    return 0


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


def _acquire(root: Path, *, open_browser: bool) -> int | None:
    """Claim the project's board lock; an int is main()'s early exit code."""
    existing = _existing_instance(root)
    if existing is not None:
        print(f"den board: already running for {root.name}: {existing}")
        if open_browser:
            with suppress(webbrowser.Error):
                webbrowser.open(existing)
        return 0
    if _claim_lock(root):
        return None
    # Lost the claim to a twin launched in the same instant: wait for it to
    # finish starting and reprint its URL instead of racing it.
    for _ in range(10):
        time.sleep(0.2)
        existing = _existing_instance(root)
        if existing is not None:
            print(f"den board: already running for {root.name}: {existing}")
            return 0
    # No live twin materialized: the claim is a corpse (a crash between
    # claim and lock write). Take it over.
    _unlink_lock(root)
    if not _claim_lock(root):
        print("den board: another instance is starting; try again", file=sys.stderr)
        return 1
    return None


def _bind_and_record(
    root: Path, config: dict[str, object], preferred: int
) -> _BoardServer | None:
    """Bind the port AND record the lock, or None (message printed) if either
    fails. The two belong together: a server that is bound but not recorded is
    invisible to _existing_instance, so the next `den board` here would start a
    SECOND one on another port and the two would split the user's reports between
    them. Serving anyway is worse than not serving."""
    try:
        server = make_server(root, config, preferred)
    except OSError as exc:
        _unlink_lock(root)  # release the claim we hold
        print(f"den board: cannot start: {exc}", file=sys.stderr)
        return None
    try:
        recorded = _write_lock(
            root,
            {
                "pid": os.getpid(),
                "port": server.server_address[1],
                "root": str(root),
                "started": datetime.now(UTC).isoformat(timespec="seconds"),
            },
        )
    except OSError as exc:
        # Full or read-only filesystem, or O_NOFOLLOW catching a symlink swapped
        # in after the pre-check. Raising here would skip the cleanup below and
        # leave the bound socket and our claim behind on the way out.
        print(f"den board: cannot record the lock: {exc}", file=sys.stderr)
        recorded = False
    if not recorded:
        server.server_close()  # give the socket back
        _unlink_lock(root)  # release the claim, if it is ours to release
        print("den board: could not record the lock; not serving", file=sys.stderr)
        return None
    return server


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if args and args[0] in {"task", "reply"}:
        return _cmd_agent(args[0], args[1:])
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

    # Windows consoles and redirected pipes can carry a narrow code page
    # (cp932/cp1252); the note echo below must never crash the server over
    # an unencodable character.
    reconfigure = getattr(sys.stdout, "reconfigure", None)
    if callable(reconfigure):
        with suppress(OSError, ValueError):
            reconfigure(errors="replace")

    early_exit = _acquire(root, open_browser=open_browser)
    if early_exit is not None:
        return early_exit

    cfg_port = config.get("port")
    preferred = (
        port_arg
        if port_arg is not None
        else cfg_port
        if isinstance(cfg_port, int) and 0 <= cfg_port <= _MAX_PORT
        else _PREFERRED_PORT
    )
    server = _bind_and_record(root, config, preferred)
    if server is None:
        return 1

    port = server.server_address[1]
    url = f"http://127.0.0.1:{port}/"
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
