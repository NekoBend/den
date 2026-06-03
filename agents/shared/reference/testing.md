# Testing reference

The single source of test-quality knowledge.
Two consumers use it:
the coding skill's test mode (how to WRITE good tests),
and the code-review skill's tests dimension (how to JUDGE tests).
Both apply the same criteria below.

## What a good test has (the criteria)

- Behavior coverage: the normal case AND the edge cases are tested
  (empty, single, maximum, null, zero, negative, boundary).
- Error paths: each failure in the code's contract has a test that triggers it.
- Meaningful assertions: each test asserts observable behavior
  and would actually fail if that behavior broke.
  A test that cannot fail is worse than no test, because it misleads.
- Determinism: the result does not depend on wall-clock time, a random seed,
  network availability, or the order tests run in.
- Independence: each test sets up its own state
  and does not rely on another test having run first.
- Clear intent: the test name says which behavior it pins down.

## How to write tests

- One behavior per test. If you need "and" to describe it, split it.
- Arrange, act, assert: set up inputs, run the unit, check the result,
  in that visible order.
- Name by behavior, not by method:
  "returns_zero_for_empty_input", not "test_proc_1".
- Cover every case from the criteria above explicitly,
  including at least one negative test (invalid input is rejected).
- Mock at boundaries (network, clock, filesystem), not internal helpers.
  Over-mocking couples the test to the implementation.

## Coverage: behavior over lines

Line coverage is necessary, not sufficient:
code can be run by a test that asserts nothing.
Map each behavior and edge case to a test;
the gap that matters is an untested behavior, not an untested line.

## Frameworks by language

| Language   | Default test framework   | Run command (typical) |
|------------|--------------------------|-----------------------|
| Python     | pytest                   | pytest                |
| TypeScript | vitest (or jest)         | vitest run            |
| Go         | standard testing package | go test ./...         |
| Rust       | built-in #[test]         | cargo test            |
| Java       | JUnit 5                  | mvn test              |
| C#         | xUnit                    | dotnet test           |
| Shell      | bats                     | bats <dir>            |

For framework-specific idioms (fixtures, parametrization, table tests),
consult the per-language reference.

## Determinism pitfalls (the usual flaky-test causes)

- Time: freeze or inject the clock; do not assert on "now".
- Randomness: seed it, or inject the value.
- Network and filesystem: stub them; a unit test must not hit the network.
- Order and shared state: no test may depend on another test's leftovers.
