# Example: commit mode

A worked commit showing the branch step and the "describe the diff, not the
journey" rule in action. This is the shape the commit mode of SKILL.md should
produce. Adapt the shape, do not copy the wording.

## Input from the user

> Commit my changes. (During this session I first added a `backoff_linear`
> helper, then replaced it with `backoff_exponential` and called it from
> `request_with_retry`. I am on `main`.)

## Worked output

Step C0, branch: you are on `main` and this is new work, so create a feature
branch first.
```
git switch -c feature/retry-backoff
```

Step C1, inspect:
```
git --no-pager status
git --no-pager diff
```
The diff adds `backoff_exponential(attempt)` to `client/retry.py` and calls it
from `request_with_retry`. There is no `backoff_linear` in the tree.

Step C2: one logical change, so one commit.

Steps C3 and C4, message from the diff:
```
git add client/retry.py
git commit -m "Add exponential backoff to request retries" \
  -m "Retries now wait 2**attempt seconds (capped) instead of a fixed delay, so a busy upstream is not hammered."
git --no-pager show --stat HEAD
```

## Why this is correct

- New work started on a feature branch, not on `main` (Step C0, Branching
  model).
- The message describes what the committed diff contains: exponential backoff.
  It does NOT say "replace linear backoff with exponential", because
  `backoff_linear` never landed in the tree. A reader inspecting the code would
  find no linear version, so mentioning it would only confuse them. This is the
  "describe the diff, not the journey" rule: the message was derived from
  `git --no-pager diff --staged`, not from the session's edit history.
- The commit is non-interactive: the message is passed with `-m`, not by
  opening an editor, and inspection used `--no-pager` (Safety rule 2).
- Only the intended file was staged (`git add client/retry.py`), not
  `git add -A` (Step C4).
