"""Tests for den uninstall (den/_uninstall.py)."""

import errno
import os
import shutil
import stat
import sys
from pathlib import Path

import pytest

from den._install import main as install_main
from den._uninstall import _has_block, _Remover, _strip_block
from den._uninstall import main as uninstall_main

# A read-only dir or file is how these tests make a delete or rewrite fail for
# real; Windows ignores the mode bits and root writes through them.
_mode_bits = pytest.mark.skipif(
    sys.platform == "win32" or getattr(os, "geteuid", lambda: 1)() == 0,
    reason="POSIX mode bits do not stop Windows or root",
)


def _hard_link(target: Path, link: Path) -> None:
    """os.link, or skip where this filesystem cannot make a hard link."""
    try:
        os.link(target, link)
    except (OSError, NotImplementedError) as e:
        pytest.skip(f"no hard links here: {e}")


def _install(tmp_path, *extra):
    assert install_main(["skills", "--target", str(tmp_path), *extra]) == 0


def _files(root: Path) -> list[Path]:
    return sorted(p for p in root.rglob("*") if p.is_file())


def test_uninstall_removes_unmodified_keeps_modified(tmp_path, monkeypatch):
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    _install(tmp_path)
    coding = tmp_path / "skills" / "coding" / "SKILL.md"
    review = tmp_path / "skills" / "code-audit" / "SKILL.md"
    coding.write_text(coding.read_text() + "\nMINE\n")  # user edit -> keep
    assert uninstall_main(["skills", "--target", str(tmp_path), "--yes"]) == 0
    assert coding.is_file() and "MINE" in coding.read_text()  # kept
    assert not review.is_file()  # den's, removed


def test_uninstall_removes_a_no_den_cli_install(tmp_path, monkeypatch):
    # `den install skills --no-den-cli` rewrites three SKILL.md files, and
    # nothing on disk records which flavor was installed. Re-deriving only the
    # den-aware bytes made uninstall report den's OWN output as "files you
    # changed": the three SKILL.md files survived while every sibling
    # (examples/, shared/reference/, shared/scripts/) was deleted, leaving a
    # gutted skill whose absolute shared/ paths point at nothing.
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    plain = tmp_path / "plain"
    denfree = tmp_path / "denfree"
    _install(plain)
    _install(denfree, "--no-den-cli")
    coding = denfree / "skills" / "coding" / "SKILL.md"
    plain_coding = plain / "skills" / "coding" / "SKILL.md"
    # the flavors really do differ, else this test would prove nothing
    assert coding.read_bytes() != plain_coding.read_bytes()
    assert uninstall_main(["skills", "--target", str(denfree), "--yes"]) == 0
    assert not (denfree / "skills").exists()


def test_uninstall_prunes_pycache_left_by_running_the_scripts(tmp_path, monkeypatch):
    # The skills tell the model to run den's deployed shared/scripts/*.py by
    # absolute path; they import _common, so CPython writes a __pycache__ next
    # to them. It is den's own residue, but it is not staged, so it used to
    # block the prune and strand the whole skill directory.
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    _install(tmp_path)
    scripts = tmp_path / "skills" / "coding" / "shared" / "scripts"
    assert (scripts / "_common.py").is_file()  # the import that makes the cache
    cache = scripts / "__pycache__"
    cache.mkdir()
    (cache / "_common.cpython-312.pyc").write_bytes(b"\x00fake bytecode")
    assert uninstall_main(["skills", "--target", str(tmp_path), "--yes"]) == 0
    assert not (tmp_path / "skills").exists()


def test_uninstall_keeps_pycache_holding_foreign_files(tmp_path, monkeypatch):
    # only compiled bytecode is treated as den's residue
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    _install(tmp_path)
    cache = tmp_path / "skills" / "coding" / "shared" / "scripts" / "__pycache__"
    cache.mkdir()
    mine = cache / "notes.txt"
    mine.write_text("mine\n")
    assert uninstall_main(["skills", "--target", str(tmp_path), "--yes"]) == 0
    assert mine.is_file()


def test_uninstall_prunes_emptied_dirs(tmp_path, monkeypatch):
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    _install(tmp_path)
    assert (tmp_path / "skills" / "code-audit").is_dir()
    assert uninstall_main(["skills", "--target", str(tmp_path), "--yes"]) == 0
    # every skill was den's -> whole skills tree gone, but the target root stays
    assert not (tmp_path / "skills").exists()
    assert tmp_path.is_dir()


def test_uninstall_dry_run_changes_nothing(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    _install(tmp_path)
    n_before = sum(1 for _ in (tmp_path / "skills").rglob("*"))
    assert uninstall_main(["skills", "--target", str(tmp_path), "--dry-run"]) == 0
    assert "dry-run" in capsys.readouterr().out
    assert sum(1 for _ in (tmp_path / "skills").rglob("*")) == n_before


def test_uninstall_non_tty_refuses_without_yes(tmp_path, monkeypatch):
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    _install(tmp_path)
    skill = tmp_path / "skills" / "coding" / "SKILL.md"
    assert uninstall_main(["skills", "--target", str(tmp_path)]) == 1
    assert skill.is_file()  # nothing deleted


def test_uninstall_interactive_confirm_yes_deletes(tmp_path, monkeypatch):
    monkeypatch.setattr("sys.stdin.isatty", lambda: True)
    _install(tmp_path)
    skill = tmp_path / "skills" / "coding" / "SKILL.md"
    monkeypatch.setattr("den._ui.confirm", lambda *a, **k: True)
    assert uninstall_main(["skills", "--target", str(tmp_path)]) == 0
    assert not skill.is_file()


def test_uninstall_interactive_confirm_no_keeps(tmp_path, monkeypatch):
    monkeypatch.setattr("sys.stdin.isatty", lambda: True)
    _install(tmp_path)
    skill = tmp_path / "skills" / "coding" / "SKILL.md"
    monkeypatch.setattr("den._ui.confirm", lambda *a, **k: False)
    assert uninstall_main(["skills", "--target", str(tmp_path)]) == 0
    assert skill.is_file()  # declined -> kept


def test_uninstall_keeps_a_file_saved_at_the_prompt(tmp_path, monkeypatch, capsys):
    """den compared the bytes only when it listed the plan, so a file edited
    while 'Remove them?' was open was deleted on a 'yes', edit and all, and
    counted as removed. Each file is now read again right before it goes."""
    monkeypatch.setattr("sys.stdin.isatty", lambda: True)
    _install(tmp_path)
    planned = len(_files(tmp_path / "skills"))
    skill = tmp_path / "skills" / "grounding" / "SKILL.md"

    def confirm(*_a, **_k):
        skill.write_text(skill.read_text() + "\nMY EDIT\n")  # saved at the prompt
        return True

    monkeypatch.setattr("den._ui.confirm", confirm)
    rc = uninstall_main(["skills", "--target", str(tmp_path)])
    assert skill.is_file() and skill.read_text().endswith("\nMY EDIT\n")
    assert _files(tmp_path / "skills") == [skill], "every other file is removed"
    assert rc == 1, "a file kept because it changed is not removed as asked"
    out, err = capsys.readouterr()
    assert f"kept {skill}: it changed after den checked it" in err
    assert f"removed {planned - 1} file(s)" in out


def test_uninstall_target_refuses_a_symlink_put_in_at_the_prompt(
    tmp_path, monkeypatch, symlink, capsys
):
    """The symlink rule is checked again right before each delete too: a
    skill dir swapped for a link while the prompt was open is not removed
    through."""
    monkeypatch.setattr("sys.stdin.isatty", lambda: True)
    repo = tmp_path / "repo"
    _install(repo)
    moved = tmp_path / "elsewhere" / "grounding"
    planned = _files(repo / "skills" / "grounding")
    after_move = [moved / p.relative_to(repo / "skills" / "grounding") for p in planned]

    def confirm(*_a, **_k):
        moved.parent.mkdir()
        (repo / "skills" / "grounding").rename(moved)
        symlink(moved, repo / "skills" / "grounding")
        return True

    monkeypatch.setattr("den._ui.confirm", confirm)
    rc = uninstall_main(["skills", "--target", str(repo)])
    assert _files(moved) == after_move, "nothing is removed through the link"
    assert (repo / "skills" / "grounding").is_symlink()
    assert not (repo / "skills" / "coding").exists(), "the rest is removed"
    assert rc == 1
    link = repo.resolve() / "skills" / "grounding"
    err = capsys.readouterr().err
    assert f"refusing to remove anything below {link}: it is a symlink" in err
    assert err.count("refusing to remove") == 1, "the link is named once"


@_mode_bits
def test_uninstall_reports_a_file_it_cannot_remove(tmp_path, monkeypatch, capsys):
    """A failed unlink printed a warning, but the closing line counted the
    whole plan as removed and the run exited 0: 'removed 117 file(s)' with a
    read-only skill dir whose SKILL.md stayed where it was."""
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    _install(tmp_path)
    planned = len(_files(tmp_path / "skills"))
    locked = tmp_path / "skills" / "grounding"
    stuck = [p for p in locked.iterdir() if p.is_file()]
    locked.chmod(0o555)
    try:
        rc = uninstall_main(["skills", "--target", str(tmp_path), "--yes"])
    finally:
        locked.chmod(0o755)
    assert stuck and all(p.is_file() for p in stuck)
    assert rc == 1, "a file den failed to remove is a failed uninstall"
    out, err = capsys.readouterr()
    assert f"removed {planned - len(stuck)} file(s)" in out
    assert f"warning: {locked / 'SKILL.md'}:" in err
    assert f"{len(stuck)} file(s) not removed; see the warnings above" in err


@_mode_bits
def test_uninstall_reports_an_rc_file_it_cannot_unwire(tmp_path, capsys):
    """_strip_block's OSError went straight out of commit when an rc file
    could not be rewritten (a traceback, after the files were gone), and was
    swallowed when a file holding only den's block could not be removed,
    which then still counted as unwired."""
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    block = f"# ===== den =====\n{line}\n"
    readonly = tmp_path / ".bashrc"
    readonly.write_text(f"export A=1\n\n{block}")
    locked = tmp_path / "locked"
    locked.mkdir()
    only_den = locked / ".zshrc"  # only den's block: den made it, so it goes
    only_den.write_text(block)
    fine = tmp_path / ".profile"
    fine.write_text(f"export B=2\n\n{block}")
    remover = _Remover()
    for rc in (readonly, only_den, fine):
        remover.unwire(rc, line)
    readonly.chmod(0o444)
    locked.chmod(0o555)
    try:
        assert remover.commit(assume_yes=True, dry_run=False) == 1
    finally:
        locked.chmod(0o755)
        readonly.chmod(0o644)
    assert _has_block(readonly, line) and _has_block(only_den, line)
    assert fine.read_text() == "export B=2\n", "the others are still unwired"
    out, err = capsys.readouterr()
    assert "unwired 1 rc file(s)" in out
    assert f"warning: {readonly}:" in err and f"warning: {only_den}:" in err
    assert "2 rc file(s) not unwired; see the warnings above" in err


@pytest.mark.parametrize(
    "mine", [b"export A=1\n\n", b""], ids=["with the user's lines", "only den's block"]
)
def test_uninstall_leaves_an_rc_file_with_a_second_hard_link(
    tmp_path, monkeypatch, capsys, mine
):
    """An rc file with a second hard link (a dotfiles repo) was replaced by
    a new file, or removed when den's block was all it held: ~/.bashrc was
    unwired, but the other name kept den's block and was no longer the same
    file. It is now left as it is, block included, and named, and the run
    fails, so the user removes the block by hand."""
    from den._shell import _BASH_LINE, _COMMENT

    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    bashrc = tmp_path / ".bashrc"  # HOME is tmp_path (isolate_user_dirs)
    original = mine + f"{_COMMENT}\n{_BASH_LINE}\n".encode()
    bashrc.write_bytes(original)
    other = tmp_path / "dotfiles" / "bashrc"
    other.parent.mkdir()
    _hard_link(bashrc, other)
    rc = uninstall_main(["shell", "--yes"])
    assert bashrc.read_bytes() == original
    assert bashrc.samefile(other), "still one file under both names"
    assert rc == 1
    out, err = capsys.readouterr()
    assert "unwired 0 rc file(s)" in out
    assert f"warning: {bashrc}: it has 2 hard links" in err
    assert "1 rc file(s) not unwired; see the warnings above" in err


@_mode_bits
@pytest.mark.parametrize("locked", ["file", "dir"])
def test_uninstall_reports_a_file_it_cannot_read(tmp_path, monkeypatch, capsys, locked):
    """A den file that uninstall could not read when it listed the plan was
    passed over without a word: exit 0, the file still there. A skill dir it
    may not search raised PermissionError out of the plan instead (3.12, and
    3.13 under --target). Each file is now named, and the run fails."""
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    _install(tmp_path)
    planned = len(_files(tmp_path / "skills"))
    skill_dir = tmp_path / "skills" / "grounding"
    stuck = [skill_dir / "SKILL.md"] if locked == "file" else _files(skill_dir)
    lock = stuck[0] if locked == "file" else skill_dir
    mode = lock.stat().st_mode
    lock.chmod(0)
    try:
        rc = uninstall_main(["skills", "--target", str(tmp_path), "--yes"])
    finally:
        lock.chmod(mode)
    assert all(p.is_file() for p in stuck)
    assert rc == 1, "a file den could not read is a failed uninstall"
    out, err = capsys.readouterr()
    assert f"removed {planned - len(stuck)} file(s)" in out
    for p in stuck:
        assert f"den uninstall: cannot read {p}:" in err
    assert f"could not read {len(stuck)} file(s) listed above" in err


@_mode_bits
def test_uninstall_reports_an_rc_file_it_cannot_read(tmp_path, monkeypatch, capsys):
    """An rc file holding den's block that uninstall could not read was
    taken for one without a block: 'Nothing to remove.', exit 0, and the
    block stayed. It is now named, and the run fails."""
    from den._shell import _BASH_LINE, _COMMENT

    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    bashrc = tmp_path / ".bashrc"  # HOME is tmp_path (isolate_user_dirs)
    original = f"export A=1\n\n{_COMMENT}\n{_BASH_LINE}\n"
    bashrc.write_text(original)
    bashrc.chmod(0)
    try:
        rc = uninstall_main(["shell", "--yes"])
    finally:
        bashrc.chmod(0o644)
    assert bashrc.read_text() == original
    assert rc == 1
    err = capsys.readouterr().err
    assert f"den uninstall: cannot read {bashrc}:" in err
    assert "could not read 1 file(s) listed above" in err


def test_uninstall_parent_only_with_flag(tmp_path, monkeypatch):
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    _install(tmp_path, "--with-parent")
    agents = tmp_path / "AGENTS.md"
    assert agents.is_file()
    # without --with-parent the parent prompt is left in place
    uninstall_main(["skills", "--target", str(tmp_path), "--yes"])
    assert agents.is_file()
    # with --with-parent it is removed (it is unchanged den content)
    _install(tmp_path, "--with-parent")
    uninstall_main(["skills", "--target", str(tmp_path), "--with-parent", "--yes"])
    assert not agents.is_file()


def test_uninstall_with_parent_keeps_an_edited_parent(tmp_path, monkeypatch, capsys):
    # both profiles are staged now: a parent matching neither is still kept
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    _install(tmp_path, "--with-parent")
    agents = tmp_path / "AGENTS.md"
    agents.write_text(agents.read_text() + "\nMY RULE\n")
    rc = uninstall_main(["skills", "--target", str(tmp_path), "--with-parent", "--yes"])
    assert rc == 0
    assert agents.read_text().endswith("\nMY RULE\n")
    assert not (tmp_path / "CLAUDE.md").exists()
    assert "Keeping files you changed" in capsys.readouterr().out


@_mode_bits
def test_uninstall_with_parent_refuses_a_linked_unreadable_parent(
    tmp_path, monkeypatch, symlink, capsys
):
    """--with-parent read the destination parent while staging, before the
    symlink rule ran, so an AGENTS.md linked to a file den may not read
    raised PermissionError out of uninstall. The link is now refused like
    any other below a --target, without being read."""
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    repo = tmp_path / "repo"
    _install(repo, "--with-parent")
    secret = tmp_path / "secret.md"
    secret.write_text("not den's\n")
    (repo / "AGENTS.md").unlink()
    symlink(secret, repo / "AGENTS.md")
    secret.chmod(0)
    try:
        rc = uninstall_main(["skills", "--target", str(repo), "--with-parent", "--yes"])
    finally:
        secret.chmod(0o644)
    assert (repo / "AGENTS.md").is_symlink()
    assert secret.read_text() == "not den's\n"
    assert not (repo / "skills").exists() and not (repo / "CLAUDE.md").exists()
    assert rc == 1
    err = capsys.readouterr().err
    assert f"refusing to remove {repo.resolve() / 'AGENTS.md'}: it is a symlink" in err


@_mode_bits
def test_uninstall_with_parent_reports_a_linked_unreadable_parent_in_a_tool_dir(
    tmp_path, monkeypatch, symlink, capsys
):
    """In a tool dir, which follows links, the same parent is read in the
    plan, where a file den cannot read is named and fails the run; it no
    longer raises out of the staging."""
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    assert install_main(["skills", "--tool", "claude", "--with-parent"]) == 0
    parent = tmp_path / ".claude" / "CLAUDE.md"  # HOME is tmp_path
    secret = tmp_path / "secret.md"
    secret.write_text("not den's\n")
    parent.unlink()
    symlink(secret, parent)
    secret.chmod(0)
    try:
        rc = uninstall_main(["skills", "--tool", "claude", "--with-parent", "--yes"])
    finally:
        secret.chmod(0o644)
    assert parent.is_symlink() and secret.read_text() == "not den's\n"
    assert not (tmp_path / ".claude" / "skills").exists()
    assert rc == 1
    assert f"den uninstall: cannot read {parent}:" in capsys.readouterr().err


# ---- --target workspaces are never removed through a symlink (as on install) ----


def test_uninstall_target_never_removes_through_a_symlinked_skills_dir(
    tmp_path, monkeypatch, symlink, capsys
):
    """A checkout shipping skills -> another den install: uninstall --target
    read that install through the link, found den's bytes, deleted every file
    and reported them as removed, with exit 0."""
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    outside = tmp_path / "outside-install"
    _install(outside)
    before = _files(outside / "skills")
    repo = tmp_path / "repo"
    repo.mkdir()
    symlink(outside / "skills", repo / "skills")

    rc = uninstall_main(["skills", "--target", str(repo), "--yes"])
    assert _files(outside / "skills") == before, "the other install is untouched"
    assert (repo / "skills").is_symlink(), "and the link is left alone"
    assert rc == 1, "a refused path is a failed uninstall"
    refusal = (
        f"den uninstall: refusing to remove anything below {repo.resolve() / 'skills'}"
        ": it is a symlink"
    )
    err = capsys.readouterr().err
    assert refusal in err
    assert err.count("refusing to remove") == 1, "named once, not once per file"
    # the preview names the same refusal and fails the same way
    assert uninstall_main(["skills", "--target", str(repo), "--dry-run"]) == 1
    assert refusal in capsys.readouterr().err


@pytest.mark.parametrize("behind", ["nothing", "an empty dir"])
def test_uninstall_target_names_a_skills_link_with_nothing_behind_it(
    tmp_path, monkeypatch, symlink, capsys, behind
):
    """A skills/ link that led nowhere, or to an empty dir, was passed over
    without a word and the run exited 0, although the README says a path
    below the target that reaches a symlink is refused and reported. The
    link is now named, and the run fails."""
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    repo = tmp_path / "repo"
    repo.mkdir()
    there = tmp_path / "there"
    if behind == "an empty dir":
        there.mkdir()
    symlink(there, repo / "skills")
    rc = uninstall_main(["skills", "--target", str(repo), "--yes"])
    assert (repo / "skills").is_symlink()
    assert rc == 1
    link = repo.resolve() / "skills"
    err = capsys.readouterr().err
    assert f"den uninstall: refusing to remove anything below {link}" in err
    assert err.count("refusing to remove") == 1


def test_uninstall_target_names_a_dangling_skill_dir_link_once(
    tmp_path, monkeypatch, symlink, capsys
):
    """The same for one skill's dir, linked to nothing: the other skills are
    removed, the link is named once (not once per file den would have looked
    for below it), and the run fails."""
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    repo = tmp_path / "repo"
    _install(repo)
    shutil.rmtree(repo / "skills" / "grounding")
    symlink(tmp_path / "gone", repo / "skills" / "grounding")
    rc = uninstall_main(["skills", "--target", str(repo), "--yes"])
    assert (repo / "skills" / "grounding").is_symlink()
    assert _files(repo / "skills") == [], "every other skill is removed"
    assert rc == 1
    link = repo.resolve() / "skills" / "grounding"
    err = capsys.readouterr().err
    assert f"den uninstall: refusing to remove anything below {link}" in err
    assert err.count("refusing to remove") == 1


def test_uninstall_target_never_removes_a_symlinked_or_dangling_parent(
    tmp_path, monkeypatch, symlink, capsys
):
    """AGENTS.md -> a den-identical parent elsewhere was unlinked as den's
    own file, and a dangling CLAUDE.md went unmentioned; both are links the
    checkout carries, so both are refused and named, and the run fails."""
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    outside = tmp_path / "outside-install"
    _install(outside, "--with-parent")
    repo = tmp_path / "repo"
    _install(repo, "--with-parent")
    (repo / "AGENTS.md").unlink()
    symlink(outside / "AGENTS.md", repo / "AGENTS.md")
    (repo / "CLAUDE.md").unlink()
    symlink(tmp_path / "nowhere.md", repo / "CLAUDE.md")

    rc = uninstall_main(["skills", "--target", str(repo), "--with-parent", "--yes"])
    assert (repo / "AGENTS.md").is_symlink() and (outside / "AGENTS.md").is_file()
    assert (repo / "CLAUDE.md").is_symlink()
    assert not (tmp_path / "nowhere.md").exists()
    assert not (repo / "skills").exists(), "everything else is still removed"
    assert rc == 1
    err = capsys.readouterr().err
    for name in ("AGENTS.md", "CLAUDE.md"):
        assert f"refusing to remove {repo.resolve() / name}: it is a symlink" in err


def test_uninstall_refusal_fails_the_run_after_a_no(
    tmp_path, monkeypatch, symlink, capsys
):
    """Answering 'no' at the prompt is the user's choice, but the refused
    path is not: the run still exits 1, and nothing is removed."""
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    repo = tmp_path / "repo"
    _install(repo, "--with-parent")
    (repo / "AGENTS.md").unlink()
    symlink(tmp_path / "nowhere.md", repo / "AGENTS.md")
    before = _files(repo)
    assert before, "there is something to remove, so the prompt is reached"
    monkeypatch.setattr("sys.stdin.isatty", lambda: True)
    monkeypatch.setattr("den._ui.confirm", lambda *a, **k: False)
    rc = uninstall_main(["skills", "--target", str(repo), "--with-parent"])
    assert _files(repo) == before, "nothing is removed after a 'no'"
    assert rc == 1
    out, err = capsys.readouterr()
    assert "aborted; nothing removed." in out
    assert f"refusing to remove {repo.resolve() / 'AGENTS.md'}: it is a symlink" in err


def test_uninstall_target_through_a_symlinked_root_is_the_users_choice(
    tmp_path, monkeypatch, symlink
):
    """Only links BELOW the target are the checkout's; a target reached
    through a link of its own (~/work -> /data/work) is uninstalled as usual."""
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    real = tmp_path / "data" / "repo"
    _install(real)
    symlink(real, tmp_path / "repo")
    assert uninstall_main(["skills", "--target", str(tmp_path / "repo"), "--yes"]) == 0
    assert not (real / "skills").exists()


def test_uninstall_tool_dir_still_follows_a_dotfiles_symlink(
    tmp_path, monkeypatch, symlink
):
    """~/.claude symlinked into a dotfiles repo is the user's own arrangement:
    the default tool dirs are not confined, on uninstall as on install."""
    home = tmp_path / "home"
    home.mkdir()
    dotfiles = tmp_path / "dotfiles" / "claude"
    dotfiles.mkdir(parents=True)
    symlink(dotfiles, home / ".claude")
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("USERPROFILE", str(home))
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    assert install_main(["skills", "--tool", "claude"]) == 0
    assert (dotfiles / "skills" / "coding" / "SKILL.md").is_file()
    assert uninstall_main(["skills", "--tool", "claude", "--yes"]) == 0
    assert not (dotfiles / "skills").exists()


def test_uninstall_unknown_target(capsys):
    assert uninstall_main(["bogus"]) == 2


def test_uninstall_unknown_tool(capsys):
    assert uninstall_main(["skills", "--tool", "notatool"]) == 2


# --------------------------------------------------------------------------- #
# rc block strip (used by shell uninstall)
# --------------------------------------------------------------------------- #


def test_strip_block_removes_marker_and_line(tmp_path):
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    rc = tmp_path / ".bashrc"
    rc.write_text(f"export FOO=1\n\n# ===== den =====\n{line}\n")
    assert _has_block(rc, line)
    _strip_block(rc, line)
    assert rc.read_text() == "export FOO=1\n"
    assert not _has_block(rc, line)


def test_strip_block_says_whether_it_removed_a_block(tmp_path):
    # commit counts 'unwired' from this, and an rc file deleted while the
    # prompt was open is nothing left to do, not a crash
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    rc = tmp_path / ".bashrc"
    rc.write_text(f"export FOO=1\n\n# ===== den =====\n{line}\n")
    assert _strip_block(rc, line) is True
    assert _strip_block(rc, line) is False, "no block left to remove"
    assert rc.read_text() == "export FOO=1\n"
    assert _strip_block(tmp_path / "gone", line) is False


def test_strip_block_keeps_the_rc_file_when_the_write_fails_part_way(tmp_path):
    """The rc file was truncated and then written, so a write that failed
    part-way (a full disk, an I/O error) left the user's file empty or cut
    short. A file-size limit makes the write fail for real after its first
    KiB, whichever way the bytes are written: the file must survive as it
    was, and no temporary copy may be left beside it."""
    resource = pytest.importorskip("resource")
    import signal

    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    rc = tmp_path / ".bashrc"
    original = b"export A=1\n" * 400 + f"\n# ===== den =====\n{line}\n".encode()
    rc.write_bytes(original)
    soft, hard = resource.getrlimit(resource.RLIMIT_FSIZE)
    previous = signal.signal(signal.SIGXFSZ, signal.SIG_IGN)  # EFBIG, not a kill
    resource.setrlimit(resource.RLIMIT_FSIZE, (1024, hard))
    try:
        with pytest.raises(OSError, match="too large"):
            _strip_block(rc, line)
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE, (soft, hard))
        signal.signal(signal.SIGXFSZ, previous)
    assert rc.read_bytes() == original, "the rc file is as it was"
    assert sorted(tmp_path.iterdir()) == [rc], "no temporary copy is left"


def test_strip_block_leaves_no_copy_when_the_replace_fails(tmp_path, monkeypatch):
    # the same promise when the rename itself fails (any platform)
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    rc = tmp_path / ".bashrc"
    original = f"export A=1\n\n# ===== den =====\n{line}\n".encode()
    rc.write_bytes(original)

    def fail(*_a):
        raise OSError(errno.EIO, "simulated I/O error")

    monkeypatch.setattr(Path, "replace", fail)
    with pytest.raises(OSError, match="simulated"):
        _strip_block(rc, line)
    monkeypatch.undo()
    assert rc.read_bytes() == original
    assert sorted(tmp_path.iterdir()) == [rc]


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX permission bits")
def test_strip_block_keeps_the_rc_files_mode(tmp_path):
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    rc = tmp_path / ".bashrc"
    rc.write_text(f"export A=1\n\n# ===== den =====\n{line}\n")
    rc.chmod(0o640)
    assert _strip_block(rc, line) is True
    assert rc.read_text() == "export A=1\n"
    assert stat.S_IMODE(rc.stat().st_mode) == 0o640


def test_strip_block_rewrites_the_target_of_a_symlinked_rc_file(tmp_path, symlink):
    """A ~/.bashrc linked into a dotfiles repo keeps its link: the new
    content goes to the target, and the link is not replaced by a file."""
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    target = tmp_path / "dotfiles" / "bashrc"
    target.parent.mkdir()
    target.write_text(f"export A=1\n\n# ===== den =====\n{line}\n")
    rc = tmp_path / ".bashrc"
    symlink(target, rc)
    assert _strip_block(rc, line) is True
    assert rc.is_symlink() and rc.resolve() == target.resolve()
    assert target.read_text() == "export A=1\n"


def test_strip_block_empties_a_linked_rc_file_that_held_only_the_block(
    tmp_path, symlink
):
    """A file holding only den's block is one den created, so it is removed;
    but a link is the user's arrangement, and removing it left the target
    with den's block in the dotfiles repo. The target is emptied instead."""
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    target = tmp_path / "dotfiles" / "zshrc"
    target.parent.mkdir()
    target.write_text(f"# ===== den =====\n{line}\n")
    rc = tmp_path / ".zshrc"
    symlink(target, rc)
    assert _strip_block(rc, line) is True
    assert rc.is_symlink(), "the link stays"
    assert target.read_bytes() == b"", "den's block was all the file held"


def test_strip_block_leaves_a_hard_linked_target_of_a_symlink(tmp_path, symlink):
    # behind a symlink the rule holds for the target the new copy would replace
    line = '[ -f "$HOME/.config/shell/init.zsh" ] && . "$HOME/.config/shell/init.zsh"'
    target = tmp_path / "dotfiles" / "zshrc"
    target.parent.mkdir()
    original = f"export Z=1\n\n# ===== den =====\n{line}\n".encode()
    target.write_bytes(original)
    _hard_link(target, tmp_path / "dotfiles" / "zshrc.orig")
    rc = tmp_path / ".zshrc"
    symlink(target, rc)
    with pytest.raises(OSError, match="it has 2 hard links"):
        _strip_block(rc, line)
    assert rc.is_symlink() and target.read_bytes() == original
    assert target.stat().st_nlink == 2
    assert sorted(target.parent.iterdir()) == [target, target.with_name("zshrc.orig")]


def test_strip_block_keeps_foreign_content(tmp_path):
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    rc = tmp_path / ".bashrc"
    rc.write_text(f"# ===== den =====\n{line}\nalias x=y\n")
    _strip_block(rc, line)
    assert "alias x=y" in rc.read_text()
    assert "den" not in rc.read_text()


def test_has_block_false_when_absent(tmp_path):
    rc = tmp_path / ".bashrc"
    rc.write_text("just my stuff\n")
    assert not _has_block(rc, "anything")
    assert not _has_block(Path(tmp_path / "nope"), "x")  # missing file


def test_has_block_ignores_marker_inside_user_comment(tmp_path):
    rc = tmp_path / ".bashrc"
    rc.write_text("echo hi  # ===== den ===== (just my note)\n")
    # the marker appears only as a substring of a user comment -> not den's block
    assert not _has_block(rc, "anything")


def test_has_block_requires_marker_followed_by_den_line(tmp_path):
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    rc = tmp_path / ".bashrc"
    # standalone marker, but the next line is the user's own, not den's wire line
    rc.write_text("# ===== den =====\nmy own note here\n")
    assert not _has_block(rc, line)


def test_strip_block_leaves_stray_marker_untouched(tmp_path):
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    rc = tmp_path / ".bashrc"
    original = "export FOO=1\n\n# ===== den =====\nmy own note here\n"
    rc.write_text(original)
    _strip_block(rc, line)
    # marker not followed by den's line -> nothing removed (incl. preceding blank)
    assert rc.read_text() == original


def test_strip_block_keeps_whitespace_only_user_content(tmp_path):
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    rc = tmp_path / ".bashrc"
    rc.write_text(f"   \n\n# ===== den =====\n{line}\n")  # user had whitespace lines
    _strip_block(rc, line)
    assert rc.exists()  # not exactly den's created form -> kept
    assert "den" not in rc.read_text()


def test_strip_block_preserves_non_utf8_bytes(tmp_path):
    # A cp1252/latin-1 rc file (old Notepad default): den's block is ASCII, so
    # it is found and stripped, but a lossy decode would silently drop the
    # user's 0xe9 byte while rewriting the whole file.
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    rc = tmp_path / ".bashrc"
    mine = "alias caf='cd ~/Caf\xe9'\n".encode("latin-1")
    rc.write_bytes(mine + f"\n# ===== den =====\n{line}\n".encode())
    assert _has_block(rc, line)
    _strip_block(rc, line)
    assert rc.read_bytes() == mine  # every byte den did not write round-trips


def test_strip_block_preserves_crlf(tmp_path):
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    rc = tmp_path / "profile.ps1"
    rc.write_bytes(f"Set-Foo 1\r\n\r\n# ===== den =====\r\n{line}\r\n".encode())
    _strip_block(rc, line)
    assert rc.read_bytes() == b"Set-Foo 1\r\n"  # CRLF kept, not flipped to LF


def test_strip_block_keeps_mixed_line_endings(tmp_path):
    # A file mixing LF and CRLF (a Windows editor touching a POSIX rc file, a
    # merge): den removes its own block and leaves every other line's ending
    # exactly as it found it. The old flag-and-normalize pass rewrote them all.
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    rc = tmp_path / ".bashrc"
    mine = b"export A=1\nexport B=2\r\nexport C=3\n"
    rc.write_bytes(mine + f"\n# ===== den =====\n{line}\n".encode())
    assert _has_block(rc, line)
    _strip_block(rc, line)
    assert rc.read_bytes() == mine, "every byte outside den's block is untouched"


def test_strip_block_keeps_crlf_block_in_an_lf_file(tmp_path):
    # The block itself carries CRLF while the user's lines are LF; removing it
    # must not drag the user's lines to CRLF.
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    rc = tmp_path / ".bashrc"
    mine = b"export A=1\nexport B=2\n"
    rc.write_bytes(mine + f"\r\n# ===== den =====\r\n{line}\r\n".encode())
    _strip_block(rc, line)
    assert rc.read_bytes() == mine


def test_strip_block_keeps_a_missing_final_newline(tmp_path):
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    rc = tmp_path / ".bashrc"
    rc.write_bytes(f"# ===== den =====\n{line}\nalias x=y".encode())
    _strip_block(rc, line)
    assert rc.read_bytes() == b"alias x=y", "no newline invented at EOF"


def test_utf16_profile_block_is_found_and_stripped(tmp_path):
    """The block den appends to a UTF-16 profile (in UTF-16, see _wire) is
    den's own; uninstall must see it and remove it byte-exactly."""
    from den._shell import _COMMENT, _PWSH_LINE

    for codec, bom in (("utf-16-le", b"\xff\xfe"), ("utf-16-be", b"\xfe\xff")):
        rc = tmp_path / "Microsoft.PowerShell_profile.ps1"
        mine = bom + "Set-Alias g git\r\n".encode(codec)
        rc.write_bytes(mine + f"\r\n{_COMMENT}\r\n{_PWSH_LINE}\r\n".encode(codec))
        assert _has_block(rc, _PWSH_LINE)
        _strip_block(rc, _PWSH_LINE)
        assert rc.read_bytes() == mine
        assert not _has_block(rc, _PWSH_LINE)


def test_undecodable_utf16_profile_is_left_alone(tmp_path):
    from den._shell import _PWSH_LINE

    rc = tmp_path / "Microsoft.PowerShell_profile.ps1"
    broken = b"\xff\xfe" + "x".encode("utf-16-le") + b"\x00"
    rc.write_bytes(broken)
    assert not _has_block(rc, _PWSH_LINE)
    _strip_block(rc, _PWSH_LINE)
    assert rc.read_bytes() == broken


def test_strip_block_removes_den_created_empty_file(tmp_path):
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    rc = tmp_path / "profile.ps1"  # created form: only den's block
    rc.write_text(f"# ===== den =====\n{line}\n")
    _strip_block(rc, line)
    assert not rc.exists()  # den created it -> removed, no empty leftover


# --------------------------------------------------------------------------- #
# shell install -> uninstall round-trip (temp HOME)
# --------------------------------------------------------------------------- #


def test_uninstall_shell_round_trip(tmp_path, monkeypatch):
    from den._shell import install_shell
    from den._uninstall import _uninstall_shell

    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    monkeypatch.setenv("HOME", str(tmp_path))  # Path.home() + expanduser() on posix
    (tmp_path / ".bashrc").write_text("export FOO=1\n")

    assert install_shell(["--no-extras"]) == 0
    shell_dir = tmp_path / ".config" / "shell"
    assert (shell_dir / "_helpers.sh").is_file()
    assert "# ===== den =====" in (tmp_path / ".bashrc").read_text()

    (shell_dir / "aliases.sh").write_text("# mine\n")  # user edit -> must survive
    assert _uninstall_shell(["--yes"]) == 0
    assert (shell_dir / "aliases.sh").read_text() == "# mine\n"  # kept
    assert not (shell_dir / "_helpers.sh").exists()  # den's, removed
    assert (tmp_path / ".bashrc").read_text() == "export FOO=1\n"  # block stripped
    assert (tmp_path / ".config").is_dir()  # boundary never removed


def test_uninstall_shell_non_tty_refuses_without_yes(tmp_path, monkeypatch):
    from den._shell import install_shell
    from den._uninstall import _uninstall_shell

    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    monkeypatch.setenv("HOME", str(tmp_path))
    assert install_shell(["--no-extras"]) == 0
    assert _uninstall_shell([]) == 1  # no --yes, non-TTY -> refuse
    assert (tmp_path / ".config" / "shell" / "_helpers.sh").is_file()  # untouched


def test_uninstall_shell_removes_posix_bin_keeps_local_bin(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    monkeypatch.setattr("den._shell._windows", lambda: False)
    assert install_main(["shell", "--bin"]) == 0
    local_bin = tmp_path / ".local" / "bin"
    installed = sorted(p.name for p in local_bin.iterdir())
    assert installed, "expected at least one helper executable installed"
    assert uninstall_main(["shell", "--yes"]) == 0
    for name in installed:
        assert not (local_bin / name).exists()  # den's helpers removed
    assert local_bin.is_dir()  # boundary keeps the (now-empty) user dir


def test_uninstall_shell_keeps_user_file_in_local_bin(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    monkeypatch.setattr("den._shell._windows", lambda: False)
    assert install_main(["shell", "--bin"]) == 0
    local_bin = tmp_path / ".local" / "bin"
    mine = local_bin / "myscript"
    mine.write_text("#!/bin/sh\necho hi\n")
    assert uninstall_main(["shell", "--yes"]) == 0
    assert mine.is_file()  # a file den did not place is never removed


def test_uninstall_cline_removes_rules_parent(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    monkeypatch.setattr("den._install.shutil.which", lambda e, path=None: None)
    assert install_main(["skills", "--tool", "cline", "--with-parent"]) == 0
    rules_parent = tmp_path / "Documents" / "Cline" / "Rules" / "AGENTS.md"
    assert rules_parent.is_file()
    assert uninstall_main(["skills", "--tool", "cline", "--with-parent", "--yes"]) == 0
    assert not rules_parent.exists()


def test_interactive_uninstalls_cheatsheets(monkeypatch):
    # Parity with `den install` interactive, which offers cheatsheets: the bare
    # `den uninstall` interactive flow must dispatch _uninstall_cheatsheets too.
    from den import _ui, _uninstall

    monkeypatch.setattr(_ui, "select", lambda *a, **k: [])  # no skills chosen
    calls = []
    monkeypatch.setattr(
        _uninstall, "_uninstall_shell", lambda argv: calls.append(("shell", argv)) or 0
    )
    monkeypatch.setattr(
        _uninstall,
        "_uninstall_cheatsheets",
        lambda argv: calls.append(("cheatsheets", argv)) or 0,
    )
    assert _uninstall._interactive() == 0
    assert ("shell", []) in calls
    assert ("cheatsheets", []) in calls  # was never dispatched before the fix


def _interactive_skills_flags(monkeypatch, *, parent: bool):
    """The flags interactive `den uninstall` hands _uninstall_skills."""
    from den import _ui, _uninstall

    monkeypatch.setattr(_ui, "select", lambda *a, **k: ["claude"])
    monkeypatch.setattr(_ui, "confirm", lambda *a, **k: parent)
    monkeypatch.setattr(_uninstall, "_uninstall_shell", lambda argv: 0)
    monkeypatch.setattr(_uninstall, "_uninstall_cheatsheets", lambda argv: 0)
    seen = []
    monkeypatch.setattr(
        _uninstall, "_uninstall_skills", lambda argv: seen.append(argv) or 0
    )
    assert _uninstall._interactive() == 0
    return seen


def test_interactive_uninstall_offers_the_parent_prompt(monkeypatch):
    """Interactive install deploys the parent by default; interactive
    uninstall never passed --with-parent, so CLAUDE.md/AGENTS.md stayed
    loaded, pointing at skills that were gone."""
    assert _interactive_skills_flags(monkeypatch, parent=True) == [
        ["--tool", "claude", "--with-parent"]
    ]


def test_interactive_uninstall_keeps_the_parent_when_declined(monkeypatch):
    assert _interactive_skills_flags(monkeypatch, parent=False) == [
        ["--tool", "claude"]
    ]


def test_interactive_uninstall_removes_the_parent_install_deployed(
    tmp_path, monkeypatch
):
    from den import _ui, _uninstall

    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("USERPROFILE", str(tmp_path))
    assert install_main(["skills", "--tool", "claude", "--with-parent"]) == 0
    parent = tmp_path / ".claude" / "CLAUDE.md"
    assert parent.is_file()
    monkeypatch.setattr("sys.stdin.isatty", lambda: True)
    monkeypatch.setattr(_ui, "select", lambda *a, **k: ["claude"])
    monkeypatch.setattr(_ui, "confirm", lambda *a, **k: True)
    monkeypatch.setattr(_uninstall, "_uninstall_shell", lambda argv: 0)
    monkeypatch.setattr(_uninstall, "_uninstall_cheatsheets", lambda argv: 0)
    assert _uninstall._interactive() == 0
    assert not parent.exists()
    assert not (tmp_path / ".claude" / "skills").exists()


def test_uninstall_usage_common_flags_scoped(capsys):
    # The "Common" flags line must not claim --yes/--dry-run apply to every
    # target: `den uninstall hook` rejects them (exit 2), so the line is scoped.
    assert uninstall_main(["--help"]) == 0
    assert "Common (skills/shell/cheatsheets):" in capsys.readouterr().out


def test_uninstall_leaf_help_prints_usage(capsys):
    # `den uninstall <target> --help` should print usage and exit 0, not error 2.
    for target in ("skills", "shell", "cheatsheets"):
        for flag in ("--help", "-h", "help"):
            assert uninstall_main([target, flag]) == 0
            assert "usage: den uninstall" in capsys.readouterr().out
