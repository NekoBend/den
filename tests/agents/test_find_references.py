"""Subprocess tests for find-references.py.

The script lives one directory up. It is invoked as a child process
(not imported) because its filename contains a hyphen and because the
public contract under test is its CLI: argv in, stdout + exit code out.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = (
    Path(__file__).resolve().parents[2]
    / "agents"
    / "src"
    / "shared"
    / "scripts"
    / "find-references.py"
)

# The scripts share their search plumbing through _common.py, which is importable
# (find-references.py itself is not: its filename has a hyphen).
sys.path.insert(0, str(SCRIPT.parent))

from _common import (  # ruff: ignore[module-import-not-at-top-of-file]
    parse_rg_line,
    parse_rg_output,
)


def run(
    *args: str, cwd: Path | None = None, env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    """Run find-references.py with `args`; return the completed process."""
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )


@pytest.fixture
def backends(tmp_path_factory: pytest.TempPathFactory) -> list[dict[str, str] | None]:
    """The two environments a search must return the same files in.

    `None` keeps the ambient PATH, which must have ripgrep on it; the second
    replaces PATH with one empty directory, so the script cannot find rg and
    has to walk the tree itself. BOTH halves are asserted, because either one
    failing quietly turns every parity test into the same backend run twice.
    Dropping only the PATH entries that contain rg is not enough: where rg
    sits in /usr/bin that removes every other tool with it.

    The directory is a sibling of the test's own tmp_path, never inside it, so
    it cannot show up in the tree being searched.
    """
    assert shutil.which("rg") is not None, (
        "these parity tests need ripgrep on PATH: without it BOTH legs below "
        "run the walk fallback and the comparison proves nothing. Install it "
        "(apt-get install ripgrep / brew install ripgrep); CI installs it in "
        "the job that runs tests/agents."
    )
    bin_dir = tmp_path_factory.mktemp("no-rg-bin")
    env = dict(os.environ)
    env["PATH"] = str(bin_dir)
    assert shutil.which("rg", path=env["PATH"]) is None
    return [None, env]


def symlink_or_skip(link: Path, target: Path) -> None:
    """Create `link` -> `target`, skipping the test where that is not allowed."""
    try:
        link.symlink_to(target)
    except (OSError, NotImplementedError) as exc:  # Windows without privileges
        pytest.skip(f"symlinks unavailable: {exc}")


def write(root: Path, rel: str, body: str) -> Path:
    """Create `root/rel` (with parents) containing `body`. Return the path."""
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    return path


# ---------- --def ----------


def test_def_finds_python_function(tmp_path: Path) -> None:
    write(tmp_path, "mod.py", "def widget():\n    return 1\n")
    proc = run("--def", "widget", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    lines = [ln for ln in proc.stdout.splitlines() if ln]
    assert len(lines) == 1
    file, lineno, kind, _context = lines[0].split(":", 3)
    assert file.endswith("mod.py")
    assert lineno == "1"
    assert kind == "def"


def test_def_finds_class(tmp_path: Path) -> None:
    write(tmp_path, "mod.py", "class CustomerOrder:\n    pass\n")
    proc = run("--def", "CustomerOrder", "--root", str(tmp_path))
    assert proc.returncode == 0
    assert any(":def:" in ln for ln in proc.stdout.splitlines())


def test_def_no_match_is_empty_and_succeeds(tmp_path: Path) -> None:
    write(tmp_path, "mod.py", "def other():\n    pass\n")
    proc = run("--def", "missing", "--root", str(tmp_path))
    assert proc.returncode == 0
    assert proc.stdout.strip() == ""


# ---------- --uses ----------


def test_uses_excludes_the_definition_line(tmp_path: Path) -> None:
    write(tmp_path, "def_site.py", "def widget():\n    return 1\n")
    write(tmp_path, "call_site.py", "from def_site import widget\nwidget()\n")
    proc = run("--uses", "widget", "--root", str(tmp_path))
    assert proc.returncode == 0
    uses = [ln for ln in proc.stdout.splitlines() if ln]
    # The `def widget` line must NOT appear; only the two references do.
    assert all(":use:" in ln for ln in uses)
    assert not any("def_site.py:1:" in ln for ln in uses)
    assert any("call_site.py" in ln for ln in uses)


# ---------- --in ----------


def test_in_lists_symbols_defined_in_file(tmp_path: Path) -> None:
    target = write(
        tmp_path, "lib.py", "def alpha():\n    pass\n\n\ndef beta():\n    pass\n"
    )
    write(tmp_path, "user.py", "from lib import alpha\nalpha()\n")
    proc = run("--in", str(target), "--root", str(tmp_path))
    assert proc.returncode == 0
    out = proc.stdout
    assert ":def:" in out
    assert "alpha" in out and "beta" in out
    # alpha is used externally -> a use:alpha row should appear.
    assert "use:alpha" in out


# ---------- language filter ----------


def test_lang_filter_restricts_extension(tmp_path: Path) -> None:
    write(tmp_path, "a.py", "def shared():\n    pass\n")
    write(tmp_path, "b.go", "func shared() {}\n")
    proc = run("--def", "shared", "--lang", ".py", "--root", str(tmp_path))
    assert proc.returncode == 0
    lines = [ln for ln in proc.stdout.splitlines() if ln]
    assert lines and all(".py:" in ln for ln in lines)
    assert not any(".go:" in ln for ln in lines)


# ---------- errors ----------


def test_missing_root_exits_1(tmp_path: Path) -> None:
    proc = run("--def", "x", "--root", str(tmp_path / "does_not_exist"))
    assert proc.returncode == 1
    assert "not a directory" in proc.stderr


def test_requires_a_mode(tmp_path: Path) -> None:
    proc = run("--root", str(tmp_path))
    # argparse mutually-exclusive required group -> exit 2.
    assert proc.returncode == 2


def test_skip_dirs_are_not_searched(tmp_path: Path) -> None:
    write(tmp_path, "real.py", "def widget():\n    pass\n")
    write(tmp_path, "node_modules/pkg.py", "def widget():\n    pass\n")
    proc = run("--def", "widget", "--root", str(tmp_path))
    assert proc.returncode == 0
    assert not any("node_modules" in ln for ln in proc.stdout.splitlines())


def test_def_finds_powershell_function(tmp_path: Path) -> None:
    # Verb-Noun names contain a hyphen; the pattern must still anchor on the
    # function keyword and the whole name, not the first \w+ run.
    write(tmp_path, "mod.ps1", "function Get-Widget {\n    param()\n}\n")
    proc = run("--def", "Get-Widget", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    lines = [ln for ln in proc.stdout.splitlines() if ln]
    assert len(lines) == 1
    file, lineno, kind, _context = lines[0].split(":", 3)
    assert file.endswith("mod.ps1")
    assert lineno == "1"
    assert kind == "def"


def test_uses_finds_powershell_call_sites(tmp_path: Path) -> None:
    write(tmp_path, "mod.psm1", "function Get-Widget {\n    param()\n}\n")
    write(tmp_path, "caller.ps1", "$w = Get-Widget\n")
    proc = run("--uses", "Get-Widget", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    out = proc.stdout
    assert "caller.ps1" in out


def test_in_reports_full_powershell_names(tmp_path: Path) -> None:
    # --in discovers definitions with a capturing group; the capture must not
    # stop at the hyphen (New-Wrapper reported as "New" made two symbols
    # sharing a verb indistinguishable).
    write(
        tmp_path,
        "mod.ps1",
        "function New-Wrapper {\n    param()\n}\nenum WidgetKind {\n    A\n}\n",
    )
    write(tmp_path, "caller.ps1", "New-Wrapper\n")
    proc = run("--in", str(tmp_path / "mod.ps1"), "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert "New-Wrapper" in proc.stdout
    assert "WidgetKind" in proc.stdout
    # Every line is `<file>:<line>:<kind>:<context>` and <file> is the absolute
    # path, so strip that prefix first instead of splitting the line blindly:
    # both the kind (`use:<owner>`) and the context can contain colons.
    prefix = f"{tmp_path}{os.sep}"
    rows: list[tuple[str, str]] = []
    for ln in proc.stdout.splitlines():
        if not ln:
            continue
        assert ln.startswith(prefix), ln
        name, _lineno, kind_and_context = ln[len(prefix) :].split(":", 2)
        rows.append((name, kind_and_context))
    assert [n for n, kc in rows if kc.startswith("def:")] == ["mod.ps1", "mod.ps1"]
    # The external call site is attributed to the whole Verb-Noun name, never
    # to the verb alone: `use:New` is the regression this test exists for.
    owners = [kc.split(":", 2)[1] for _n, kc in rows if kc.startswith("use:")]
    assert owners == ["New-Wrapper"], proc.stdout


# ---------- rg output parsing ----------


def test_rg_line_parser_reads_the_null_separated_format() -> None:
    # rg is run with --null, so the path ends at the NUL byte and the only
    # colon that matters is the one after the line number. Parsed directly:
    # the Windows case cannot be produced on the ubuntu CI runners.
    assert parse_rg_line("/repo/mod.py\x0012:def widget():") == (
        "/repo/mod.py",
        12,
        "def widget():",
    )
    # a colon inside the path is no longer ambiguous...
    assert parse_rg_line("/repo/a:b.py\x0012:widget()") == (
        "/repo/a:b.py",
        12,
        "widget()",
    )
    # ...neither is a Windows drive letter, which needs no special case now
    assert parse_rg_line("C:\\repo\\mod.py\x0012:def widget():") == (
        "C:\\repo\\mod.py",
        12,
        "def widget():",
    )
    # and the content keeps every colon it had
    assert parse_rg_line("/repo/mod.py\x007:d = {'a': 1, 'b': 2}") == (
        "/repo/mod.py",
        7,
        "d = {'a': 1, 'b': 2}",
    )


def test_rg_line_parser_rejects_junk() -> None:
    assert parse_rg_line("no separators here") is None
    assert parse_rg_line("/repo/mod.py:12:no null byte") is None
    assert parse_rg_line("/repo/mod.py\x00twelve:x") is None
    assert parse_rg_line("/repo/mod.py\x0012 no colon") is None


def test_rg_stream_parser_splits_records_on_the_record_newline_only() -> None:
    # Only the newline that ends a record ends a record. str.splitlines(),
    # which this replaced, also breaks on form feed, vertical tab, NEL, U+2028
    # and U+2029, and it split a path containing a newline in half.
    stream = (
        "/repo/a.txt\x001:head \x0c tail\n"
        "/repo/b\nc.txt\x002:x\n"
        "/repo/d.txt\x003:sep \u2028 here\n"
        "/repo/e.txt\x004:vertical \x0b tab\n"
    )
    assert parse_rg_output(stream) == [
        ("/repo/a.txt", 1, "head \x0c tail"),
        ("/repo/b\nc.txt", 2, "x"),
        ("/repo/d.txt", 3, "sep \u2028 here"),
        ("/repo/e.txt", 4, "vertical \x0b tab"),
    ]
    # a stream with no trailing newline still yields its last record
    assert parse_rg_output("/repo/f.txt\x005:last") == [("/repo/f.txt", 5, "last")]
    assert parse_rg_output("") == []


# ---------- the two backends must see the same tree ----------


def test_the_ripgrep_backend_is_really_invoked(
    tmp_path: Path, tmp_path_factory: pytest.TempPathFactory
) -> None:
    # The `backends` fixture asserts rg is reachable on the ambient PATH; this
    # observes the call itself, which is the only direct evidence that the
    # first leg of every parity test runs ripgrep and not the fallback. A stub
    # `rg` records its argv, so the flags that keep the two backends in
    # agreement are pinned on the real command line too.
    if sys.platform == "win32":
        pytest.skip("the stub rg is a /bin/sh script")
    bin_dir = tmp_path_factory.mktemp("stub-rg-bin")
    record = bin_dir / "argv.txt"
    stub = bin_dir / "rg"
    stub.write_text(
        f'#!/bin/sh\nprintf "%s\\n" "$@" > "{record}"\nexit 1\n', encoding="utf-8"
    )
    stub.chmod(0o755)
    env = dict(os.environ)
    env["PATH"] = str(bin_dir)
    write(tmp_path, "mod.py", "def widget():\n    return 1\n")

    proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
    assert proc.returncode == 0, proc.stderr
    assert record.is_file(), "rg was on PATH but the script never ran it"
    argv = record.read_text(encoding="utf-8").splitlines()
    assert "--no-config" in argv, argv
    assert "--null" in argv, argv
    assert "--text" in argv, argv
    assert "--no-ignore" in argv, argv
    assert "--hidden" in argv, argv
    assert "!.git" in argv, argv


def test_root_under_a_skipped_directory_is_still_searched(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # SKIP_DIRS applies BELOW the root; a checkout that happens to live under a
    # directory called build/ (or dist/, target/, out/) is not itself skipped.
    root = tmp_path / "build" / "proj"
    write(root, "mod.py", "def widget():\n    return 1\n")
    for env in backends:
        proc = run("--def", "widget", "--root", str(root), env=env)
        assert proc.returncode == 0, proc.stderr
        lines = [ln for ln in proc.stdout.splitlines() if ln]
        assert len(lines) == 1, proc.stdout
        assert lines[0].endswith("mod.py:1:def:def widget():"), proc.stdout


def test_hidden_and_ignored_files_are_searched_by_both_backends(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # The walk fallback knows nothing about .gitignore or dotfiles, so rg is
    # given --no-ignore/--hidden to match it. Pinned because dropping either
    # flag makes the output depend on whether rg is installed.
    (tmp_path / ".git").mkdir()  # makes rg honour .gitignore at all
    write(tmp_path, ".gitignore", "ignored.py\n")
    write(tmp_path, "ignored.py", "widget()\n")
    write(tmp_path, ".github/workflows/ci.yml", "run: widget()\n")
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert "ignored.py" in proc.stdout, proc.stdout
        assert "ci.yml" in proc.stdout, proc.stdout


def test_binary_files_are_searched_as_text_by_both_backends(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # One policy on both sides: every regular file is searched as text (rg
    # gets --text, the walker decodes with errors="replace"). Letting each
    # backend detect binaries instead could only ever approximate the other -
    # rg decides per read buffer and can still print matches from before the
    # NUL it stops at - so the files hardest to reason about were exactly the
    # ones where the two disagreed. Both blobs below must be reported, with
    # identical output.
    (tmp_path / "early.bin").write_bytes(b"\x00\x00widget()\n")
    (tmp_path / "late.bin").write_bytes(b"x" * 20000 + b"\nwidget()\n" + b"\x00")
    write(tmp_path, "real.py", "widget()\n")
    outputs = []
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert "early.bin" in proc.stdout, proc.stdout
        assert "late.bin" in proc.stdout, proc.stdout
        assert "real.py" in proc.stdout, proc.stdout
        outputs.append(sorted(proc.stdout.splitlines()))
    assert outputs[0] == outputs[1], outputs


def test_a_very_long_line_is_clamped_identically_by_both_backends(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # Every regular file is searched as text, so a hit inside a minified
    # bundle or a blob would otherwise print a "line" megabytes long into the
    # caller's output. The clamp sits where the result line is formatted, so
    # both backends produce exactly the same clamped row.
    long_line = "x" * 2000 + " widget() " + "y" * 3000
    write(tmp_path, "bundle.min.js", long_line + "\n")
    write(tmp_path, "short.py", "widget()\n")
    expected = long_line[:300] + f" [...+{len(long_line) - 300} chars]"

    outputs = []
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        contexts = {}
        for ln in proc.stdout.splitlines():
            file, _lineno, _kind, context = ln.split(":", 3)
            contexts[Path(file).name] = context
        assert contexts["bundle.min.js"] == expected, contexts["bundle.min.js"][:120]
        # a short line keeps every character and gains no marker
        assert contexts["short.py"] == "widget()", contexts["short.py"]
        outputs.append(sorted(proc.stdout.splitlines()))
    assert outputs[0] == outputs[1], outputs


def test_undecodable_bytes_do_not_forge_a_match(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # ripgrep searches raw bytes, so `widget` does not occur in
    # b"wid\xffget()". Decoding with errors="ignore" deleted the 0xff and
    # made the fallback report a hit rg never sees; errors="replace" leaves a
    # U+FFFD in the way, which is not a word character, so the boundary
    # behaves the way rg's does.
    (tmp_path / "bad.txt").write_bytes(b"wid\xffget()\n")
    write(tmp_path, "real.py", "widget()\n")
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert "bad.txt" not in proc.stdout, proc.stdout
        assert "real.py" in proc.stdout, proc.stdout


def test_a_ripgrep_config_cannot_change_what_is_searched(
    tmp_path: Path,
    tmp_path_factory: pytest.TempPathFactory,
    backends: list[dict[str, str] | None],
) -> None:
    # RIPGREP_CONFIG_PATH would otherwise hand the rg backend --follow and
    # extra globs, putting files the walker never sees (here: a symlink out of
    # the tree) into the rg results on that machine alone. --no-config is in
    # the shared flag list; this pins the whole result against the walker with
    # such a config in place.
    config = tmp_path_factory.mktemp("rg-config") / "rgrc"
    config.write_text("--follow\n--text\n", encoding="utf-8")
    secret = tmp_path_factory.mktemp("outside") / "credentials"
    secret.write_text("widget = 'SENTINEL-SECRET'\n", encoding="utf-8")
    root = tmp_path / "repo"
    write(root, "real.py", "widget()\n")
    (root / "blob.bin").write_bytes(b"\x00\x00widget()\n")
    symlink_or_skip(root / "creds", secret)

    outputs = []
    for env in backends:
        full = dict(os.environ if env is None else env)
        full["RIPGREP_CONFIG_PATH"] = str(config)
        proc = run("--uses", "widget", "--root", str(root), env=full)
        assert proc.returncode == 0, proc.stderr
        assert "SENTINEL-SECRET" not in proc.stdout, proc.stdout
        assert "real.py" in proc.stdout, proc.stdout
        outputs.append(sorted(proc.stdout.splitlines()))
    assert outputs[0] == outputs[1], outputs


def test_a_colon_in_a_path_does_not_lose_the_hit(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # The rg backend used to split its output on colons, so a hit in `a:b.py`
    # was dropped there and reported by the walk fallback.
    try:
        write(tmp_path, "a:b.py", "widget()\n")
    except OSError as exc:  # Windows forbids ':' in a file name
        pytest.skip(f"cannot create a path containing a colon: {exc}")
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert "a:b.py" in proc.stdout, proc.stdout


def test_a_file_named_like_a_skipped_directory_is_not_searched(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # A linked git worktree has a regular `.git` FILE holding a gitdir
    # pointer. rg's `-g !.git` excludes files as well as directories; the
    # walker pruned directory names only, so it alone searched this one.
    write(tmp_path, "worktree/.git", "gitdir: /elsewhere/.git/worktrees/x\nwidget()\n")
    write(tmp_path, "real.py", "widget()\n")
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert ".git" not in proc.stdout, proc.stdout
        assert "real.py" in proc.stdout, proc.stdout


def test_control_characters_in_a_line_do_not_truncate_the_record(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # A form feed, a vertical tab or U+2028 inside a matching line used to cut
    # rg's record short (the walker never split on them), so the two backends
    # printed different context for the same hit.
    write(tmp_path, "odd.txt", "head \x0c mid \u2028 widget() \x0b tail\n")
    write(tmp_path, "real.py", "widget()\n")
    outputs = []
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        # split on the record separator only: the content holds characters
        # that str.splitlines() would break on here too.
        rows = [ln for ln in proc.stdout.split("\n") if ln]
        assert len(rows) == 2, rows
        assert any("\x0c" in ln and "\u2028" in ln and "\x0b" in ln for ln in rows), (
            rows
        )
        outputs.append(sorted(rows))
    assert outputs[0] == outputs[1], outputs


def test_a_newline_in_a_file_name_does_not_lose_the_hit(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # rg terminates the path with NUL, so a newline inside the NAME is data,
    # not a record boundary - but only if the stream is parsed as records.
    try:
        write(tmp_path, "new\nline.txt", "widget()\n")
    except OSError as exc:  # a filesystem that refuses the name
        pytest.skip(f"cannot create a file name containing a newline: {exc}")
    write(tmp_path, "real.py", "widget()\n")
    outputs = []
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert "new\nline.txt" in proc.stdout, proc.stdout
        outputs.append(sorted(proc.stdout.split("\n")))
    assert outputs[0] == outputs[1], outputs


def test_the_git_directory_is_never_searched(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # .git holds the whole history (and credentials in .git/config); it is in
    # SKIP_DIRS, and --no-ignore/--hidden must not bring it back.
    write(tmp_path, ".git/config", "widget()\n")
    write(tmp_path, "real.py", "widget()\n")
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert ".git" not in proc.stdout, proc.stdout
        assert "real.py" in proc.stdout, proc.stdout


def test_symlinked_files_are_not_followed(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # rg does not follow links without -L; the fallback walk must not either,
    # or a link committed in a repo turns a search into a read of a file
    # outside it, printed verbatim.
    outside = tmp_path / "outside"
    outside.mkdir()
    secret = outside / "credentials"
    secret.write_text("widget = 'SENTINEL-SECRET'\n", encoding="utf-8")
    root = tmp_path / "repo"
    write(root, "real.py", "widget()\n")
    symlink_or_skip(root / "creds", secret)
    for env in backends:
        proc = run("--uses", "widget", "--root", str(root), env=env)
        assert proc.returncode == 0, proc.stderr
        assert "SENTINEL-SECRET" not in proc.stdout, proc.stdout
        assert "creds" not in proc.stdout, proc.stdout
        assert "real.py" in proc.stdout, proc.stdout
