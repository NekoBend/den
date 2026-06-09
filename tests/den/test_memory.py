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
