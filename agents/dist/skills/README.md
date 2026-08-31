# den-free skill copies

Generated from `agents/src/skills/` by `python3 -m den._portable`; do not edit
here. Each directory is a self-contained skill: copy it into the directory your
tool reads skills from (for example `~/.claude/skills/<name>/`) and it works
without den installed. Compared with the source skills: `den verify` is
replaced by the bundled `shared/scripts/run-checks.sh`, the den board
paragraphs are removed, and `shared/` paths are relative to the skill.
