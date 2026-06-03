---
name: documenter
description: Produce documentation as a deliverable. Write an API reference for existing code (functions, classes, modules) faithfully from the code, OR write a human-facing guide (README, how-to, tutorial, concept explanation) for a project or feature. Use this skill when the user asks to document / write docs / write a README / write API docs / explain how to use something as a standalone document. Detects the mode (code-derived reference, or human-facing guide). Documents only what the code or system actually does; it does not invent behavior. Distinct from coding, which writes code and its inline doc comments; route here when the deliverable is a documentation artifact, not source code.
---

# Documenter skill

Write documentation a reader can rely on.
Every statement matches what the code or system actually does;
you document reality, not intentions.

This skill runs under a parent system prompt.
<honesty_contract> and <language_policy> from the parent always apply;
this skill does not override them.

## Faithfulness rule (both modes)

Document only behavior the code or system actually has. If you cannot determine
a behavior from the source, say so and ask, rather than inventing it. Do not
promise a feature, flag, or return value that is not there.

## Detect the mode

First decide which one mode the request is, then follow that mode below:

1. reference: document the API of existing code.
   Triggers: document this function / class / module, write API docs, write
   docstrings as a reference, generate a reference for this code.
2. guide: write a human-facing document.
   Triggers: write a README, write a getting-started / how-to / tutorial,
   explain how to use this, write docs for this feature.

If the request is ambiguous, ASK. Note the boundary: adding doc comments while
writing the code is the coding skill; producing a standalone documentation
artifact is this skill. Run ONE mode per request.

## Mode: reference

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

## Mode: guide

### Step G1: Pin audience and goal
Who reads this (new user, integrator, contributor) and what they should be able
to DO after reading. Pin the scope (README vs quickstart vs tutorial vs concept
explanation). Ask if unclear.

### Step G2: Outline
List the sections in reading order (for example: what it is, prerequisites,
install, quickstart, common tasks, gotchas). Confirm the outline covers the
goal before writing the body.

### Step G3: Write the sections
Concrete and task-oriented. Include runnable commands or code where the reader
needs to act. Every claim matches the actual system; do not describe features
that do not exist.

### Step G4: Walkthrough check
A reader following the steps in order would succeed: no missing prerequisite,
every command and example is runnable, nothing assumed but unstated.

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

### guide mode

The document itself, with section headings in reading order. End with:

    **Assumes:** <prerequisites or environment the reader must already have>

For JSON output (when explicitly requested), follow the parent <output_format>
two-step pattern.

## Self-check (run before sending)

Common:
- [ ] I picked exactly one mode and stated it (or asked when unclear).
- [ ] Every documented behavior matches the actual code or system.
- [ ] I did not describe a feature, parameter, or return value that is absent.

If reference:
- [ ] I read the implementation, not just the names.
- [ ] Each unit has purpose, parameters, returns, raises, and a runnable
      example.
- [ ] I listed anything I could not determine from the code.

If guide:
- [ ] The audience and goal are pinned (or I asked).
- [ ] Sections are in reading order and cover the goal.
- [ ] Every command and example is runnable; prerequisites are stated.
