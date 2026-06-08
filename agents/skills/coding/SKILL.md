---
name: coding
description: Produce code artifacts (implement features, write tests, or design data and API schemas) in Python, TypeScript, Go, Rust, Java, C#, or Shell. Use this skill when the user asks to implement / write / build / fix a function, class, or module; to write or add tests for code; or to design a schema, data model, or type definitions. Detects the task mode (implement / test / schema) and the target language, then follows a mode-specific workflow. Uses shared per-language reference files and shared verification scripts. Produces new code; to review existing code, use code-review.
---

# Coding skill

Produce code artifacts that are complete, typed, idiomatic for the target
language, and ready to drop in.
No sketches, no "you would add error handling here" placeholders.

This skill runs under a parent system prompt.
<honesty_contract> and <language_policy> from the parent always apply;
this skill does not override them.

## Detect the task mode

First decide which one mode the request is, then follow that mode below:

1. implement: write new feature code, or modify existing code.
   Triggers: implement, write, build, add, fix, refactor a function/class/module.
2. test: write tests for code (existing or just produced).
   Triggers: write tests, add tests, cover this with tests, test this.
3. schema: design a data or API schema.
   Triggers: design a schema, model this data, define the types,
   design the table / the API shape.

If the request fits none of these, or is ambiguous, ASK.
Do not guess the mode.

Run ONE mode per request.
Do not blend modes:
if the user wants code AND its tests,
finish implement mode and deliver, then run test mode as a separate pass.

## Common setup (all modes)

### Detect the target language

Pick the language in this order:

1. Explicit user instruction.
2. File extension (.py / .ts / .go / .rs / .java / .cs / .sh).
3. Project context (existing imports, build files, lockfiles).
4. If none of the above resolves it: ASK the user. Do not guess.

| Language   | Reference (read when working in this language) |
|------------|------------------------------------------------|
| Python     | ../../shared/reference/python.md               |
| TypeScript | ../../shared/reference/typescript.md           |
| Go         | ../../shared/reference/go.md                   |
| Rust       | ../../shared/reference/rust.md                 |
| Java       | ../../shared/reference/java.md                 |
| C#         | ../../shared/reference/csharp.md               |
| Shell      | ../../shared/reference/shell.md                |

### Read the relevant references

Read ../../shared/reference/architecture.md
AND the per-language reference from the table above.
Then read the mode reference:

- test mode also reads ../../shared/reference/testing.md
- schema mode also reads ../../shared/reference/schema-design.md

Apply all of them during the work.

## Mode: implement

### Step 1: Pin requirements
Restate inputs, outputs, and failure modes in your own words.
If anything is ambiguous (types, error contract, scope, language version),
ask under <work_discipline> Clarification discipline.

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
      surface it under <work_discipline> Clarification discipline first.
  3c. Change the target file AND every reference site. No dangling references.
  3d. Run ../../shared/scripts/check-broken-refs.py;
      fix every broken_ref hit or explain why it is intentional;
      re-run until zero.

If WRITING NEW code, skip 3a-3d.

  3e. Types first, then logic, then doc comment.
      Validate inputs at module / API boundaries, not between trusted helpers.

### Step 4: Verify with scripts
Run against the file you produced:

1. ../../shared/scripts/run-checks.sh <file>       # format + lint + typecheck
2. ../../shared/scripts/verify-imports.py <file>   # imported APIs exist
3. ../../shared/scripts/doc-coverage.py <file>     # public API has docs
4. ../../shared/scripts/check-broken-refs.py       # only when modifying

Resolve every finding (fix, or suppress with a written reason).
If a script cannot run, state which and proceed. Do not pretend a check passed.

### Step 5: Compare against examples/<language>.md
Confirm your code matches the canonical shape (typing, docs, error handling).
Adapt the shape, do not copy the wording.

## Mode: test

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

### Step T4: Run them
Execute the suite; report the exact command and its result.
If you cannot run it, say so. Do not report a pass you did not run.
Also run ../../shared/scripts/run-checks.sh on the test file.

### Step T5: Compare against examples/testing.md

## Mode: schema

### Step S1: Gather the model
Entities, fields and their types, relationships, constraints,
and which fields are required vs optional.
Ask if the domain is unclear. Do not invent entities.

### Step S2: Choose the form
Database DDL, JSON Schema, language types, or an API contract,
based on where the schema is used
(see ../../shared/reference/schema-design.md).

### Step S3: Design
Apply normalization vs denormalization deliberately.
Express constraints (keys, uniqueness, nullability, ranges).
Plan for evolution (versioning or migration).
State where the schema is validated at the boundary.

### Step S4: Verify
For a code schema (types, ORM models):
run ../../shared/scripts/run-checks.sh and verify-imports.py.
For a non-code schema (SQL DDL, JSON Schema):
validate with a tool if one exists, otherwise state it was reviewed by reading.

### Step S5: Compare against examples/schema.md

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
follow the parent <output_format> two-step pattern
(reasoning block first, then a single fenced ```json``` block).

## Self-check (run before sending)

Common:
- [ ] I picked exactly one mode and stated it (or asked when unclear).
- [ ] I named the target language and read its reference,
      plus the mode reference (testing.md or schema-design.md) when relevant.

If implement:
- [ ] I listed edge cases and each is handled or explicitly out of scope.
- [ ] If I modified existing code, I ran find-references.py before
      and check-broken-refs.py after (zero remaining, or each explained).
- [ ] I ran run-checks.sh, verify-imports.py, doc-coverage.py
      (or stated which could not run).
- [ ] Every public API has a doc comment.
- [ ] No untyped escape hatch (any / Any / object / interface{}) without a
      documented exception, and no catch-all handler outside the entry point.
- [ ] Code matches examples/<language>.md.

If test:
- [ ] I listed the cases to cover and each has a test.
- [ ] Negative and error paths are tested.
- [ ] Tests are deterministic and independent.
- [ ] I ran the suite (or stated why I could not).
- [ ] Tests match examples/testing.md.

If schema:
- [ ] Entities and constraints are captured (or I asked).
- [ ] I chose the schema form deliberately for where it is used.
- [ ] Constraints and nullability are explicit; evolution is considered.
- [ ] I validated the schema (or stated it was reviewed by reading).
- [ ] Schema matches examples/schema.md.
