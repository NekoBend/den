# Example: a read-only review panel with a dissent seat

A worked plan-run-integrate chain for reviewing the master's own work
before merge. This is the shape SKILL.md should produce. Adapt the
shape, do not copy the wording.

## Input from the user

> Two PRs are ready. Have a few agents review them, fix whatever is
> real, and push the fixes so I can merge.

## Worked output

**Plan** (P1: the master wrote both PRs, so rule 2 applies - this is
exactly the case that cannot be self-reviewed; two diffs plus an
adversarial pass is well past a handful of tool calls):

- reviewer A - PR 1 only: is the change complete and consistent with
  what its description claims? Read-only.
- reviewer B - PR 2 only: is every factual claim in the new content
  true? Read-only, told to measure rather than assert.
- dissent seat - both PRs: the strongest honest case that merging
  either is a mistake, including what both authors passed over.
  Read-only.
- All three engines: the master's own tier (rule of the model table:
  review runs on the master's tier, not on a cheaper one).

**Launched:** three read-only reviewers, one message, background.
Told the user in two lines; kept answering an unrelated CI question
while they ran.

**Returned:**
- A: merge-safe, three minor leftovers.
- B: not merge-safe, two factual errors with measurements attached.
- dissent: blocker - the tree still contradicts the change in three
  places the diff itself touched, and one verification claim in the
  PR body is vacuous.

**Verified** (I1, before acting on any of it):
- Opened each file:line the reports named. All three leftovers real.
- Re-ran reviewer B's two measurements; both reproduced.
- The dissent's "vacuous check" claim confirmed by reading the
  checker: it skips the file type this PR consists of, so the PR
  body's "checker passed" line proved nothing.

**Adopted / rejected:** all confirmed findings adopted; one dissent
item rejected - it asked for a policy the user had already explicitly
declined, which a reviewer cannot know. Conflict between A
(merge-safe) and the dissent (blocker) resolved by the artifacts, not
by rank: the dissent had the evidence.

**Changed:** both branches fixed and re-pushed - covered by the user's
explicit "fix and push" in the request; on a review-only request this
section would end at "fixes prepared, push awaiting your go-ahead"
(rule 6). The false verification line removed from the PR body;
`git status` clean before and after the reviewers ran, confirming
read-only held.
