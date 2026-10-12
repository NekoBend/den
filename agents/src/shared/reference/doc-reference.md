# documenter: reference mode

Steps R1 to R4 of documenter's reference mode,
with its output format and its checklist.
documenter's SKILL.md sends you here when the mode is reference.

### Step R1: Read the code
Identify the units to document (the public functions, classes, or module
surface). Read their implementation. Do not document from the names alone.

### Step R2: Extract per unit, from the code
For each public unit: its purpose, each parameter (name, type, meaning), the
return value, the errors or exceptions it raises, and any important behavior
(side effects, preconditions, ordering). Take each from the code. If a behavior
is unclear, mark it as a question, do not guess.

### Step R3: Write the entries
One entry per unit in a consistent format, including a minimal usage example
that would actually run.

### Step R4: Faithfulness check
Every documented behavior is backed by the code. List anything you could not
determine and need confirmed.

## Output format

### reference mode

    ## <unit name>
    <one-line purpose>

    **Parameters:** <name> (<type>) - <meaning>   (repeat, or "none")
    **Returns:** <type> - <meaning>   (or "none")
    **Raises:** <error> - <when>   (or "none")

    **Example:**
    ```<language>
    <minimal runnable usage>
    ```

    (repeat per unit)

    **Could not determine:** <behaviors needing confirmation, or "none">

## Checklist (run before sending)

If reference:
- [ ] I read the implementation, not just the names.
- [ ] Each unit has purpose, parameters, returns, raises, and a runnable
      example.
- [ ] I listed anything I could not determine from the code.
