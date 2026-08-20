"""Tests for den board (den/_board.py): scaffold, HTTP surface, lock logic."""

from __future__ import annotations

import http.client
import json
import socket
import threading

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
    lock.write_text(json.dumps({"pid": __import__("os").getpid(), "port": 1}))
    _board._release_lock(tmp_path)
    assert not lock.exists(), "our own lock is removed"


def test_tail_lines_returns_only_complete_lines(tmp_path):
    path = tmp_path / "reports.jsonl"
    entries = [json.dumps({"n": i, "pad": "x" * 20}) + "\n" for i in range(5)]
    path.write_text("".join(entries), encoding="utf-8")

    assert _board._tail_lines(path, 10_000) == [e.rstrip("\n") for e in entries]

    window = len(entries[0]) * 2 + 10  # cuts into entry 2 -> partial dropped
    tail = _board._tail_lines(path, window)
    assert 0 < len(tail) < 5
    assert all(json.loads(line) for line in tail), "every returned line parses"
    assert json.loads(tail[-1])["n"] == 4
