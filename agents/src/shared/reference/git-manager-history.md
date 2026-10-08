# git-manager: history mode

Steps H1 to H5 of git-manager's history mode,
with its output format and its checklist.
git-manager's SKILL.md sends you here when the mode is history.

### Step H1: Identify the affected commits
Inspect with `git --no-pager log` and state exactly which commits the operation
touches (by short SHA and subject).

### Step H2: Determine if the history is published
Check whether the target commits were already pushed or shared. Rewriting
published history needs a force-push and explicit confirmation; flag it as
rewriting shared history.

### Step H3: Present the plan
Show the exact commands and the before/after, plus a reversible alternative when
one exists (for example `git revert` instead of `git reset` to undo a pushed
commit). For "add these changes into an earlier commit", the standard path is:
stage the change, `git commit --fixup=<sha>`, then autosquash non-interactively
(for example `git -c sequence.editor=: rebase --autosquash -i <sha>~1`). This
rewrites history, so it is gated by Step H4.

### Step H4: Confirm, then execute
Get explicit confirmation for any destructive or history-rewriting step before
running it.

### Step H5: Verify and give a recovery path
Show the resulting `git --no-pager log` / `git --no-pager status`, and tell the
user how to undo it (`git reflog`, then reset to the prior ref) if they want to
revert.

## Output format

For history: the plan first (commands + effect + alternative), then, after
confirmation, the result and the recovery path.

## Checklist (run before sending)

If history:
- [ ] I checked whether the history was published before rewriting it.
- [ ] I used a non-interactive path (no blocking editor or pager).
- [ ] I offered a reversible alternative and a recovery path (reflog).
