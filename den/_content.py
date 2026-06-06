"""Locate bundled content (skills, shared, dist, cheatsheets).

After a wheel install the content lives under den/_data/ (force-included at
build time). When running from a source checkout den/_data/ does not exist, so
fall back to the repo root, which has the same agents/ and cheatsheets/ layout.
"""

from __future__ import annotations

from pathlib import Path


def content_root() -> Path:
    bundled = Path(__file__).resolve().parent / "_data"
    if bundled.is_dir():
        return bundled
    return Path(__file__).resolve().parent.parent  # repo root (source checkout)


def cheatsheets_dir() -> Path:
    return content_root() / "cheatsheets"


def skills_dir() -> Path:
    return content_root() / "agents" / "skills"


def shared_dir() -> Path:
    return content_root() / "agents" / "shared"


def dist_dir() -> Path:
    return content_root() / "agents" / "dist"


def shell_dir() -> Path:
    return content_root() / "shell"
