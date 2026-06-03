# Tests review

Review lens: do the tests give enough confidence
that this code works and will keep working after a change?
This pass is ONLY about test adequacy.
You judge the TESTS here, not the code under test:
the code's own correctness is the correctness pass.

## What to look for

Apply the criteria in the shared testing reference
(shared/reference/testing.md) as your checklist.
For each, check whether the tests under review meet it:

- behavior coverage (the normal case plus the edge cases:
  empty, single, maximum, null, zero, negative, boundary),
- error paths triggered,
- meaningful assertions (a test that cannot fail is itself a finding),
- determinism (no time, randomness, network, or order dependence),
- independence,
- clear intent in each test name.

One review-specific check the criteria do not state:
when the change fixes a bug, a regression test for that bug must exist.

## Common defects in this dimension

- Only the happy path is tested; the edge and error cases are not.
- A test that asserts nothing meaningful, or cannot fail.
- A flaky test that depends on time, randomness, or execution order.
- A fixed bug shipped with no regression test.
- Tests coupled to internal details,
  so a safe refactor breaks them for no real reason.

## How to verify

- Run the test suite if one is present,
  and state the exact command and its result.
  Do not report a pass you did not run.
- Map each correctness edge case to a test;
  list the cases that have no test as findings.
- Treat line coverage as necessary, not sufficient:
  code can be executed by a test that asserts nothing.
  Behavior coverage is what matters.

## Language specifics

For the test framework and conventions,
consult the shared testing reference (shared/reference/testing.md)
and the per-language reference.
