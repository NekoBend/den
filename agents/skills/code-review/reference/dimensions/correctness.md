# Correctness review

Review lens: does the code compute the right result and avoid failing
for every input it is meant to handle?
This pass is ONLY about correctness.
Leave naming and structure to the maintainability pass,
speed to the performance pass,
hostile input to the security pass,
and test adequacy to the tests pass.

## What to look for

- The normal case: does the code actually do what the stated intent says?
- Edge cases, traced one by one:
  empty input, a single element, the maximum expected size,
  null / None / nil, zero, negative numbers, overflow,
  unicode and multibyte text, boundary values (off by one).
- Error handling: is every failure mode handled,
  and does the code honor its stated error contract?
  Are errors swallowed or hidden?
- Control flow: wrong condition (and / or, a missing negation),
  a missing return, an unreachable branch, a loop bound that is off.
- Data handling: mutation of shared or aliased state,
  a value copied when a reference was meant (or the reverse),
  a surprising type coercion.
- Resource handling: every file, lock, socket, or connection
  that is opened is also released on every path, including errors.
- Concurrency, when the code is concurrent:
  unguarded shared state, a race, an assumed ordering that is not guaranteed.
- API and symbol use: arguments in the right order and type,
  return values checked, imported names that actually exist.

## Common defects in this dimension

- Off by one in a range, slice, or loop bound.
- A swallowed error: the failure is caught and then ignored,
  so the caller cannot tell anything went wrong.
- Shared mutable state used as if it were fresh per call.
- The empty or null case is simply not handled.
- Identity compared where equality was meant, or the reverse.
- A return value or error code that is never checked.
- A resource opened on the happy path but leaked on the error path.

## How to verify

When the code is on disk and the toolchain exists,
run these shared scripts (invocation paths are in SKILL.md Step 3):

- run-checks.sh
  typecheck and lint catch a whole class of correctness defects, and the
  typecheck stage confirms imported APIs actually resolve.
- check-broken-refs.py
  confirms a renamed or removed symbol left no dangling reference.

Then reason by hand: list the inputs the code claims to handle
and trace each one through to its result.
A finding you can demonstrate with a specific input is stronger
than a vague worry.

## Language specifics

For idioms that decide correctness in the target language
(identity vs equality, error wrapping, nullability, integer width),
consult the shared reference for the target language
(SKILL.md Step 4 gives the path).
