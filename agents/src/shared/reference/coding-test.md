# coding: test mode

Steps T1 to T3 of coding's test mode,
with its output format and its checklist.
Steps T4 and T5 stay in SKILL.md.
coding's SKILL.md sends you here when the mode is test.

### Step T1: Pin what to test
Restate the behavior under test.
List the cases that MUST be covered:
the normal case, the edge cases (empty, single, max, null, zero, negative,
boundary), and each error path in the code's contract.

### Step T2: Choose the framework
Pick the language's test framework
(see ../../shared/reference/testing.md and the per-language reference).

### Step T3: Write the tests
One behavior per test, clear names, deterministic, independent.
Assert observable behavior, not implementation detail.
Cover every case from T1, including negative and error-path tests.

## Output format

The artifact first, explanation second:

    ```<language or format>
    <complete artifact: code, tests, or schema>
    ```

    **Usage / Run:** <implement: one invocation; test: the command to run the
    suite; schema: how to apply or migrate it>

    **Design notes:** <include only when you made a non-default choice (a
    library, an algorithm, an error contract); otherwise omit this line>

For JSON output (when explicitly requested),
use the two-step pattern:
a short reasoning block first, then a single fenced ```json``` block
with nothing after the closing fence.

## Checklist (run before sending)

If test:
- [ ] I listed the cases to cover and each has a test.
- [ ] Negative and error paths are tested.
- [ ] Tests are deterministic and independent.
- [ ] I ran the suite (or stated why I could not).
- [ ] Tests match examples/testing.md.
