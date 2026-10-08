# git-manager: commit and pr modes

The branching model,
and Steps C0 to C4 and P1 to P4 of git-manager's commit and pr modes,
with their output format and their checklists.
git-manager's SKILL.md sends you here when the mode is commit or pr,
and before you create a branch in another mode.

Run one mode per pass, not one mode per request. A request that needs two
modes gets two passes in the same turn: finish the first, deliver its
output, then start the second. This chain is the common case here, not the
exception - "commit this and open a PR" is commit mode followed by pr mode,
and stopping after the commit leaves the request half done.

## Branching model (default: GitHub Flow)

The default workflow is GitHub Flow. Follow it unless the user specifies a
different model or branch; explicit user instructions take precedence.

1. The default branch (main or master) stays deployable. Do not commit new work
   directly to it.
2. Start each piece of work on a short-lived branch created from the current
   default branch, with a descriptive name. Match the repo's existing naming if
   one is visible (`git --no-pager branch -a`); otherwise use a clear
   `type/short-description` form such as `feature/add-retry` or `fix/null-header`.
3. Commit your work to that branch (commit mode).
4. Open a pull request from the branch into the base for review (pr mode).
5. After approval, the branch is merged through the pull request (per the repo's
   convention); then delete the merged branch.
6. Keep a branch focused on one logical change.

## Describe the diff, not the journey (commit and pr)

A commit message or PR description states the NET change that is actually in the
code, read from the diff. It does not narrate the editing process from the
conversation or work history.

Worked danger: during the work you added function B, then later replaced B with
C. The committed code contains A and C; B never lands. The message must describe
A and C. It must NOT say "changed B to C", because a reader inspecting the code
finds no B and is confused by a step that is not in the tree. Describe the
destination, not the path you took to it.

## Mode: commit

### Step C0: Be on the right branch
If you are on the default branch (main or master) and starting new work, create
a feature branch first per the Branching model, unless the user told you to
commit on the current branch. If already on a feature branch, continue on it.

### Step C1: Inspect
Run `git --no-pager status`, `git --no-pager diff`, and
`git --no-pager diff --staged` to see every change.

### Step C2: Group into logical commits
Do not mix unrelated changes in one commit. If the working tree holds several
independent changes, propose splitting them and stage each group separately.

### Step C3: Write the message from the diff
Base the message on the staged diff (`git --no-pager diff --staged`): describe
the net change the commit introduces, per "Describe the diff, not the journey"
above. Match the repository's existing convention for the format (read recent
`git --no-pager log`). Write the message in English
unless the user or the repository's instruction file (CLAUDE.md, AGENTS.md)
asks for another language. Default to a concise imperative subject (around 50
characters) plus, when the change touches control flow or a public contract,
a body explaining WHY.

### Step C4: Commit
Stage the intended files (do not `git add -A` blindly; stage what you mean) and
commit with the message passed via `-m` (repeat `-m` for a body) or `-F`, never
by opening an editor. Show the result with `git --no-pager show --stat HEAD`.

## Mode: pr

### Step P1: Inspect the branch
Identify the base branch and run `git --no-pager log <base>..HEAD` and
`git --no-pager diff <base>...HEAD` to see exactly what the PR would contain.

### Step P2: Summarize the change
Group the commits into a coherent summary of what changed and why, from the
diff (not the work history).

### Step P3: Write the PR text
A clear title and a description with: summary, the notable changes, how it was
tested, and anything reviewers should watch for.

### Step P4: Create it (only if asked)
Confirm the remote and base branch first. The branch must be pushed before the
PR; pushing is a remote-affecting step under the safety rules. Use the platform
CLI if available (for example `gh pr create`), and show the command before
running it.

## Output format

For commit and pr: show the commands you ran, the commit message or PR text in a
fenced block, and the resulting state.

## Checklist (run before sending)

If commit:
- [ ] New work went onto a feature branch, not directly onto the default branch
      (unless the user directed otherwise).
- [ ] Unrelated changes are in separate commits, not one blob.
- [ ] The message is derived from `git --no-pager diff --staged`, passed via
      `-m`/`-F`, and matches the repo's convention.

If pr:
- [ ] The summary reflects `<base>..HEAD`, not the work history.
- [ ] The description covers changes, testing, and reviewer notes.
