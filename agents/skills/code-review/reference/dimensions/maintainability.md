# Maintainability review

Review lens: can a future reader understand this code
and change it safely without surprises?
This pass is ONLY about readability and structure.
Leave whether the code is correct, safe, or fast to their own passes;
here the code is assumed to work, and the question is how well it reads.

## What to look for

- Naming: does each name reveal its role and intent?
  A name that describes the type instead of the role is weak
  (prefer CustomerOrder over a bare Order when the domain has several).
  Misleading or vague names are findings.
- Single responsibility: does each function or class do one thing?
  Flag a unit that mixes unrelated concerns.
- Complexity: very long functions, deep nesting,
  conditionals that could be flattened with early returns.
- Duplication: copy-pasted logic that should be one shared helper.
- Abstraction: a leaky abstraction that exposes its internals,
  or a premature generalization that adds indirection for no current need.
- Documentation: every public symbol has a doc comment;
  comments explain WHY, not a restatement of WHAT the code already says;
  no stale comment that now contradicts the code.
- Consistency: the code matches the idiom of the surrounding module
  and the language style guide.
- Dead weight: unreachable code, commented-out code,
  a bare TODO with no context.

## Common defects in this dimension

- A name that describes the type rather than the role it plays.
- One function doing several unrelated jobs.
- The same logic copied in several places instead of one helper.
- A public symbol with no doc comment.
- Deeply nested conditionals that an early return would flatten.
- A comment that repeats the code instead of explaining the reason.

## How to verify

- run-checks.sh: format and lint catch style drift
  and some complexity signals. See SKILL.md Step 3 for invocation.
- doc-coverage.py: flags public symbols with no documentation.
- Read for intent: would a new contributor understand this
  in a single pass, without having to run it in their head?

## Language specifics

For naming, structure, and documentation conventions in the target language,
consult the shared reference for the target language,
and the shared architecture reference for structure defaults
(single responsibility, dependency injection, immutability).
SKILL.md Step 4 gives the path.
