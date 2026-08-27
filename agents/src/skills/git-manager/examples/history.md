# Example: history mode

A worked "fold a change into an earlier commit" (fixup plus non-interactive
autosquash), with the published check, the confirmation gate, and a recovery
path. This is the shape the history mode of SKILL.md should produce. Adapt the
shape, do not copy the wording.

## Input from the user

> I forgot to update the README in the commit where I added the `--json` flag.
> Fold this README change into that commit.

## Worked output

Step H1, identify the commit:
```
git --no-pager log --oneline -5
```
```
9f3a1c2 (HEAD) Add tests for --json
a1b2c3d Add --json flag
7e4d5f6 Initial CLI
```
The target is `a1b2c3d Add --json flag`.

Step H2, published check:
```
git --no-pager log --oneline origin/feature/json-flag..HEAD
```
Both `a1b2c3d` and `9f3a1c2` are ahead of the remote, so this history is NOT
published. The rewrite is local and reflog-recoverable; no force-push is needed.
(If it had been pushed, this step would flag a force-push and higher stakes.)

Step H3, the plan:
```
git add README.md
git commit --fixup=a1b2c3d
git -c sequence.editor=: rebase --autosquash -i a1b2c3d~1
```
Effect: the README change is squashed into `a1b2c3d`; `a1b2c3d` and every commit
after it get new hashes, but their content is unchanged except for the folded
README. Reversible alternative: keep the README as its own separate commit
("Document --json flag") if you would rather not rewrite history at all.

Step H4: this rewrites history, so confirm before running.
> User: yes, fold it in.

Step H5, verify and recovery:
```
git --no-pager log --oneline -5
```
```
b8c9d0e (HEAD) Add tests for --json
f1a2b3c Add --json flag
7e4d5f6 Initial CLI
```
The README now lives in the `--json` commit (`f1a2b3c`). To undo the rebase,
run `git reflog`, find the `HEAD@{n}` from just before the rebase, and
`git reset --hard HEAD@{n}`.

## Why this is correct

- The exact target commit was identified by SHA and subject before any change
  (Step H1).
- Whether the history was published was checked explicitly, which decides
  whether a force-push and higher-stakes confirmation are needed (Step H2).
- The plan was shown with its effect AND a reversible alternative, then run only
  after explicit confirmation (Steps H3, H4, Safety rule 3).
- The autosquash is non-interactive (`sequence.editor=:`), so no editor blocks
  (Safety rule 2).
- A concrete recovery path via `git reflog` was given (Step H5).
