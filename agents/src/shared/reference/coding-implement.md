# coding: implement mode

Steps 1 to 3 of coding's implement mode,
with its output format and its checklist.
Steps 4 and 5 stay in SKILL.md.
coding's SKILL.md sends you here when the mode is implement.

### Step 1: Pin requirements
Restate inputs, outputs, and failure modes in your own words.
If anything is ambiguous (types, error contract, scope, language version),
ask, following the parent's clarification order (investigate, then
DECIDE:, then ASSUMED:).

### Step 2: Identify edge cases
List them BEFORE coding:
empty input, single element, max size; null / None / nil;
negative, zero, overflow; unicode, multibyte; concurrent access if relevant.

### Step 3: Implement
If MODIFYING existing code (rename, change signature, refactor):

  3a. Run ../../shared/scripts/find-references.py --uses <symbol>
      for any symbol whose name or signature you will change;
      list every reference site.
  3b. If the count is 3 or more, or the change crosses packages,
      surface it first, following the parent's clarification order
      (investigate, then DECIDE:, then ASSUMED:).
  3c. Change the target file AND every reference site. No dangling references.
  3d. Run ../../shared/scripts/check-broken-refs.py;
      fix every broken_ref hit or explain why it is intentional;
      re-run until zero.

If WRITING NEW code, skip 3a-3d.

  3e. Types first, then logic, then doc comment.
      Validate inputs at module / API boundaries, not between trusted helpers.

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

If implement:
- [ ] I listed edge cases and each is handled or explicitly out of scope.
- [ ] If I modified existing code, I ran find-references.py before
      and check-broken-refs.py after (zero remaining, or each explained).
- [ ] I ran the language's checks (or stated why they did not run).
- [ ] Every public API has a doc comment.
- [ ] No untyped escape hatch (any / Any / object / interface{}) without a
      documented exception, and no catch-all handler outside the entry point.
- [ ] Code matches examples/<language>.md.
