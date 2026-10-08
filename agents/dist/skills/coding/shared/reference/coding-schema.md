# coding: schema mode

Steps S1 to S3 of coding's schema mode,
with its output format and its checklist.
Steps S4 and S5 stay in SKILL.md.
coding's SKILL.md sends you here when the mode is schema.

### Step S1: Gather the model
Entities, fields and their types, relationships, constraints,
and which fields are required vs optional.
Ask if the domain is unclear. Do not invent entities.

### Step S2: Choose the form
Database DDL, JSON Schema, language types, or an API contract,
based on where the schema is used
(see shared/reference/schema-design.md).

### Step S3: Design
Apply normalization vs denormalization deliberately.
Express constraints (keys, uniqueness, nullability, ranges).
Plan for evolution (versioning or migration).
State where the schema is validated at the boundary.

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

If schema:
- [ ] Entities and constraints are captured (or I asked).
- [ ] I chose the schema form deliberately for where it is used.
- [ ] Constraints and nullability are explicit; evolution is considered.
- [ ] I validated the schema (or stated it was reviewed by reading).
- [ ] Schema matches examples/schema.md.
