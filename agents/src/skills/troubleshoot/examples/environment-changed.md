# Example: the code did not change, the world did

A worked diagnose pass where the cause is outside the repository. This is the
shape the diagnose mode of SKILL.md should produce. Adapt the shape, do not
copy the wording.

## Input from the user

> CI went red on main and nobody pushed anything. The lint job fails with 19
> errors. It was green yesterday.

## Worked output

**Reproduced:** `ruff check den tests` locally reports the same 19 errors.
So this is not a CI-only artifact and not a flake.

**What changed** (asked before opening the code):

- Code: `git log --since=yesterday` on main is empty. Nothing was pushed.
- Data: the lint job reads the repository only. No inputs to change.
- Environment: the workflow installs `ruff` with no version pin.
  `pip index versions ruff` shows 0.16.0 published this morning; the last
  green run installed 0.15.4.

Two of the three questions ruled themselves out in one command each. The
third named the suspect.

**Hypotheses**

1. The new ruff release widened its default rule set, so rules that were
   never enabled here now fire.
2. The new release changed behavior of a rule that was already enabled, so
   the same rule now reports more.

**The observation that separates them:** pin the old version and re-run.
`pip install ruff==0.15.4 && ruff check den tests` reports 0 errors, and the
19 findings under 0.16.0 all carry rule codes that do not appear anywhere in
the 0.15.4 output. That is hypothesis 1 - new rules, not changed ones.
Hypothesis 2 would have shown the same rule codes with more hits.

**Cause:** the repository has no ruff configuration at all, so it inherits
whatever the installed ruff considers default, and CI installs ruff
unpinned. A release that widens the defaults turns CI red on code that did
not change.

**Fix:** pin the linter in the workflow AND write an explicit
`[tool.ruff.lint]` select list, so the rule set is a decision in this
repository rather than a property of whichever version got installed. The
19 findings are fixed in the same commit.

Pinning alone would have been the workaround: green again, same trap on the
next deliberate bump.

**Elsewhere:** `ty` is installed unpinned in the same job and has the same
exposure. Pinned in this commit too, before it bites.
