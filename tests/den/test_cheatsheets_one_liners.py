"""cheatsheets/shell/one-liners.md: the commands do what their comments say.

The lint tests read the sheet's ```sh blocks and always run. The behavior tests
run the sheet's own command lines, verbatim, in a scratch directory with a
scratch HOME; they need fd, rg, sd and git and are skipped where those are
missing (or on native Windows, where the lines are not POSIX sh).
"""

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

SHEET = Path(__file__).resolve().parents[2] / "cheatsheets" / "shell" / "one-liners.md"
OLD = 1_577_836_800  # 2020-01-01, well outside "changed within 1d"


def _sh_lines() -> list[str]:
    text = SHEET.read_text(encoding="utf-8")
    blocks = re.findall(r"^```sh\n(.*?)^```", text, flags=re.MULTILINE | re.DOTALL)
    return [line for block in blocks for line in block.splitlines() if line.strip()]


def _split(line: str) -> tuple[str, str]:
    """Split a sheet line into (command, comment)."""
    match = re.match(r"^(.*?)\s{2,}#\s(.*)$", line)
    return (match.group(1).strip(), match.group(2)) if match else (line.strip(), "")


def _command(comment: str) -> str:
    """The command whose trailing comment starts with ``comment``."""
    found = [cmd for cmd, note in map(_split, _sh_lines()) if note.startswith(comment)]
    assert len(found) == 1, (comment, found)
    return found[0]


def _command_after(heading: str) -> str:
    """The command on the line after a ``# heading`` comment line."""
    lines = _sh_lines()
    index = lines.index(f"# {heading}")
    return lines[index + 1].strip()


# --- lint: shapes that are known to be wrong ---------------------------------


def test_every_xargs_pipe_is_nul_separated():
    # A plain `| xargs` splits "my file.ts" into "my" and "file.ts": sd then
    # fails on those names and the refactor is half applied.
    for line in _sh_lines():
        command, _ = _split(line)
        if "| xargs" in command:
            assert "xargs -0" in command, line
            producer = command.split("|")[0]
            assert re.search(r"(^|\s)-(l0|0)\b", producer), line


def test_sd_is_only_handed_files_that_match():
    # sd rewrites every file it is given (new inode and mtime) even without a
    # match, so fd -x/-X sd over a whole file type touched the entire tree.
    for line in _sh_lines():
        command, _ = _split(line)
        assert not re.search(r"^fd\b.*-[xX] sd\b", command), line
        if " sd " in f" {command} " and "|" in command:
            assert command.startswith("rg -l0"), line


def test_known_wrong_flags_are_gone():
    commands = [_split(line)[0] for line in _sh_lines()]
    joined = "\n".join(commands)
    assert "bat --list" not in joined  # no such flag
    assert "dust -t " not in joined  # -t is --file-types, not a size threshold
    assert "procs -p " not in joined  # -p is --pager
    assert "procs --watch 1" not in joined  # --watch takes no value
    assert "xh --json api" not in joined  # the JSON string became a header name
    assert " -t rs" not in joined  # rg's type is "rust"
    assert not re.search(r"^fd\b.*-x rg\b", joined, flags=re.MULTILINE)
    for command in commands:
        if "unwrap()" in command:
            assert "-F" in command.split(), command  # () is an empty regex group


def test_eza_and_dust_comments_match_the_flags():
    assert "--reverse" not in _command("oldest first")
    assert "-r" not in _command("oldest first").split()
    assert (
        "header" in _split(next(ln for ln in _sh_lines() if "eza -l --git -h" in ln))[1]
    )
    assert (
        "biggest first"
        in _split(next(ln for ln in _sh_lines() if ln.startswith("dust -r")))[1]
    )


def test_delete_recipes_include_gitignored_files():
    assert " -I " in f" {_command('delete all .log files')} "
    assert " -I " in f" {_command('remove all .bak files')} "


def test_delete_recipes_say_that_hidden_files_need_h():
    # fd skips hidden files and directories without -H, so "delete all .log
    # files" left .hidden/app.log in place without saying so.
    for comment in ("delete all .log files", "remove all .bak files"):
        line = next(ln for ln in _sh_lines() if _split(ln)[1].startswith(comment))
        command, note = _split(line)
        assert " -H " in f" {command} " or "-H" in note, line


# --- behavior: the sheet's own lines, run in a scratch tree -------------------


needs_tools = pytest.mark.skipif(
    sys.platform == "win32"
    or any(shutil.which(tool) is None for tool in ("fd", "rg", "sd", "git", "sh")),
    reason="needs fd, rg, sd, git and a POSIX sh",
)


def _run(command: str, cwd: Path) -> subprocess.CompletedProcess[str]:
    home = cwd.parent / "home"
    home.mkdir(exist_ok=True)
    env = {
        "PATH": os.environ["PATH"],
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "LC_ALL": "C.UTF-8",
    }
    return subprocess.run(
        ["sh", "-c", command],
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )


@pytest.fixture
def repo(tmp_path) -> Path:
    root = tmp_path / "repo"
    root.mkdir()
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    return root


@needs_tools
def test_delete_all_log_files_deletes_gitignored_logs(repo):
    # fd skips gitignored files, and logs are gitignored in a typical repo:
    # `fd -e log -x rm` deleted nothing at all.
    (repo / ".gitignore").write_text("*.log\n", encoding="utf-8")
    (repo / "sub").mkdir()
    logs = [repo / "app.log", repo / "build.log", repo / "sub" / "debug.log"]
    for log in logs:
        log.write_text("x\n", encoding="utf-8")
    keep = repo / "notes.txt"
    keep.write_text("x\n", encoding="utf-8")
    result = _run(_command("delete all .log files"), repo)
    assert result.returncode == 0, result.stderr
    assert not any(log.exists() for log in logs)
    assert keep.exists()


@needs_tools
def test_replace_in_matching_files_handles_spaces_and_skips_the_rest(repo):
    spaced = repo / "my file.ts"
    plain = repo / "b.ts"
    other = repo / "c.ts"
    for path, text in ((spaced, "oldFunc()\n"), (plain, "oldFunc()\n"), (other, "x\n")):
        path.write_text(text, encoding="utf-8")
        os.utime(path, (OLD, OLD))
    result = _run(_command("replace in all matching files"), repo)
    assert result.returncode == 0, result.stderr
    assert spaced.read_text(encoding="utf-8") == "newFunc()\n"
    assert plain.read_text(encoding="utf-8") == "newFunc()\n"
    assert other.stat().st_mtime == OLD


@needs_tools
def test_bulk_rename_touches_only_the_files_that_match(repo):
    match = repo / "a.py"
    match.write_text("old_name = 1\n", encoding="utf-8")
    others = [repo / "b.py", repo / "c.py"]
    for path in others:
        path.write_text("x = 1\n", encoding="utf-8")
    for path in (match, *others):
        os.utime(path, (OLD, OLD))
    inodes = [path.stat().st_ino for path in others]
    result = _run(_command("rename across Python files"), repo)
    assert result.returncode == 0, result.stderr
    assert match.read_text(encoding="utf-8") == "new_name = 1\n"
    assert [path.stat().st_mtime for path in others] == [OLD, OLD]
    assert [path.stat().st_ino for path in others] == inodes


@needs_tools
@pytest.mark.parametrize("changed", [2, 1], ids=["two-files", "one-file"])
def test_search_in_files_changed_today_names_the_files(repo, changed):
    # `-x rg PATTERN {}` ran one rg per file, and rg given one path prints no
    # file name: the matches could not be told apart. With -X the same holds
    # when exactly one file changed, so the line needs rg -H as well.
    names = [f"f{index}.txt" for index in range(1, changed + 1)]
    for index, name in enumerate(names, start=1):
        (repo / name).write_text(f"needle {index}\n", encoding="utf-8")
    command = _command_after("Find files changed today and search within them")
    result = _run(command.replace("PATTERN", "needle"), repo)
    assert result.returncode == 0, result.stderr
    assert sorted(result.stdout.splitlines()) == [
        f"./{name}:needle {index}" for index, name in enumerate(names, start=1)
    ]
