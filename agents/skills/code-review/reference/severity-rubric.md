# Severity rubric

Every finding gets exactly one severity.
Severity is about IMPACT and CERTAINTY, not about how easy the fix is.
The verdict in SKILL.md Step 6 is computed directly from the severities,
so classify honestly:
do not inflate a nit to look thorough,
and do not soften a real defect to be agreeable.

## The four levels

### blocker

The code is wrong, unsafe, or will fail, and shipping it causes real harm.
Choose blocker when at least one is true:

- It produces an incorrect result for an input the code is meant to handle.
- It crashes, hangs, or corrupts data under a realistic condition.
- It introduces a security hole (injection, auth bypass, secret exposure).
- It loses data or money.

A blocker means the change cannot ship until it is fixed.

### major

A real defect, but narrower than a blocker:
it bites only in an edge case, a specific configuration,
or it is a design problem that will cause maintenance pain soon.
Choose major when at least one is true:

- It is wrong only for an uncommon but reachable input.
- It works now but a near-term change will break it
  (for example a hidden coupling, a missing abstraction).
- It is a performance problem that matters at expected scale,
  not just in theory.

A major must be fixed before the change ships.
It need not block the rest of the review;
the author can address it as a distinct follow-up fix.

### minor

A genuine improvement that does not affect correctness or safety.
The code works; this would make it better.
Choose minor for:

- A clearer name, a simpler structure, a removed duplication.
- A missing doc comment on a public symbol.
- A test that should exist but whose absence is not dangerous.

A minor does not block the change.

### nit

A small, subjective, or stylistic point.
Mostly things a formatter or linter would catch, or pure preference.
Choose nit for:

- Formatting the tool did not enforce, wording in a comment.
- A preference with no objective advantage.

Mark nits as nits so the author can skip them without guilt.

## From severities to the verdict

Map the highest-severity finding to the verdict:

| Highest finding present | Verdict            |
|-------------------------|--------------------|
| any blocker or major    | request changes    |
| only minors and nits    | approve with nits  |
| nothing worth acting on | approve            |

## When you are unsure between two levels

- Unsure blocker vs major: ask "does a realistic, in-scope input hit this?"
  Yes means blocker, only-edge-case means major.
- Unsure minor vs nit: ask "is there an objective benefit?"
  Yes means minor, pure preference means nit.

State the uncertainty in the finding rather than hiding it.
It is honest to write "major (blocker if <condition> is reachable)".
