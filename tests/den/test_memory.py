"""Tests for den memory (den/_memory.py)."""

import io
import json
import os
import sys

import pytest

from den import _memory
from den._memory import main as memory_main


def _mem(proj):
    return proj / ".den" / "memory.md"


def _history(proj):
    h = proj / ".den" / "history"
    return sorted(h.iterdir()) if h.is_dir() else []


def _save(proj, monkeypatch, text):
    monkeypatch.chdir(proj)
    monkeypatch.setattr("sys.stdin", io.StringIO(text))
    assert memory_main(["save"]) == 0


# --------------------------------------------------------------------------- #
# add (low-friction append)
# --------------------------------------------------------------------------- #


def test_add_creates_memory_from_args(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    assert memory_main(["add", "use", "ruff", "for", "lint"]) == 0
    assert _mem(tmp_path).read_text() == "use ruff for lint\n"


def test_add_appends_with_newline_separation(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    _mem(tmp_path).parent.mkdir(parents=True)
    _mem(tmp_path).write_text("first fact")  # no trailing newline
    assert memory_main(["add", "second fact"]) == 0
    assert _mem(tmp_path).read_text() == "first fact\nsecond fact\n"


def test_add_reads_stdin_when_no_args(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr("sys.stdin", io.StringIO("piped decision\n"))
    assert memory_main(["add"]) == 0
    assert _mem(tmp_path).read_text() == "piped decision\n"


def test_add_rejects_empty(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr("sys.stdin", io.StringIO("   \n"))
    assert memory_main(["add"]) == 2
    assert not _mem(tmp_path).is_file()


def test_add_checkpoints_previous_content(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    assert memory_main(["add", "v1"]) == 0  # creates, nothing to snapshot yet
    assert _history(tmp_path) == []
    assert memory_main(["add", "v2"]) == 0  # snapshots the pre-append content
    snaps = _history(tmp_path)
    assert len(snaps) == 1
    assert snaps[0].read_text() == "v1\n"
    assert _mem(tmp_path).read_text() == "v1\nv2\n"


# --------------------------------------------------------------------------- #
# den dir resolution
# --------------------------------------------------------------------------- #


def test_find_den_dir_uses_cwd_when_absent(tmp_path):
    assert _memory._find_den_dir(tmp_path) == tmp_path / ".den"


def test_find_den_dir_discovers_ancestor(tmp_path):
    (tmp_path / ".den").mkdir()
    sub = tmp_path / "a" / "b"
    sub.mkdir(parents=True)
    assert _memory._find_den_dir(sub) == tmp_path / ".den"


# --------------------------------------------------------------------------- #
# show / save / path
# --------------------------------------------------------------------------- #


def test_show_empty_when_absent(tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    assert memory_main(["show"]) == 0
    assert capsys.readouterr().out == ""


def test_save_then_show_roundtrips(tmp_path, monkeypatch, capsys):
    _save(tmp_path, monkeypatch, "# Memory\n\n- fact\n")
    assert _mem(tmp_path).read_text() == "# Memory\n\n- fact\n"
    capsys.readouterr()
    assert memory_main(["show"]) == 0
    assert capsys.readouterr().out == "# Memory\n\n- fact\n"


def test_save_from_file(tmp_path, monkeypatch):
    src = tmp_path / "src.md"
    src.write_text("from file\n")
    monkeypatch.chdir(tmp_path)
    assert memory_main(["save", "--file", str(src)]) == 0
    assert _mem(tmp_path).read_text() == "from file\n"


def test_path_prints_resolved(tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    assert memory_main(["path"]) == 0
    assert capsys.readouterr().out.strip() == str(_mem(tmp_path))


# --------------------------------------------------------------------------- #
# checkpoint: content-gated, captures direct edits
# --------------------------------------------------------------------------- #


def test_checkpoint_noop_without_memory(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    assert memory_main(["checkpoint"]) == 0
    assert _history(tmp_path) == []


def test_checkpoint_is_content_gated(tmp_path, monkeypatch):
    _save(tmp_path, monkeypatch, "v1\n")
    monkeypatch.chdir(tmp_path)
    assert memory_main(["checkpoint"]) == 0
    assert len(_history(tmp_path)) == 1
    # unchanged -> no new snapshot
    assert memory_main(["checkpoint"]) == 0
    assert len(_history(tmp_path)) == 1


def test_checkpoint_captures_direct_edit(tmp_path, monkeypatch):
    """A direct write (model's own editor) is captured on the next checkpoint."""
    _save(tmp_path, monkeypatch, "v1\n")
    monkeypatch.chdir(tmp_path)
    memory_main(["checkpoint"])  # snapshot v1
    # newline="" writes LF (like den + an LF editor) so the byte-compare below
    # holds on Windows, where write_text would otherwise translate to CRLF.
    _mem(tmp_path).write_text("v2 edited directly\n", newline="")  # bypass den save
    memory_main(["checkpoint"])  # snapshot v2
    snaps = [
        p.read_bytes() for p in _memory._snapshots(_memory._find_den_dir(tmp_path))
    ]
    assert b"v1\n" in snaps
    assert b"v2 edited directly\n" in snaps


def test_save_checkpoints_previous(tmp_path, monkeypatch):
    _save(tmp_path, monkeypatch, "old\n")
    _save(tmp_path, monkeypatch, "new\n")
    # the overwrite snapshotted "old" before writing "new"
    snaps = [
        p.read_bytes() for p in _memory._snapshots(_memory._find_den_dir(tmp_path))
    ]
    assert b"old\n" in snaps
    assert _mem(tmp_path).read_text() == "new\n"


# --------------------------------------------------------------------------- #
# log / restore / diff / clear
# --------------------------------------------------------------------------- #


def test_restore_brings_back_old_and_is_reversible(tmp_path, monkeypatch, capsys):
    _save(tmp_path, monkeypatch, "v1\n")
    _save(tmp_path, monkeypatch, "v2\n")  # snapshots v1
    monkeypatch.chdir(tmp_path)
    assert memory_main(["restore", "1"]) == 0  # newest snapshot == v1
    assert _mem(tmp_path).read_text() == "v1\n"
    # the current v2 was snapshotted before the restore, so it is recoverable
    snaps = [
        p.read_bytes() for p in _memory._snapshots(_memory._find_den_dir(tmp_path))
    ]
    assert b"v2\n" in snaps


def test_restore_out_of_range(tmp_path, monkeypatch):
    _save(tmp_path, monkeypatch, "v1\n")
    monkeypatch.chdir(tmp_path)
    assert memory_main(["restore", "99"]) == 1


def test_diff_reports_changes(tmp_path, monkeypatch, capsys):
    _save(tmp_path, monkeypatch, "alpha\n")
    _save(tmp_path, monkeypatch, "beta\n")  # snapshots alpha
    monkeypatch.chdir(tmp_path)
    capsys.readouterr()
    assert memory_main(["diff", "1"]) == 0
    out = capsys.readouterr().out
    assert "-alpha" in out
    assert "+beta" in out


def test_log_lists_newest_first(tmp_path, monkeypatch, capsys):
    _save(tmp_path, monkeypatch, "# first\n")
    monkeypatch.chdir(tmp_path)
    memory_main(["checkpoint"])  # snapshot "# first"
    _mem(tmp_path).write_text("# second\n")
    memory_main(["checkpoint"])  # snapshot "# second"
    capsys.readouterr()
    assert memory_main(["log"]) == 0
    lines = [ln for ln in capsys.readouterr().out.splitlines() if ln.strip()]
    assert lines[0].endswith("# second")
    assert lines[1].endswith("# first")


def test_clear_removes_and_snapshots(tmp_path, monkeypatch):
    _save(tmp_path, monkeypatch, "bye\n")
    monkeypatch.chdir(tmp_path)
    assert memory_main(["clear"]) == 0
    assert not _mem(tmp_path).exists()
    snaps = [
        p.read_bytes() for p in _memory._snapshots(_memory._find_den_dir(tmp_path))
    ]
    assert b"bye\n" in snaps


# --------------------------------------------------------------------------- #
# rotation + collision guard
# --------------------------------------------------------------------------- #


def test_rotation_keeps_limit(tmp_path):
    den = tmp_path / ".den"
    hist = den / "history"
    hist.mkdir(parents=True)
    for i in range(_memory.HISTORY_LIMIT + 5):
        (hist / f"memory.2026010100000{i:04d}.md").write_text(str(i))
    _memory._rotate(den)
    assert len(list(hist.iterdir())) == _memory.HISTORY_LIMIT


def test_checkpoint_collision_does_not_clobber(tmp_path, monkeypatch):
    """Two snapshots forced into the same timestamp must both survive."""
    den = tmp_path / ".den"
    den.mkdir()
    mem = den / "memory.md"
    monkeypatch.setattr(_memory, "_rotate", lambda d: None)

    class _Fixed:
        @staticmethod
        def now(tz=None):
            import datetime as _dt

            return _dt.datetime(2026, 1, 1, tzinfo=_dt.UTC)

    monkeypatch.setattr(_memory, "datetime", _Fixed)
    mem.write_text("a\n")
    _memory._do_checkpoint(den)
    mem.write_text("b\n")
    _memory._do_checkpoint(den)
    bodies = {p.read_text() for p in (den / "history").iterdir()}
    assert bodies == {"a\n", "b\n"}


def test_save_missing_file_returns_2(tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    assert memory_main(["save", "--file", str(tmp_path / "nope.md")]) == 2
    assert "cannot read" in capsys.readouterr().err


# --------------------------------------------------------------------------- #
# .clinerules mirror (cline CLI memory delivery)
# --------------------------------------------------------------------------- #


def _clinerules_mem(proj):
    return proj / ".clinerules" / "den-memory.md"


def _cline_cli_here(proj):
    """Simulate `den hook install --tool cline-cli`: a `.clinerules/` with the
    `den-imprint.md` marker the mirror gates on."""
    d = proj / ".clinerules"
    d.mkdir(exist_ok=True)
    (d / "den-imprint.md").write_text("# imprint\n", encoding="utf-8")


def test_add_mirrors_to_clinerules_when_present(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    _cline_cli_here(tmp_path)
    assert memory_main(["add", "use run_job for the entry function"]) == 0
    mirror = _clinerules_mem(tmp_path)
    assert mirror.is_file()
    assert "run_job" in mirror.read_text()
    assert mirror.read_text().startswith("<!-- den-managed")


def test_add_no_clinerules_does_not_create_one(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    assert memory_main(["add", "a fact"]) == 0
    assert _mem(tmp_path).is_file()
    assert not (tmp_path / ".clinerules").exists()  # non-cline workspace untouched


def test_add_extension_only_does_not_mirror(tmp_path, monkeypatch):
    # The cline EXTENSION install makes .clinerules/hooks/ but no den-imprint.md
    # marker; memory must NOT mirror there (the extension already injects per turn
    # via its hook -- mirroring too would double-deliver).
    monkeypatch.chdir(tmp_path)
    (tmp_path / ".clinerules" / "hooks").mkdir(parents=True)
    assert memory_main(["add", "x"]) == 0
    assert not _clinerules_mem(tmp_path).exists()


def test_clear_removes_clinerules_mirror(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    _cline_cli_here(tmp_path)
    memory_main(["add", "x"])
    assert _clinerules_mem(tmp_path).is_file()
    memory_main(["clear"])
    assert not _clinerules_mem(tmp_path).exists()  # stale mirror dropped


def test_save_refreshes_clinerules_mirror(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    _cline_cli_here(tmp_path)
    _save(tmp_path, monkeypatch, "# Memory\n\n- v1 fact\n")
    assert "v1 fact" in _clinerules_mem(tmp_path).read_text()
    _save(tmp_path, monkeypatch, "# Memory\n\n- v2 fact\n")
    assert "v2 fact" in _clinerules_mem(tmp_path).read_text()
    assert "v1 fact" not in _clinerules_mem(tmp_path).read_text()


def test_restore_refreshes_clinerules_mirror(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    _cline_cli_here(tmp_path)
    _save(tmp_path, monkeypatch, "v1\n")
    _save(tmp_path, monkeypatch, "v2\n")  # snapshots v1
    assert "v2" in _clinerules_mem(tmp_path).read_text()
    assert memory_main(["restore", "1"]) == 0  # newest snapshot == v1
    assert "v1" in _clinerules_mem(tmp_path).read_text()


# --------------------------------------------------------------------------- #
# symlink hardening
#
# A cloned repository ships the content and layout of .den/, so a symlink there
# is an attempt to make den read a file from outside the workspace into the
# model's context (memory.md is injected every turn and copied into history) or
# to overwrite one. den must follow none of them, in either direction.
# --------------------------------------------------------------------------- #

_OUTSIDE_TEXT = "PRIVATE KEY MATERIAL\n"


def _planted(tmp_path, symlink, name="memory.md"):
    """A workspace whose .den/<name> is a repo-shipped symlink to a file outside
    it. Returns (project dir, the outside file)."""
    secret = tmp_path / "id_ed25519"
    secret.write_text(_OUTSIDE_TEXT)
    proj = tmp_path / "repo"
    link = proj / ".den" / name
    link.parent.mkdir(parents=True, exist_ok=True)
    symlink(secret, link)
    return proj, secret


def test_show_refuses_symlinked_memory(tmp_path, monkeypatch, capsys, symlink):
    proj, _secret = _planted(tmp_path, symlink)
    monkeypatch.chdir(proj)
    assert memory_main(["show"]) == 1, "a refused read is an error, not an empty file"
    out = capsys.readouterr()
    assert "PRIVATE KEY" not in out.out, "the target must never be printed"
    assert "is a symlink" in out.err


def test_checkpoint_does_not_snapshot_symlinked_memory(tmp_path, monkeypatch, symlink):
    proj, _secret = _planted(tmp_path, symlink)
    monkeypatch.chdir(proj)
    assert memory_main(["checkpoint"]) == 0
    assert _history(proj) == [], "the target must not be copied into history"


def test_save_refuses_to_write_through_symlinked_memory(tmp_path, monkeypatch, symlink):
    proj, secret = _planted(tmp_path, symlink)
    monkeypatch.chdir(proj)
    monkeypatch.setattr("sys.stdin", io.StringIO("overwritten\n"))
    assert memory_main(["save"]) == 1
    assert secret.read_text() == _OUTSIDE_TEXT
    assert _mem(proj).is_symlink(), "den must not replace the link either"


def test_add_refuses_to_write_through_symlinked_memory(tmp_path, monkeypatch, symlink):
    proj, secret = _planted(tmp_path, symlink)
    monkeypatch.chdir(proj)
    assert memory_main(["add", "appended fact"]) == 1
    assert secret.read_text() == _OUTSIDE_TEXT


def test_clear_refuses_symlinked_memory(tmp_path, monkeypatch, symlink):
    proj, secret = _planted(tmp_path, symlink)
    monkeypatch.chdir(proj)
    assert memory_main(["clear"]) == 1
    assert secret.is_file() and secret.read_text() == _OUTSIDE_TEXT


def test_restore_refuses_symlinked_memory(tmp_path, monkeypatch, symlink):
    proj, secret = _planted(tmp_path, symlink)
    hist = proj / ".den" / "history"
    hist.mkdir()
    (hist / "memory.20260101T000000000000.md").write_text("snapshot\n")
    monkeypatch.chdir(proj)
    assert memory_main(["restore", "1"]) == 1
    assert secret.read_text() == _OUTSIDE_TEXT


def test_symlinked_den_dir_is_refused(tmp_path, monkeypatch, capsys, symlink):
    outside = tmp_path / "elsewhere"
    outside.mkdir()
    (outside / "memory.md").write_text("INJECTED\n")
    proj = tmp_path / "repo"
    proj.mkdir()
    symlink(outside, proj / ".den")
    monkeypatch.chdir(proj)
    assert memory_main(["show"]) == 1
    out = capsys.readouterr()
    assert "INJECTED" not in out.out
    assert "is a symlink" in out.err


def test_symlinked_history_dir_refuses_checkpoint(tmp_path, monkeypatch, symlink):
    outside = tmp_path / "elsewhere"
    outside.mkdir()
    proj = tmp_path / "repo"
    (proj / ".den").mkdir(parents=True)
    _mem(proj).write_text("real memory\n")
    symlink(outside, proj / ".den" / "history")
    monkeypatch.chdir(proj)
    assert memory_main(["checkpoint"]) == 1, (
        "asked for a checkpoint, could not make one"
    )
    assert list(outside.iterdir()) == [], "nothing may land outside the workspace"


def test_symlinked_snapshot_is_not_a_snapshot(tmp_path, monkeypatch, capsys, symlink):
    proj, _secret = _planted(
        tmp_path, symlink, name="history/memory.20260102T000000000000.md"
    )
    real = proj / ".den" / "history" / "memory.20260101T000000000000.md"
    real.write_text("real snapshot\n")
    monkeypatch.chdir(proj)
    assert _memory._snapshots(proj / ".den") == [real]
    assert memory_main(["log"]) == 0
    out = capsys.readouterr().out
    assert "real snapshot" in out
    assert "PRIVATE KEY" not in out


def test_mirror_refuses_symlinked_clinerules_memory(tmp_path, monkeypatch, symlink):
    secret = tmp_path / "id_ed25519"
    secret.write_text(_OUTSIDE_TEXT)
    proj = tmp_path / "repo"
    (proj / ".den").mkdir(parents=True)
    _cline_cli_here(proj)  # the marker that turns mirroring on
    symlink(secret, proj / ".clinerules" / "den-memory.md")
    monkeypatch.chdir(proj)
    assert memory_main(["add", "a fact"]) == 0, "memory itself is fine"
    assert _mem(proj).read_text() == "a fact\n"
    assert secret.read_text() == _OUTSIDE_TEXT, (
        "the mirror must not write through the link"
    )


# --------------------------------------------------------------------------- #
# unreadable != absent
#
# Collapsing the two would make a write command take a memory.md it failed to
# read for an empty one and truncate content it never saw.
# --------------------------------------------------------------------------- #


@pytest.fixture
def unreadable():
    """`make(path, text)` -> a file that exists but den cannot read back.

    Skipped where POSIX mode bits do not bite: Windows ignores them, and root
    reads straight through 0o200. The directory-in-place test below covers the
    same `_UNREADABLE` path on every platform.
    """
    if sys.platform == "win32":
        pytest.skip("POSIX mode bits do not make a file unreadable on Windows")
    if getattr(os, "geteuid", lambda: 1)() == 0:
        pytest.skip("root reads through mode 0o200")

    def _make(path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o200)
        return path

    return _make


def test_add_refuses_unreadable_memory(tmp_path, monkeypatch, unreadable):
    proj = tmp_path / "repo"
    mem = unreadable(_mem(proj), "important prior content\n")
    monkeypatch.chdir(proj)
    assert memory_main(["add", "a new fact"]) == 1
    mem.chmod(0o600)
    assert mem.read_text() == "important prior content\n", "not truncated"
    assert _history(proj) == []


def test_save_refuses_unreadable_memory(tmp_path, monkeypatch, unreadable):
    proj = tmp_path / "repo"
    mem = unreadable(_mem(proj), "important prior content\n")
    monkeypatch.chdir(proj)
    monkeypatch.setattr("sys.stdin", io.StringIO("replacement\n"))
    assert memory_main(["save"]) == 1
    mem.chmod(0o600)
    assert mem.read_text() == "important prior content\n"
    assert _history(proj) == [], "no checkpoint was possible, so no write happened"


def test_clear_refuses_unreadable_memory(tmp_path, monkeypatch, unreadable):
    proj = tmp_path / "repo"
    mem = unreadable(_mem(proj), "important prior content\n")
    monkeypatch.chdir(proj)
    assert memory_main(["clear"]) == 1
    assert mem.exists(), "deleting what cannot be snapshotted is not reversible"


def test_write_commands_refuse_a_directory_in_place_of_memory(
    tmp_path, monkeypatch, capsys
):
    # Same _UNREADABLE path as the 0o200 tests, but it bites as root and on
    # Windows too, so this one always runs.
    proj = tmp_path / "repo"
    _mem(proj).mkdir(parents=True)
    # a snapshot, so restore reaches the unreadable check instead of stopping at
    # "no snapshot #1"
    hist = proj / ".den" / "history"
    hist.mkdir()
    (hist / "memory.20260101T000000000000.md").write_text("older snapshot\n")
    monkeypatch.chdir(proj)
    monkeypatch.setattr("sys.stdin", io.StringIO("replacement\n"))
    for argv in (["show"], ["add", "x"], ["save"], ["clear"], ["diff"], ["restore"]):
        assert memory_main(argv) == 1, argv
    assert _mem(proj).is_dir()
    assert len(_history(proj)) == 1, "nothing was checkpointed"
    assert "cannot read" in capsys.readouterr().err


def test_unreadable_memory_does_not_drop_the_clinerules_mirror(
    tmp_path, monkeypatch, unreadable
):
    proj = tmp_path / "repo"
    proj.mkdir()
    _cline_cli_here(proj)
    mirror = _clinerules_mem(proj)
    mirror.write_text("<!-- den-managed -->\n\nprior mirror\n")
    unreadable(_mem(proj), "prior memory\n")
    monkeypatch.chdir(proj)
    assert _memory.mirror_to_clinerules(proj / ".den") is False
    assert mirror.read_text().endswith("prior mirror\n"), "mirror left alone"


def test_restore_refuses_unreadable_memory(tmp_path, monkeypatch, unreadable):
    # restore's promise is that what it replaces stays recoverable; with no
    # snapshot of the current content possible, it must not write.
    proj = tmp_path / "repo"
    hist = proj / ".den" / "history"
    hist.mkdir(parents=True)
    (hist / "memory.20260101T000000000000.md").write_text("older snapshot\n")
    mem = unreadable(_mem(proj), "important prior content\n")
    monkeypatch.chdir(proj)
    assert memory_main(["restore", "1"]) == 1
    mem.chmod(0o600)
    assert mem.read_text() == "important prior content\n", "not truncated"
    assert len(_history(proj)) == 1, "no checkpoint was possible"


def test_mirror_survives_a_directory_at_the_mirror_path(tmp_path, monkeypatch, capsys):
    # `.clinerules/den-memory.md` as a DIRECTORY: the mirror write must refuse,
    # not raise IsADirectoryError out of `den hook memory add`.
    proj = tmp_path / "repo"
    proj.mkdir()
    _cline_cli_here(proj)
    _clinerules_mem(proj).mkdir()
    monkeypatch.chdir(proj)
    assert memory_main(["add", "a fact"]) == 0, "memory itself still saves"
    assert _mem(proj).read_text() == "a fact\n"
    assert _clinerules_mem(proj).is_dir()
    assert "not a regular file" in capsys.readouterr().err


def test_clear_survives_a_directory_at_the_mirror_path(tmp_path, monkeypatch, capsys):
    # `.clinerules/den-memory.md` as a DIRECTORY hits the mirror's EMPTY branch,
    # which unlinks -- after clear has already deleted memory.md, so den used to
    # die half-done with IsADirectoryError.
    proj = tmp_path / "repo"
    proj.mkdir()
    _cline_cli_here(proj)
    _mem(proj).parent.mkdir(parents=True, exist_ok=True)
    _mem(proj).write_text("a fact\n")
    _clinerules_mem(proj).mkdir()
    monkeypatch.chdir(proj)
    assert memory_main(["clear"]) == 0
    assert not _mem(proj).exists(), "memory really was cleared"
    assert _clinerules_mem(proj).is_dir(), "the planted dir is left alone"
    assert "not a regular file" in capsys.readouterr().err


def test_save_of_whitespace_survives_a_directory_at_the_mirror_path(
    tmp_path, monkeypatch
):
    # Same branch, reached the other way: a whitespace-only save empties memory.
    proj = tmp_path / "repo"
    proj.mkdir()
    _cline_cli_here(proj)
    _clinerules_mem(proj).mkdir()
    _save(proj, monkeypatch, "   \n")
    assert _mem(proj).read_text() == "   \n"
    assert _clinerules_mem(proj).is_dir()


def test_a_directory_named_like_a_snapshot_is_not_one(tmp_path, monkeypatch, capsys):
    # `.den/history/memory.<stamp>.md/` passes the name test; every consumer of
    # the list then called read_bytes() on it.
    proj = tmp_path / "repo"
    hist = proj / ".den" / "history"
    hist.mkdir(parents=True)
    (hist / "memory.20260102T000000000000.md").mkdir()
    real = hist / "memory.20260101T000000000000.md"
    real.write_text("real snapshot\n")
    _mem(proj).write_text("current\n")
    monkeypatch.chdir(proj)
    assert _memory._snapshots(proj / ".den") == [real]
    assert memory_main(["log"]) == 0
    assert memory_main(["diff", "1"]) == 0
    assert memory_main(["restore", "1"]) == 0
    assert _mem(proj).read_text() == "real snapshot\n"
    assert memory_main(["checkpoint"]) == 0
    assert "real snapshot" in capsys.readouterr().out


# --------------------------------------------------------------------------- #
# a refused checkpoint is not "nothing to snapshot"
#
# The pre-write checkpoint IS the undo for save/add/clear/restore. When it is
# refused the safety net is gone, so the write must not happen either -- and a
# refusal must not read as the ordinary "content unchanged, nothing to do".
# --------------------------------------------------------------------------- #


def _no_history_workspace(tmp_path, symlink, kind="symlink"):
    """A workspace whose .den/history cannot hold a snapshot, with memory.md
    holding content that would need one."""
    outside = tmp_path / "elsewhere"
    outside.mkdir()
    proj = tmp_path / "repo"
    (proj / ".den").mkdir(parents=True)
    _mem(proj).write_text("the only copy\n")
    if kind == "symlink":
        symlink(outside, proj / ".den" / "history")
    else:
        (proj / ".den" / "history").write_text("not a directory\n")
    return proj, outside


def test_write_commands_abort_when_the_checkpoint_is_refused(
    tmp_path, monkeypatch, symlink
):
    proj, outside = _no_history_workspace(tmp_path, symlink)
    monkeypatch.chdir(proj)
    monkeypatch.setattr("sys.stdin", io.StringIO("replacement\n"))
    # restore stops earlier here (a symlinked history lists no snapshots), but it
    # must be just as harmless; the branch itself is pinned by the next test.
    for argv in (["save"], ["add", "a fact"], ["clear"], ["restore", "1"]):
        assert memory_main(argv) == 1, argv
        assert _mem(proj).read_text() == "the only copy\n", argv
    assert list(outside.iterdir()) == [], "nothing landed outside the workspace"


def test_restore_aborts_when_the_checkpoint_is_refused(tmp_path, monkeypatch):
    """restore is the one command that needs a USABLE history to read its source
    from, so it cannot reach the refusal through a symlinked history dir. Stub
    the checkpoint result to pin the branch itself: a restore that could not be
    made reversible must not run."""
    proj = tmp_path / "repo"
    hist = proj / ".den" / "history"
    hist.mkdir(parents=True)
    (hist / "memory.20260101T000000000000.md").write_text("older\n")
    _mem(proj).write_text("the only copy\n")
    monkeypatch.chdir(proj)
    monkeypatch.setattr(_memory, "_do_checkpoint", lambda den_dir: _memory._REFUSED)
    assert memory_main(["restore", "1"]) == 1
    assert _mem(proj).read_text() == "the only copy\n", "not replaced without an undo"


def test_write_commands_abort_when_history_is_a_file(tmp_path, monkeypatch):
    # A regular file at .den/history used to raise FileExistsError out of the
    # mkdir; it is a refusal like any other now.
    proj, _outside = _no_history_workspace(tmp_path, None, kind="file")
    monkeypatch.chdir(proj)
    monkeypatch.setattr("sys.stdin", io.StringIO("replacement\n"))
    for argv in (["checkpoint"], ["save"], ["add", "a fact"], ["clear"]):
        assert memory_main(argv) == 1, argv
    assert _mem(proj).read_text() == "the only copy\n"
    assert (proj / ".den" / "history").read_text() == "not a directory\n"


def test_hook_run_stays_tolerant_of_a_refused_checkpoint(
    tmp_path, monkeypatch, capsys, symlink
):
    # The per-turn hook must never fail on this: it still exits 0 and composes.
    from den._hook import main as hook_main

    proj, _outside = _no_history_workspace(tmp_path, symlink)
    (proj / ".den" / "imprint.md").write_text("IMP\n")
    monkeypatch.chdir(proj)
    assert hook_main(["run", "--event", "per-turn", "--tool", "claude"]) == 0
    out = capsys.readouterr()
    context = json.loads(out.out)["hookSpecificOutput"]["additionalContext"]
    assert "IMP" in context and "the only copy" in context
    assert "is a symlink" in out.err, "the refusal is still spoken"


def test_unchanged_content_is_not_a_refusal(tmp_path, monkeypatch):
    # The no-regression guard: "nothing to snapshot" must keep exiting 0 and let
    # the write through, which is the common path on every turn.
    monkeypatch.chdir(tmp_path)
    assert memory_main(["add", "v1"]) == 0
    assert memory_main(["checkpoint"]) == 0  # first snapshot
    assert memory_main(["checkpoint"]) == 0  # unchanged: no new snapshot, still 0
    assert len(_history(tmp_path)) == 1
    assert memory_main(["add", "v2"]) == 0
    assert _mem(tmp_path).read_text() == "v1\nv2\n"
