"""Tests for den's shared file-safety helpers (den/_fsafe.py).

install, uninstall and the hook cleanup all go through these, so they are
pinned here directly rather than only through a command.
"""

from den import _fsafe

_OUTSIDE_TEXT = "PRIVATE KEY MATERIAL\n"


# --------------------------------------------------------------------------- #
# den dir resolution
# --------------------------------------------------------------------------- #


def test_find_den_dir_uses_cwd_when_absent(tmp_path):
    assert _fsafe._find_den_dir(tmp_path) == tmp_path / ".den"


def test_find_den_dir_discovers_ancestor(tmp_path):
    (tmp_path / ".den").mkdir()
    sub = tmp_path / "a" / "b"
    sub.mkdir(parents=True)
    assert _fsafe._find_den_dir(sub) == tmp_path / ".den"


# --------------------------------------------------------------------------- #
# symlink guard: a cloned repo ships the content and layout of what den reads
# and writes, so a symlink there would make den read or write a file outside
# the workspace. den follows none of them, in either direction.
# --------------------------------------------------------------------------- #


def _outside(tmp_path):
    secret = tmp_path / "id_ed25519"
    secret.write_text(_OUTSIDE_TEXT)
    return secret


def test_symlink_component_names_the_first_link_under_root(tmp_path, symlink):
    root = tmp_path / ".den"
    (tmp_path / "elsewhere").mkdir()
    root.mkdir()
    symlink(tmp_path / "elsewhere", root / "sub")
    assert _fsafe._symlink_component(root, root / "sub" / "x.json") == root / "sub"


def test_symlink_component_names_a_symlinked_root(tmp_path, symlink):
    (tmp_path / "elsewhere").mkdir()
    root = tmp_path / ".den"
    symlink(tmp_path / "elsewhere", root)
    assert _fsafe._symlink_component(root, root / "x") == root


def test_symlink_component_names_a_dangling_link(tmp_path, symlink):
    root = tmp_path / ".den"
    root.mkdir()
    symlink(tmp_path / "missing", root / "x")
    assert _fsafe._symlink_component(root, root / "x") == root / "x"


def test_symlink_component_does_not_check_a_path_outside_root(tmp_path, symlink):
    # None outside the root means "not checked", not "safe": the caller owns
    # such a path (see the docstring).
    root = tmp_path / ".den"
    root.mkdir()
    symlink(_outside(tmp_path), tmp_path / "link")
    assert _fsafe._symlink_component(root, tmp_path / "link") is None


def test_refuse_symlink_says_why_with_the_callers_prefix(tmp_path, symlink, capsys):
    root = tmp_path / ".den"
    root.mkdir()
    symlink(_outside(tmp_path), root / "x")
    assert _fsafe._refuse_symlink(root, root / "x", "read", "den x") is True
    err = capsys.readouterr().err
    assert err.startswith("den x: refusing to read ")
    assert "is a symlink" in err


def test_refuse_symlink_passes_a_real_file(tmp_path, capsys):
    root = tmp_path / ".den"
    root.mkdir()
    (root / "x").write_text("mine")
    assert _fsafe._refuse_symlink(root, root / "x", "read", "den x") is False
    assert capsys.readouterr().err == ""


# --------------------------------------------------------------------------- #
# _write_guarded
# --------------------------------------------------------------------------- #


def test_write_guarded_writes_bytes_and_makes_the_parent(tmp_path):
    root = tmp_path / ".den"
    path = root / "sub" / "x.json"
    assert _fsafe._write_guarded(root, path, b"a\nb\n", "den x") is True
    assert path.read_bytes() == b"a\nb\n", "LF stays LF on every platform"


def test_write_guarded_replaces_what_is_there(tmp_path):
    root = tmp_path / ".den"
    root.mkdir()
    (root / "x").write_bytes(b"old content that is longer\n")
    assert _fsafe._write_guarded(root, root / "x", b"new\n", "den x") is True
    assert (root / "x").read_bytes() == b"new\n"


def test_write_guarded_refuses_to_write_through_a_symlink(tmp_path, symlink, capsys):
    secret = _outside(tmp_path)
    root = tmp_path / ".den"
    root.mkdir()
    symlink(secret, root / "x")
    assert _fsafe._write_guarded(root, root / "x", b"overwritten\n", "den x") is False
    assert secret.read_text() == _OUTSIDE_TEXT
    assert (root / "x").is_symlink(), "den must not replace the link either"
    assert capsys.readouterr().err.startswith("den x: refusing to write ")


def test_write_guarded_refuses_a_dangling_symlink(tmp_path, symlink):
    root = tmp_path / ".den"
    root.mkdir()
    target = tmp_path / "would-be-created"
    symlink(target, root / "x")
    assert _fsafe._write_guarded(root, root / "x", b"x\n", "den x") is False
    assert not target.exists()


def test_write_guarded_refuses_a_symlinked_root(tmp_path, symlink):
    outside = tmp_path / "elsewhere"
    outside.mkdir()
    root = tmp_path / "repo" / ".den"
    root.parent.mkdir()
    symlink(outside, root)
    assert _fsafe._write_guarded(root, root / "x", b"x\n", "den x") is False
    assert list(outside.iterdir()) == []


def test_write_guarded_refuses_a_directory_in_place(tmp_path, capsys):
    root = tmp_path / ".den"
    (root / "x").mkdir(parents=True)
    assert _fsafe._write_guarded(root, root / "x", b"x\n", "den x") is False
    assert (root / "x").is_dir()
    err = capsys.readouterr().err
    assert err.startswith("den x: refusing to write ")
    assert "not a regular file" in err
