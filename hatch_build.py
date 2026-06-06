"""Bundle deployable content into the wheel, excluding tests and caches.

pyproject `force-include` cannot filter nested paths, so the deployable content
(skills, shared, dist, cheatsheets, shell) is mapped into den/_data/ here, with
__pycache__ / .pytest_cache / tests and *.pyc skipped. Keeps test fixtures and
caches out of the distribution.
"""

from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface

_BUNDLE = {
    "agents/skills": "den/_data/agents/skills",
    "agents/shared": "den/_data/agents/shared",
    "agents/dist": "den/_data/agents/dist",
    "cheatsheets": "den/_data/cheatsheets",
    "shell": "den/_data/shell",
}
_SKIP_DIRS = {"__pycache__", ".pytest_cache", "tests"}


class CustomBuildHook(BuildHookInterface):
    def initialize(self, version, build_data):
        root = Path(self.root)
        force = build_data.setdefault("force_include", {})
        for src, dest in _BUNDLE.items():
            base = root / src
            if not base.is_dir():
                continue
            for path in base.rglob("*"):
                if not path.is_file() or path.suffix == ".pyc":
                    continue
                rel = path.relative_to(base)
                if any(part in _SKIP_DIRS for part in rel.parts):
                    continue
                force[str(path)] = f"{dest}/{rel.as_posix()}"
