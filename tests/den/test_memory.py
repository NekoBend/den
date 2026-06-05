"""Tests for den memory (den/_memory.py)."""

import io

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
    _mem(tmp_path).write_text("v2 edited directly\n")  # bypass den memory save
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

            return _dt.datetime(2026, 1, 1, tzinfo=_dt.timezone.utc)

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
