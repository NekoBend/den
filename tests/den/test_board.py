"""Tests for den board (den/_board.py): scaffold, HTTP surface, lock logic."""

from __future__ import annotations

import http.client
import json
import os
import socket
import threading
import time

import pytest

from den import _board


@pytest.fixture
def served(tmp_path):
    """A live board server on an OS-picked port, torn down after the test."""
    config = _board.ensure_scaffold(tmp_path)
    server = _board.make_server(tmp_path, config, preferred_port=0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield tmp_path, server, server.server_address[1]
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)


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
    thread = threading.Thread(target=srv.serve_forever, daemon=True)
    thread.start()
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


def test_scaffold_refuses_symlinked_config(tmp_path, capsys, symlink):
    outside = tmp_path / "elsewhere.json"
    outside.write_text('{"title": "planted"}\n')
    proj = tmp_path / "repo"
    (proj / ".den" / "board").mkdir(parents=True)
    symlink(outside, proj / ".den" / "board" / "board.json")
    config = _board.ensure_scaffold(proj)
    assert config["title"] is None, "the planted config is not used"
    assert "is a symlink" in capsys.readouterr().err
