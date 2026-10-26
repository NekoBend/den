"""Tests for den board (den/_board.py): scaffold, HTTP surface, lock logic."""

from __future__ import annotations

import http.client
import json
import os
import socket
import sys
import threading
import time
from pathlib import Path

import pytest

from den import _board

# serve_forever looks for a shutdown() request once per poll, every 0.5 s by
# default, so each teardown waited up to half a second for it: about 11 s of a
# 15 s tests/den run. Poll every 20 ms instead.
_POLL_INTERVAL = 0.02


def _serve_in_thread(server):
    """Run server.serve_forever in a daemon thread and return the thread."""
    thread = threading.Thread(
        target=server.serve_forever,
        kwargs={"poll_interval": _POLL_INTERVAL},
        daemon=True,
    )
    thread.start()
    return thread


@pytest.fixture
def served(tmp_path):
    """A live board server on an OS-picked port, torn down after the test."""
    config = _board.ensure_scaffold(tmp_path)
    server = _board.make_server(tmp_path, config, preferred_port=0)
    thread = _serve_in_thread(server)
    yield tmp_path, server, server.server_address[1]
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)


def _umask():
    """The process umask, read back the only way POSIX offers (set and restore)."""
    current = os.umask(0o022)
    os.umask(current)
    return current


def _request(port, method, path, body=None, headers=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        payload = None if body is None else json.dumps(body).encode()
        all_headers = {} if body is None else {"Content-Type": "application/json"}
        all_headers.update(headers or {})
        conn.request(method, path, body=payload, headers=all_headers)
        resp = conn.getresponse()
        return resp.status, resp.read()
    finally:
        conn.close()


def test_scaffold_creates_defaults_and_preserves_edits(tmp_path):
    config = _board.ensure_scaffold(tmp_path)
    cfg_path = tmp_path / ".den" / "board" / "board.json"
    assert cfg_path.is_file()
    assert any(b["id"] == "bug" for b in config["buttons"])

    cfg_path.write_text(json.dumps({"title": "My Rig"}), encoding="utf-8")
    again = _board.ensure_scaffold(tmp_path)
    assert again["title"] == "My Rig"
    assert again["buttons"], "defaults still fill unset keys"


def test_index_serves_page(served):
    _root, _server, port = served
    status, body = _request(port, "GET", "/")
    assert status == 200
    assert b"den board" in body


def test_config_title_defaults_to_dirname(served):
    root, _server, port = served
    status, body = _request(port, "GET", "/api/config")
    assert status == 200
    cfg = json.loads(body)
    assert cfg["title"] == root.name
    assert cfg["reports_path"].endswith("reports.jsonl")


def test_report_roundtrip(served):
    root, _server, port = served
    status, body = _request(
        port, "POST", "/api/report", {"button": "bug", "text": "boss froze"}
    )
    assert status == 200
    assert json.loads(body)["ok"] is True

    lines = (root / ".den" / "board" / "reports.jsonl").read_text().splitlines()
    assert len(lines) == 1
    entry = json.loads(lines[0])
    assert entry["button"] == "bug"
    assert entry["text"] == "boss froze"
    assert entry["ts"].endswith("+00:00")

    status, body = _request(port, "GET", "/api/reports")
    listed = json.loads(body)
    assert status == 200
    assert listed["total"] == 1
    assert listed["reports"][0]["text"] == "boss froze"


def test_report_validation(served):
    _root, _server, port = served
    status, _ = _request(port, "POST", "/api/report", {"text": "no button"})
    assert status == 400
    status, _ = _request(port, "POST", "/api/report", {"button": "  "})
    assert status == 400
    status, _ = _request(port, "POST", "/api/report", {"button": "x" * 65})
    assert status == 400
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        conn.request(
            "POST",
            "/api/report",
            body=b"not json",
            headers={"Content-Type": "application/json"},
        )
        assert conn.getresponse().status == 400
    finally:
        conn.close()


def test_unknown_paths_404(served):
    _root, _server, port = served
    assert _request(port, "GET", "/nope")[0] == 404
    assert _request(port, "POST", "/nope", {"button": "bug"})[0] == 404


def test_ping_names_root(served):
    root, _server, port = served
    _status, body = _request(port, "GET", "/api/ping")
    ping = json.loads(body)
    assert ping["root"] == str(root)
    assert ping["den_board"]


def test_served_server_shuts_down_promptly(served):
    # A request restarts the poll, so with the 0.5 s default this shutdown
    # took the whole half second; with _POLL_INTERVAL it takes about 20 ms.
    # The bound leaves room for a slow runner. The fixture's own shutdown()
    # afterwards returns at once.
    _root, server, port = served
    assert _request(port, "GET", "/api/ping")[0] == 200
    start = time.monotonic()
    server.shutdown()
    assert time.monotonic() - start < 0.3


def test_existing_instance_detects_live_server(served):
    root, _server, port = served
    lock = root / ".den" / "board" / "server.json"
    lock.write_text(json.dumps({"pid": 1, "port": port, "root": str(root)}))
    assert _board._existing_instance(root) == f"http://127.0.0.1:{port}/"
    assert lock.is_file(), "live lock is kept"


def test_existing_instance_clears_stale_lock(tmp_path):
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        dead_port = s.getsockname()[1]
    lock = tmp_path / ".den" / "board" / "server.json"
    lock.parent.mkdir(parents=True)
    lock.write_text(json.dumps({"pid": 1, "port": dead_port, "root": str(tmp_path)}))
    assert _board._existing_instance(tmp_path) is None
    assert not lock.exists(), "stale lock removed"


def test_existing_instance_ignores_other_projects_server(served, tmp_path_factory):
    _root, _server, port = served
    other = tmp_path_factory.mktemp("other")
    lock = other / ".den" / "board" / "server.json"
    lock.parent.mkdir(parents=True)
    lock.write_text(json.dumps({"pid": 1, "port": port, "root": str(other)}))
    assert _board._existing_instance(other) is None, "root mismatch is not ours"


def test_port_fallback_when_preferred_is_busy(served, tmp_path_factory):
    _root, _server, busy_port = served
    other = tmp_path_factory.mktemp("second")
    config = _board.ensure_scaffold(other)
    second = _board.make_server(other, config, preferred_port=busy_port)
    try:
        assert second.server_address[1] != busy_port
    finally:
        second.server_close()


def test_main_usage_errors():
    assert _board.main(["--bogus"]) == 2
    assert _board.main(["--port", "abc"]) == 2
    assert _board.main(["--help"]) == 0


def test_port_out_of_range_is_usage_error():
    assert _board.main(["--port", "-1"]) == 2
    assert _board.main(["--port", "70000"]) == 2


def test_cross_origin_post_rejected(served):
    root, _server, port = served
    status, _ = _request(
        port,
        "POST",
        "/api/report",
        {"button": "bug", "text": "forged"},
        headers={"Origin": "http://evil.example"},
    )
    assert status == 403
    assert not (root / ".den" / "board" / "reports.jsonl").exists()

    status, _ = _request(
        port,
        "POST",
        "/api/report",
        {"button": "bug", "text": "own page"},
        headers={"Origin": f"http://127.0.0.1:{port}"},
    )
    assert status == 200


def test_rebinding_host_rejected(served):
    _root, _server, port = served
    status, _ = _request(port, "GET", "/api/reports", headers={"Host": "evil.example"})
    assert status == 403
    status, _ = _request(
        port,
        "POST",
        "/api/report",
        {"button": "bug"},
        headers={"Host": "evil.example:80"},
    )
    assert status == 403


def test_release_lock_only_removes_own(tmp_path):
    lock = tmp_path / ".den" / "board" / "server.json"
    lock.parent.mkdir(parents=True)
    lock.write_text(json.dumps({"pid": 999_999_999, "port": 1}))
    _board._release_lock(tmp_path)
    assert lock.is_file(), "a twin's lock is left alone"
    lock.write_text(json.dumps({"pid": os.getpid(), "port": 1}))
    _board._release_lock(tmp_path)
    assert not lock.exists(), "our own lock is removed"


def test_tail_lines_boundaries(tmp_path):
    path = tmp_path / "reports.jsonl"
    entries = [json.dumps({"n": i, "pad": "x" * 20}) + "\n" for i in range(5)]
    # write_bytes: text mode would translate \n to \r\n on Windows and shift
    # every byte-window boundary this test pins.
    path.write_bytes("".join(entries).encode("utf-8"))
    full = [e.rstrip("\n") for e in entries]
    line = len(entries[0])

    assert _board._tail_lines(tmp_path, path, 10_000) == full
    assert _board._tail_lines(tmp_path, path, line * 2 + 10) == full[3:], (
        "partial dropped"
    )
    assert _board._tail_lines(tmp_path, path, line * 2) == full[3:], (
        "exact boundary kept"
    )


def test_claim_lock_is_exclusive(tmp_path):
    assert _board._claim_lock(tmp_path) is True
    assert _board._claim_lock(tmp_path) is False, "second claimant loses"
    _board._lock_path(tmp_path).unlink()
    assert _board._claim_lock(tmp_path) is True


def test_ipv6_host_parsing(served):
    _root, _server, port = served
    assert _request(port, "GET", "/api/ping", headers={"Host": "[::1]:9999"})[0] == 200
    hdr = {"Host": "[2001:db8::1]:80"}
    assert _request(port, "GET", "/api/ping", headers=hdr)[0] == 403, (
        "a non-loopback bracketed literal must not pass"
    )


def test_more_validation_edges(served):
    _root, _server, port = served
    status, _ = _request(
        port, "POST", "/api/report", {"button": "bug", "text": "x" * 16001}
    )
    assert status == 400

    for body, expected in ((b"[1, 2]", 400), (b"{}", 400)):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        try:
            conn.request(
                "POST",
                "/api/report",
                body=body,
                headers={"Content-Type": "application/json"},
            )
            assert conn.getresponse().status == expected
        finally:
            conn.close()

    big = json.dumps({"button": "bug", "text": "y" * 70000}).encode()
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        conn.request(
            "POST",
            "/api/report",
            body=big,
            headers={"Content-Type": "application/json"},
        )
        assert conn.getresponse().status == 413
    finally:
        conn.close()

    assert _request(port, "GET", "/api/reports?limit=abc")[0] == 200
    assert _request(port, "GET", "/api/reports?limit=0")[0] == 200


def test_make_server_at_port_ceiling_never_overflows(tmp_path):
    config = _board.ensure_scaffold(tmp_path)
    server = _board.make_server(tmp_path, config, preferred_port=65535)
    try:
        assert 0 < server.server_address[1] <= 65535
    finally:
        server.server_close()


def test_missing_page_reports_itself_not_ports(tmp_path, monkeypatch):
    monkeypatch.setattr(_board, "_PAGE_PATH", tmp_path / "gone.html")
    config = _board.ensure_scaffold(tmp_path)
    with pytest.raises(FileNotFoundError):
        _board.make_server(tmp_path, config, preferred_port=0)


def test_existing_instance_survives_non_dict_ping(tmp_path):
    from http.server import BaseHTTPRequestHandler, HTTPServer

    class NullHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            body = b"null"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    srv = HTTPServer(("127.0.0.1", 0), NullHandler)
    _serve_in_thread(srv)
    try:
        lock = tmp_path / ".den" / "board" / "server.json"
        lock.parent.mkdir(parents=True)
        lock.write_text(
            json.dumps({"pid": 1, "port": srv.server_address[1], "root": str(tmp_path)})
        )
        assert _board._existing_instance(tmp_path) is None
        assert not lock.exists(), "foreign responder -> stale lock cleared"
    finally:
        srv.shutdown()
        srv.server_close()


def test_report_gets_auto_id_and_re(served):
    root, _server, port = served
    status, body = _request(
        port,
        "POST",
        "/api/report",
        {"button": "task-done", "text": "cleared", "re": "abc12345"},
    )
    assert status == 200
    rid = json.loads(body)["id"]
    assert isinstance(rid, str) and len(rid) == 8

    entry = json.loads(
        (root / ".den" / "board" / "reports.jsonl").read_text().splitlines()[-1]
    )
    assert entry["id"] == rid
    assert entry["re"] == "abc12345"


def test_report_re_validation(served):
    _root, _server, port = served
    status, _ = _request(port, "POST", "/api/report", {"button": "bug", "re": 7})
    assert status == 400
    status, _ = _request(port, "POST", "/api/report", {"button": "bug", "re": "x" * 65})
    assert status == 400


def test_agent_endpoint_serves_and_derives_ids(served):
    root, _server, port = served
    agent = root / ".den" / "board" / "agent.jsonl"
    agent.write_text(
        json.dumps({"id": "fixedid1", "type": "task", "text": "with id"})
        + "\n"
        + json.dumps({"type": "task", "text": "no id"})
        + "\n"
        + "not json\n",
        encoding="utf-8",
    )
    status, body = _request(port, "GET", "/api/agent")
    assert status == 200
    entries = json.loads(body)["entries"]
    assert len(entries) == 2, "broken line skipped"
    assert entries[0]["id"] == "fixedid1"
    derived = entries[1]["id"]
    assert isinstance(derived, str) and len(derived) == 8

    _status, body2 = _request(port, "GET", "/api/agent")
    assert json.loads(body2)["entries"][1]["id"] == derived, "derived id stable"


def test_cli_task_and_reply(tmp_path, capsys):
    assert _board.main(["task", "--dir", str(tmp_path), "boss", "crash?"]) == 0
    task_id = capsys.readouterr().out.strip()
    assert len(task_id) == 8

    assert _board.main(["reply", "--dir", str(tmp_path), task_id, "fixed"]) == 0
    reply_id = capsys.readouterr().out.strip()
    assert len(reply_id) == 8 and reply_id != task_id

    lines = [
        json.loads(ln)
        for ln in (tmp_path / ".den" / "board" / "agent.jsonl").read_text().splitlines()
    ]
    assert lines[0] == {
        **lines[0],
        "type": "task",
        "text": "boss crash?",
        "id": task_id,
    }
    assert lines[1] == {
        **lines[1],
        "type": "reply",
        "re": task_id,
        "text": "fixed",
        "id": reply_id,
    }


def test_cli_agent_usage_errors(tmp_path):
    assert _board.main(["task", "--dir", str(tmp_path)]) == 2, "no text"
    assert _board.main(["reply", "--dir", str(tmp_path)]) == 2, "no id"
    assert _board.main(["reply", "--dir", str(tmp_path), "x" * 65, "t"]) == 2
    assert not (tmp_path / ".den" / "board" / "agent.jsonl").exists()


def test_page_has_tasks_section(served):
    _root, _server, port = served
    _status, body = _request(port, "GET", "/")
    assert b"Tasks from the agent" in body


def test_line_separator_chars_stay_visible(served):
    root, _server, port = served
    _board._append_agent(root, "task", "plan A\u2028plan B\u2029end\u0085.", None)
    _status, body = _request(port, "GET", "/api/agent")
    entries = json.loads(body)["entries"]
    assert len(entries) == 1, "U+2028/29/85 must not shred the line"
    assert "plan A\u2028plan B" in entries[0]["text"]


def test_cli_rejects_flag_like_input(tmp_path):
    assert _board.main(["task", "--dir", str(tmp_path), "--port", "9000"]) == 2
    assert _board.main(["task", "--dir"]) == 2, "valueless --dir"
    assert _board.main(["task", "--help"]) == 0, "help shows usage"
    assert not (tmp_path / ".den" / "board" / "agent.jsonl").exists()

    assert _board.main(["task", "--dir", str(tmp_path), "--", "--literal"]) == 0
    line = json.loads(
        (tmp_path / ".den" / "board" / "agent.jsonl").read_text().splitlines()[0]
    )
    assert line["text"] == "--literal", "-- terminator keeps dash text"


def test_reaction_joined_server_side(served):
    root, _server, port = served
    task_id = _board._append_agent(root, "task", "press done", None)
    status, _ = _request(
        port,
        "POST",
        "/api/report",
        {"button": "task-done", "text": "ok", "re": task_id},
    )
    assert status == 200
    _status, body = _request(port, "GET", "/api/agent")
    entry = json.loads(body)["entries"][0]
    assert entry["reaction"]["button"] == "task-done"
    assert entry["reaction"]["text"] == "ok"


def _react(port, task_id):
    """The user presses Done on the task, with the note "ok"."""
    body = {"button": "task-done", "text": "ok", "re": task_id}
    assert _request(port, "POST", "/api/report", body)[0] == 200


def _listed_reaction(port):
    """The reaction of the one task /api/agent lists, or None while it is open."""
    _status, body = _request(port, "GET", "/api/agent")
    (task,) = json.loads(body)["entries"]
    return task.get("reaction")


@pytest.mark.parametrize("polled_before", [False, True])
def test_reaction_outlives_the_reports_window(served, polled_before):
    # A reaction with more than _MAX_LIST_BYTES of reports after it fell out
    # of the tail that settlement was joined over, and the page offered Done /
    # Can't again on a task the user had answered. polled_before: the server
    # saw the reaction before the flood and from then on reads only what was
    # appended, or it reads the whole file for the first time after it.
    root, _server, port = served
    task_id = _board._append_agent(root, "task", "press done", None)
    _react(port, task_id)
    if polled_before:
        assert _listed_reaction(port)["button"] == "task-done"
    reports = _board._reports_path(root)
    after = reports.stat().st_size
    note = {"button": "note", "text": "x" * _board._MAX_TEXT_LEN}
    while reports.stat().st_size - after <= _board._MAX_LIST_BYTES:
        assert _request(port, "POST", "/api/report", note)[0] == 200

    reaction = _listed_reaction(port)
    assert reaction is not None, "the answered task is open again"
    assert (reaction["button"], reaction["text"]) == ("task-done", "ok")
    # /api/reports keeps its window: the list no longer reaches the reaction.
    _status, body = _request(port, "GET", "/api/reports?limit=500")
    assert all(r.get("re") != task_id for r in json.loads(body)["reports"])


def test_settlement_follows_a_rewritten_reports_file(served):
    # The server reads only what was appended since its last poll, so a file
    # changed in any other way has to be read again from the start.
    root, _server, port = served
    task_id = _board._append_agent(root, "task", "press done", None)
    _react(port, task_id)
    assert _listed_reaction(port)["button"] == "task-done"
    reports = _board._reports_path(root)

    # Edited in place, same size: the user changed the answer by hand.
    reports.write_bytes(reports.read_bytes().replace(b"task-done", b"task-cant"))
    assert _listed_reaction(port)["button"] == "task-cant"

    # Changed back further up than the seam reaches, same size, and saved the
    # way many editors save: a new file renamed over the old one.
    note = {"button": "note", "text": "y" * 1000}
    while reports.stat().st_size <= 2 * _board._SEAM_BYTES:
        assert _request(port, "POST", "/api/report", note)[0] == 200
    assert _listed_reaction(port)["button"] == "task-cant"
    saved = reports.with_name("reports.jsonl.new")
    saved.write_bytes(reports.read_bytes().replace(b"task-cant", b"task-done"))
    saved.replace(reports)
    assert _listed_reaction(port)["button"] == "task-done"


def test_settlement_follows_a_truncated_or_deleted_reports_file(served):
    root, _server, port = served
    task_id = _board._append_agent(root, "task", "press done", None)
    reports = _board._reports_path(root)
    _react(port, task_id)
    assert _listed_reaction(port)["button"] == "task-done"
    reports.write_bytes(b"")
    assert _listed_reaction(port) is None

    _react(port, task_id)
    assert _listed_reaction(port)["button"] == "task-done"
    reports.unlink()  # as den/README.md suggests when a session is done
    assert _listed_reaction(port) is None

    _react(port, task_id)
    assert _listed_reaction(port)["button"] == "task-done"
    # Deleted again, and the new file grew past the old one between polls.
    reports.unlink()
    for _ in range(3):
        note = {"button": "note", "text": "y" * 200}
        assert _request(port, "POST", "/api/report", note)[0] == 200
    assert _listed_reaction(port) is None


def test_reactions_read_whole_lines_across_chunks(tmp_path, monkeypatch):
    # A line split across read chunks, multi-byte characters included, is read
    # whole; a line still missing its newline waits for the next poll; and a
    # task's latest reaction wins.
    monkeypatch.setattr(_board, "_READ_CHUNK", 7)
    reports = _board._reports_path(tmp_path)
    reports.parent.mkdir(parents=True)
    text = "caf\u00e9 \u2028 \u7121\u7406"
    rows = [
        {"button": "bug", "text": text},
        {"button": "task-cant", "re": "t1", "text": text},
        {"button": "task-done", "re": "t2", "text": "ok", "ts": "now"},
        {"button": "task-done", "re": "t1", "text": "after all"},
    ]
    data = "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows).encode()
    cut = len(data) - 10  # inside the last line
    reports.write_bytes(data[:cut])
    index = _board._Reactions(tmp_path)
    t2 = {"button": "task-done", "ts": "now", "text": "ok"}
    assert index.snapshot() == {
        "t1": {"button": "task-cant", "ts": None, "text": text},
        "t2": t2,
    }
    with reports.open("ab") as f:
        f.write(data[cut:])
    assert index.snapshot() == {
        "t1": {"button": "task-done", "ts": None, "text": "after all"},
        "t2": t2,
    }


def test_reactions_read_only_what_was_appended(tmp_path, monkeypatch):
    # After the first poll, a poll takes in only what was appended since, so
    # the 5 s poll never reads the whole file again. The file is longer than
    # the seam: a seam compared anywhere but where it was read would make
    # every poll start over from byte 0.
    reports = _board._reports_path(tmp_path)
    reports.parent.mkdir(parents=True)
    notes = [{"id": f"n{i}", "button": "note", "text": "x" * 100} for i in range(64)]
    reports.write_bytes("".join(json.dumps(n) + "\n" for n in notes).encode())
    assert reports.stat().st_size > _board._SEAM_BYTES
    index = _board._Reactions(tmp_path)
    assert index.snapshot() == {}

    taken = []
    take = _board._Reactions._take

    def record(self, block):
        taken.append(block)
        take(self, block)

    monkeypatch.setattr(_board._Reactions, "_take", record)
    line = json.dumps({"button": "task-done", "re": "t1"}).encode() + b"\n"
    with reports.open("ab") as f:
        f.write(line)
    assert "t1" in index.snapshot()
    assert taken == [line], "the poll took in only the appended line"
    assert index._offset == reports.stat().st_size
    taken.clear()
    assert "t1" in index.snapshot()
    assert taken == [], "a poll of an untouched file takes in nothing"


# Lines json.loads rejects with something other than JSONDecodeError: an array
# nested deeper than the parser can recurse (RecursionError), and an int past
# Python's 4300-digit limit for int(str) (a plain ValueError).
_DEEP_LINE = "[" * 200_000 + "]" * 200_000
_BIG_INT_LINE = '{"n": ' + "1" * 5000 + "}"


def _in_a_new_thread(func, *args):
    """func(*args) in a new thread, as the server's handlers run json.loads and
    json.dumps. A new thread starts near the top of its stack; the thread a
    test runs in is deep in pytest's, and there both give up sooner."""
    results = []
    thread = threading.Thread(target=lambda: results.append(func(*args)))
    thread.start()
    thread.join()
    (result,) = results  # empty when func raised (the thread printed why)
    return result


def _parses(text):
    try:
        json.loads(text)
    except RecursionError:
        return False
    return True


# CPython 3.14 sizes the recursion limit to the stack, so a big enough stack
# parses even _DEEP_LINE, which there cannot reach the RecursionError it is for.
_DEEP_LINE_PARSES = _in_a_new_thread(_parses, _DEEP_LINE)
_BAD_LINES = [
    pytest.param(
        _DEEP_LINE,
        id="deep",
        marks=pytest.mark.skipif(
            _DEEP_LINE_PARSES, reason="a new thread's stack parses _DEEP_LINE here"
        ),
    ),
    pytest.param(_BIG_INT_LINE, id="big-int"),
]


def test_reactions_skip_lines_json_cannot_parse(tmp_path):
    # Both come before the reaction: a read that raised on them would never
    # reach it, and would raise again on every poll after.
    reports = _board._reports_path(tmp_path)
    reports.parent.mkdir(parents=True)
    reaction = json.dumps({"button": "task-done", "re": "t1"})
    reports.write_bytes(f"{_DEEP_LINE}\n{_BIG_INT_LINE}\n{reaction}\n".encode())
    index = _board._Reactions(tmp_path)
    assert index.snapshot()["t1"]["button"] == "task-done"
    assert index.snapshot()["t1"]["button"] == "task-done", "and on the next poll"


@pytest.mark.parametrize("bad", _BAD_LINES)
def test_agent_list_answers_past_a_line_json_cannot_parse(served, bad):
    # Raised out of the handler, such a line dropped the connection on every
    # poll for as long as it stayed inside the 512 KiB window.
    root, _server, port = served
    task_id = _board._append_agent(root, "task", "press done", None)
    with _board._agent_path(root).open("ab") as f:
        f.write(bad.encode() + b"\n")
    _react(port, task_id)
    assert _listed_reaction(port)["button"] == "task-done"


@pytest.mark.parametrize("bad", _BAD_LINES)
def test_report_list_answers_past_a_line_json_cannot_parse(served, bad):
    root, _server, port = served
    before = {"button": "note", "text": "before"}
    assert _request(port, "POST", "/api/report", before)[0] == 200
    with _board._reports_path(root).open("ab") as f:
        f.write(bad.encode() + b"\n")
    after = {"button": "bug", "text": "after"}
    assert _request(port, "POST", "/api/report", after)[0] == 200
    status, body = _request(port, "GET", "/api/reports")
    assert status == 200
    assert _listed_reports(body) == [("note", "before"), ("bug", "after")]


def _listed_reports(body):
    """(button, text) of each report an /api/reports body lists, leaving out
    the ones that are not objects: a line that parses lists as itself, and
    can be nested as deep as a handler could send (so decode it as one)."""
    reports = _in_a_new_thread(json.loads, body)["reports"]
    return [(r["button"], r["text"]) for r in reports if isinstance(r, dict)]


# The escape of a lone surrogate. json.loads accepts it, but the str it gives
# back has no UTF-8 encoding. Python's json.dumps writes one for text decoded
# with surrogateescape: a file name with a byte that is not UTF-8, say.
_LONE_SURROGATE = '"caf\\udce9"'


def test_lists_answer_past_text_utf_8_cannot_carry(served):
    # Encoding the response raised, and the connection dropped, on every poll
    # while such a line stayed in the window.
    root, _server, port = served
    with _board._agent_path(root).open("a") as f:
        f.write('{"id": "t1", "type": "task", "text": ' + _LONE_SURROGATE + "}\n")
    with _board._reports_path(root).open("a") as f:
        f.write('{"button": "note", "text": ' + _LONE_SURROGATE + "}\n")

    status, body = _request(port, "GET", "/api/agent")
    assert status == 200
    (task,) = json.loads(body)["entries"]
    assert (task["id"], task["text"][:3]) == ("t1", "caf")
    status, body = _request(port, "GET", "/api/reports")
    assert status == 200
    [(button, text)] = _listed_reports(body)
    assert (button, text[:3]) == ("note", "caf")


@pytest.mark.parametrize("polled_before", [False, True])
def test_reaction_with_text_utf_8_cannot_carry_outlives_the_reports_window(
    served, polled_before
):
    # Such a reaction made /api/agent raise as above, and since settlement is
    # read over the whole file, it kept doing so past the reports window. The
    # first poll after the notes reads the file whole, as after a restart.
    root, _server, port = served
    task_id = _board._append_agent(root, "task", "press done", None)
    reports = _board._reports_path(root)
    reports.write_text(
        f'{{"button": "task-done", "re": "{task_id}", "text": {_LONE_SURROGATE}}}\n'
    )
    if polled_before:
        assert _listed_reaction(port)["button"] == "task-done"
    after = reports.stat().st_size
    note = {"button": "note", "text": "x" * _board._MAX_TEXT_LEN}
    while reports.stat().st_size - after <= _board._MAX_LIST_BYTES:
        assert _request(port, "POST", "/api/report", note)[0] == 200
    assert _listed_reaction(port)["button"] == "task-done"


def _nested(depth):
    return "[" * depth + "]" * depth


@pytest.fixture(scope="module")
def parse_limit():
    """The deepest array json.loads accepts in a new thread."""
    if _DEEP_LINE_PARSES:
        pytest.skip("a new thread's stack parses _DEEP_LINE here")
    parses, fails = 1, 200_000  # _DEEP_LINE's depth
    while fails - parses > 1:
        depth = (parses + fails) // 2
        if _in_a_new_thread(_parses, _nested(depth)):
            parses = depth
        else:
            fails = depth
    return parses


# json.loads accepts an array nested a few levels short of its limit, and the
# response nests it deeper still: json.dumps raised, and the connection dropped
# on every poll. How many levels short depends on the Python and its stack, so
# the tests below try every depth from 32 levels short up to the limit. What a
# handler sent is decoded in a new thread too: json.dumps and json.loads reach
# the same depth, and a handler starts deeper in its stack than a new thread.
def _near(limit):
    return range(limit - 32, limit + 1)


def test_report_list_answers_past_a_report_nested_near_the_limit(served, parse_limit):
    root, _server, port = served
    for depth in _near(parse_limit):
        _board._reports_path(root).write_text(
            '{"button": "note", "text": "before"}\n'
            + _nested(depth)
            + '\n{"button": "bug", "text": "after"}\n'
        )
        status, body = _request(port, "GET", "/api/reports")
        assert status == 200, f"depth {depth}"
        assert _listed_reports(body) == [("note", "before"), ("bug", "after")]


def test_agent_list_answers_past_an_entry_nested_near_the_limit(served, parse_limit):
    root, _server, port = served
    task_id = _board._append_agent(root, "task", "press done", None)
    task_line = _board._agent_path(root).read_text()
    for depth in _near(parse_limit):
        entry = '{"type": "note", "x": ' + _nested(depth - 1) + "}\n"
        _board._agent_path(root).write_text(task_line + entry)
        status, body = _request(port, "GET", "/api/agent")
        assert status == 200, f"depth {depth}"
        assert _in_a_new_thread(json.loads, body)["entries"][0]["id"] == task_id


def test_agent_list_answers_past_a_reaction_nested_near_the_limit(served, parse_limit):
    # Appended, as the server writes reactions, so each poll reads one more.
    root, _server, port = served
    task_id = _board._append_agent(root, "task", "press done", None)
    for depth in _near(parse_limit):
        with _board._reports_path(root).open("a") as f:
            f.write(
                f'{{"button": "task-done", "re": "{task_id}", '
                f'"text": {_nested(depth - 1)}}}\n'
            )
        status, body = _request(port, "GET", "/api/agent")
        assert status == 200, f"depth {depth}"
        assert _in_a_new_thread(json.loads, body)["entries"][0]["id"] == task_id


def test_reactions_survive_a_failed_read(tmp_path, monkeypatch):
    reports = _board._reports_path(tmp_path)
    reports.parent.mkdir(parents=True)
    reports.write_text(json.dumps({"button": "task-done", "re": "t1"}) + "\n")
    index = _board._Reactions(tmp_path)
    assert "t1" in index.snapshot()

    real_open = Path.open

    def refuse(self, *args, **kwargs):
        if self == reports:
            raise PermissionError(13, "Permission denied", str(self))
        return real_open(self, *args, **kwargs)

    with monkeypatch.context() as m:
        m.setattr(Path, "open", refuse)
        assert "t1" in index.snapshot(), "a read that fails once reopens nothing"
    reports.unlink()
    assert index.snapshot() == {}, "a deleted file settles nothing"


def test_tasks_still_list_with_a_directory_at_reports_jsonl(served):
    # A cloned repo can ship .den/board/reports.jsonl as a directory. The
    # tasks still list, open, as they did when the tail read the file.
    root, _server, port = served
    _board._append_agent(root, "task", "press done", None)
    _board._reports_path(root).mkdir()
    assert _listed_reaction(port) is None
    assert _listed_reaction(port) is None, "and on the next poll"


def test_reactions_close_what_they_open(tmp_path):
    # Every poll opens reports.jsonl, so one descriptor left behind per poll
    # (a directory there is the case that does it) runs a long-lived board
    # out of them.
    listings = (Path("/proc/self/fd"), Path("/dev/fd"))
    fd_dir = next((d for d in listings if d.is_dir()), None)
    if fd_dir is None:
        pytest.skip("no per-process descriptor listing here")
    _board._reports_path(tmp_path).mkdir(parents=True)
    index = _board._Reactions(tmp_path)
    before = len(list(fd_dir.iterdir()))
    for _ in range(5):
        assert index.snapshot() == {}
    assert len(list(fd_dir.iterdir())) == before


def test_derived_ids_of_duplicate_lines_stay_distinct(served):
    root, _server, port = served
    raw = json.dumps({"type": "task", "text": "same"}) + "\n"
    (root / ".den" / "board" / "agent.jsonl").write_text(raw + raw, encoding="utf-8")
    _status, body = _request(port, "GET", "/api/agent")
    ids = [e["id"] for e in json.loads(body)["entries"]]
    assert len(ids) == 2 and ids[0] != ids[1]

    _status, body2 = _request(port, "GET", "/api/agent")
    assert [e["id"] for e in json.loads(body2)["entries"]] == ids, "stable"


def test_append_agent_survives_lone_surrogate(tmp_path):
    entry_id = _board._append_agent(tmp_path, "task", "bad\udcffbyte", None)
    line = json.loads(
        (tmp_path / ".den" / "board" / "agent.jsonl").read_text().splitlines()[0]
    )
    assert line["id"] == entry_id
    assert "\udcff" not in line["text"], "surrogate scrubbed, no crash"


def test_page_sends_anti_framing_headers(served):
    _root, _server, port = served
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        conn.request("GET", "/")
        resp = conn.getresponse()
        resp.read()
        assert resp.getheader("X-Frame-Options") == "DENY"
        assert "frame-ancestors" in (resp.getheader("Content-Security-Policy") or "")
    finally:
        conn.close()


def test_main_serve_path_writes_lock_and_reprints(tmp_path, capsys):
    board = tmp_path / ".den" / "board"
    board.mkdir(parents=True)
    (board / "board.json").write_text(json.dumps({"port": 0, "title": "Rig"}))

    thread = threading.Thread(
        target=_board.main, args=(["--dir", str(tmp_path)],), daemon=True
    )
    thread.start()
    lock = board / "server.json"
    for _ in range(100):
        if lock.is_file() and lock.read_text().strip():
            break
        time.sleep(0.05)
    info = json.loads(lock.read_text())
    assert info["pid"] == os.getpid()
    assert info["root"] == str(tmp_path)

    status, body = _request(info["port"], "GET", "/api/ping")
    assert status == 200
    assert json.loads(body)["root"] == str(tmp_path)

    assert _board.main(["--dir", str(tmp_path)]) == 0
    assert "already running" in capsys.readouterr().out


# --------------------------------------------------------------------------- #
# symlink hardening: a cloned repo ships .den/board/, so a symlink there would
# turn every board write into an append to a file outside the workspace.
# --------------------------------------------------------------------------- #

_OUTSIDE_TEXT = "ORIGINAL\n"


def _outside(tmp_path):
    path = tmp_path / "outside.log"
    path.write_text(_OUTSIDE_TEXT)
    return path


def test_agent_append_refuses_symlinked_file(tmp_path, capsys, symlink):
    outside = _outside(tmp_path)
    proj = tmp_path / "repo"
    (proj / ".den" / "board").mkdir(parents=True)
    symlink(outside, _board._agent_path(proj))
    assert _board.main(["task", "--dir", str(proj), "do the thing"]) == 1
    assert outside.read_text() == _OUTSIDE_TEXT
    assert "is a symlink" in capsys.readouterr().err


def test_agent_append_refuses_symlinked_board_dir(tmp_path, symlink):
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    proj = tmp_path / "repo"
    (proj / ".den").mkdir(parents=True)
    symlink(elsewhere, proj / ".den" / "board")
    assert _board.main(["task", "--dir", str(proj), "do the thing"]) == 1
    assert list(elsewhere.iterdir()) == []


def test_report_post_refuses_symlinked_reports_file(served, tmp_path, symlink):
    _root, _server, port = served
    outside = _outside(tmp_path)
    reports = _board._reports_path(tmp_path)
    reports.unlink(missing_ok=True)
    symlink(outside, reports)
    status, _body = _request(port, "POST", "/api/report", {"button": "bug"})
    assert status == 500
    assert outside.read_text() == _OUTSIDE_TEXT


def test_tail_lines_ignores_symlinked_file(tmp_path, symlink):
    outside = tmp_path / "secrets.txt"
    outside.write_text('{"leaked": true}\n')
    proj = tmp_path / "repo"
    (proj / ".den" / "board").mkdir(parents=True)
    reports = _board._reports_path(proj)
    symlink(outside, reports)
    assert _board._tail_lines(proj, reports, 10_000) == []


def test_reactions_ignore_a_symlinked_reports_file(tmp_path, symlink):
    proj = tmp_path / "repo"
    reports = _board._reports_path(proj)
    reports.parent.mkdir(parents=True)
    reaction = json.dumps({"button": "task-done", "re": "t1"}) + "\n"
    reports.write_text(reaction)
    index = _board._Reactions(proj)
    assert "t1" in index.snapshot()
    outside = tmp_path / "outside.jsonl"
    outside.write_text(reaction)
    reports.unlink()
    symlink(outside, reports)
    assert index.snapshot() == {}, "a symlinked board file reads as empty"


def test_scaffold_refuses_symlinked_config(tmp_path, capsys, symlink):
    outside = tmp_path / "elsewhere.json"
    outside.write_text('{"title": "planted"}\n')
    proj = tmp_path / "repo"
    (proj / ".den" / "board").mkdir(parents=True)
    symlink(outside, proj / ".den" / "board" / "board.json")
    config = _board.ensure_scaffold(proj)
    assert config["title"] is None, "the planted config is not used"
    assert "is a symlink" in capsys.readouterr().err


def _plant_lock_symlink(tmp_path, symlink, payload="outside file\n"):
    """A workspace whose .den/board/server.json is a symlink to a file the board
    has no business reading, writing, or deleting."""
    outside = tmp_path / "outside.json"
    outside.write_text(payload)
    proj = tmp_path / "repo"
    (proj / ".den" / "board").mkdir(parents=True)
    symlink(outside, _board._lock_path(proj))
    return proj, outside


def test_existing_instance_ignores_symlinked_lock(tmp_path, capsys, symlink):
    # A planted lock could otherwise name any port for `den board` to probe and
    # any pid for it to trust.
    proj, outside = _plant_lock_symlink(
        tmp_path, symlink, json.dumps({"pid": 1, "port": 8484}) + "\n"
    )
    assert _board._existing_instance(proj) is None
    assert outside.is_file(), "the stale-lock cleanup must not reach the target"
    assert "is a symlink" in capsys.readouterr().err


def test_release_lock_refuses_symlinked_lock(tmp_path, symlink):
    # The planted file names our own pid, which is what used to buy the unlink.
    proj, outside = _plant_lock_symlink(
        tmp_path, symlink, json.dumps({"pid": os.getpid(), "port": 1}) + "\n"
    )
    _board._release_lock(proj)
    assert outside.is_file()
    assert _board._lock_path(proj).is_symlink(), (
        "a lock den refuses to read is not one it may clear"
    )


def test_claim_lock_refuses_symlinked_lock(tmp_path, capsys, symlink):
    proj, outside = _plant_lock_symlink(tmp_path, symlink)
    assert _board._claim_lock(proj) is False
    assert outside.read_text() == "outside file\n"
    # O_EXCL alone also returns False here, but silently, leaving the caller to
    # "take over" a lock it cannot see was planted. The refusal must be spoken.
    assert "is a symlink" in capsys.readouterr().err


def test_write_lock_refuses_symlinked_lock(tmp_path, symlink):
    proj, outside = _plant_lock_symlink(tmp_path, symlink)
    assert _board._write_lock(proj, {"pid": 1, "port": 8484}) is False
    assert outside.read_text() == "outside file\n"


def test_unlink_lock_refuses_symlinked_lock(tmp_path, symlink):
    proj, outside = _plant_lock_symlink(tmp_path, symlink)
    _board._unlink_lock(proj)
    assert outside.is_file()
    assert _board._lock_path(proj).is_symlink(), "the link is left as evidence"


def test_lock_round_trip_still_works(tmp_path):
    assert _board._claim_lock(tmp_path) is True
    assert _board._write_lock(tmp_path, {"pid": os.getpid(), "port": 8484}) is True
    assert _board._read_lock(tmp_path) == {"pid": os.getpid(), "port": 8484}
    _board._release_lock(tmp_path)
    assert not _board._lock_path(tmp_path).exists()


@pytest.mark.skipif(
    sys.platform == "win32", reason="POSIX mode bits; the ubuntu jobs cover this"
)
def test_board_files_are_not_created_executable(tmp_path):
    # os.open's default mode is 0o777, so an unspecified mode ships an
    # executable reports.jsonl / agent.jsonl.
    _board._append_agent(tmp_path, "task", "do the thing", None)
    _board._append_line(tmp_path, _board._reports_path(tmp_path), "{}\n")
    for path in (_board._agent_path(tmp_path), _board._reports_path(tmp_path)):
        mode = path.stat().st_mode & 0o777
        assert not mode & 0o111, f"{path.name} is executable ({mode:o})"
        assert mode == 0o666 & ~_umask(), f"{path.name} is {mode:o}"


def test_main_does_not_serve_when_the_lock_cannot_be_recorded(
    tmp_path, monkeypatch, capsys
):
    """An unrecorded server is invisible to _existing_instance, so a second
    `den board` would start a twin on another port and split the reports."""
    board = tmp_path / ".den" / "board"
    board.mkdir(parents=True)
    (board / "board.json").write_text(json.dumps({"port": 0}))
    monkeypatch.setattr(_board, "_write_lock", lambda root, info: False)
    # Returns instead of blocking in serve_forever: a hang here IS the failure.
    assert _board.main(["--dir", str(tmp_path)]) == 1
    out = capsys.readouterr()
    assert "serving" not in out.out
    assert "not serving" in out.err
    assert not (board / "server.json").exists(), "the claim is released"
    assert _board._existing_instance(tmp_path) is None


def test_non_utf8_lock_reads_as_an_invalid_lock(tmp_path):
    # A repo can ship .den/board/server.json with any bytes in it. That is an
    # invalid lock, as it always was -- not a UnicodeDecodeError out of den board.
    lock = _board._lock_path(tmp_path)
    lock.parent.mkdir(parents=True)
    lock.write_bytes(b'{"pid": 1, "port": 8484, "root": "\xff\xfe"}\n')
    assert _board._read_lock(tmp_path) is None
    assert _board._existing_instance(tmp_path) is None
    # Left in place, exactly as an unparseable lock always was: _acquire's
    # takeover path clears it after no live twin answers.
    assert lock.is_file()
    _board._unlink_lock(tmp_path)
    assert _board._claim_lock(tmp_path) is True, "den board can still take over"


def test_non_utf8_lock_does_not_block_release(tmp_path):
    lock = _board._lock_path(tmp_path)
    lock.parent.mkdir(parents=True)
    lock.write_bytes(b"\xff\xfe not json at all")
    _board._release_lock(tmp_path)  # must not raise
    assert lock.is_file(), "not ours to remove: no readable pid says so"


def test_main_does_not_serve_when_the_lock_write_raises(tmp_path, monkeypatch, capsys):
    """_write_lock reaches os.open, which raises on a full or read-only
    filesystem (and on O_NOFOLLOW catching a symlink swapped in after the
    pre-check). That must take the same path as a refusal, not a traceback."""
    board = tmp_path / ".den" / "board"
    board.mkdir(parents=True)
    (board / "board.json").write_text(json.dumps({"port": 0}))

    def _boom(root, info):
        raise OSError(28, "No space left on device")

    monkeypatch.setattr(_board, "_write_lock", _boom)
    # Returns instead of raising, and instead of blocking in serve_forever.
    assert _board.main(["--dir", str(tmp_path)]) == 1
    out = capsys.readouterr()
    assert "serving" not in out.out
    assert "No space left on device" in out.err
    assert "not serving" in out.err
    assert not (board / "server.json").exists(), "the claim is released"
