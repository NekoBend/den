---
name: prompt-engineering
description: Author a new prompt from a goal, or improve an existing prompt's clarity and reliability. Use this skill when the user asks to write / design / draft a prompt or system prompt, OR to improve / fix / debug / make more reliable a prompt they already have. Detects the mode (author from a goal, or improve an existing prompt) and applies explicit prompt-design principles tuned for models that follow instructions literally. Distinct from compressor, which shortens a prompt without changing behavior; route here when the goal is a better or new prompt, not a shorter one. Does not write application code (that is coding).
---

# Prompt-engineering skill

Produce prompts that a model follows correctly on the first try.
A strong prompt is explicit, single-purpose, and self-checkable;
it does not rely on the model to guess intent.

This skill runs under a parent system prompt.
The parent prompt's honesty and language rules always apply (standard honesty norms when no parent prompt is deployed);
this skill does not override them.

## Detect the mode

First decide which one mode the request is, then follow that mode below:

1. author: write a new prompt from a stated goal.
   Triggers: write a prompt, design a system prompt, draft a prompt that makes
   the model do X.
2. improve: diagnose and rewrite an existing prompt.
   Triggers: improve this prompt, why does this prompt fail, make this prompt
   more reliable, fix this system prompt.

If the request is ambiguous, ASK. Note the boundary: making a prompt SHORTER
with the same behavior is the compressor skill; making it BETTER or writing a
new one is this skill. Run ONE mode per request.

## Principles of a strong prompt (apply in both modes)

1. State the role and the goal explicitly. Say what the model is and what one
   job it must do.
2. Give step-by-step instructions. Do not rely on the model to infer the
   procedure.
3. One task per prompt. Many simultaneous instructions degrade adherence; split
   unrelated jobs into separate prompts.
4. Specify the output format exactly: structure, length, and what NOT to
   include.
5. Handle the edges. Say what to do when input is missing, ambiguous, or out of
   scope, instead of leaving it to chance.
6. Show an example of the desired output when the format is non-trivial.
7. Make success checkable. Give the model criteria it can verify against before
   it answers.
8. Remove ambiguity. Define terms; replace vague qualifiers ("good", "concise")
   with concrete, measurable ones.

## Mode: author

### Step A1: Pin the job
What task the prompt must make the model perform, the target model and context,
what inputs the model will have, and the exact desired output. If any of these
is unclear, ASK under <work_discipline> Clarification discipline.

### Step A2: Draft against the principles
Write the prompt covering: role and goal, the instructions, the constraints and
edge handling, the output format, an example if the format is non-trivial, and
explicit success criteria.

### Step A3: Stress-test
List two or three ways the prompt could be misread or could fail, then tighten
the wording to close each one.

### Step A4: Deliver
Output the prompt, then a short note on the load-bearing design choices.

## Mode: improve

### Step I1: Restate the goal
State what the existing prompt is supposed to achieve. If it is not obvious from
the prompt, ASK; do not guess the intent and optimize for the wrong target.

### Step I2: Diagnose
List the specific weaknesses, each tied to a principle above (for example
"no output format stated (principle 4)", "four unrelated tasks in one prompt
(principle 3)", "edge case of empty input unhandled (principle 5)").

### Step I3: Rewrite
Rewrite to fix each diagnosed weakness. Preserve the original intent; do not
silently change the task. If you must change scope to make it coherent, flag
that change explicitly.

### Step I4: Deliver
Output the improved prompt, then the diagnosis: what was weak and what changed,
mapped to the principles.

## Output format

### author mode

    ```
    <the prompt>
    ```

    **Design notes:** <the load-bearing choices: why this role, this format,
    these constraints>

### improve mode

    **Diagnosis:**
    - <weakness> (principle <n>)
    (repeat per weakness)

    ```
    <the improved prompt>
    ```

    **What changed:** <each fix, mapped to the diagnosis; note any scope change>

For JSON output (when explicitly requested), use the two-step pattern:
a short reasoning block first, then a single fenced ```json``` block
with nothing after the closing fence.

## Self-check (run before sending)

Common:
- [ ] I picked exactly one mode and stated it (or asked when unclear).
- [ ] The prompt I produced states a role, a single goal, instructions, an
      output format, edge handling, and checkable success criteria.
- [ ] The prompt has no vague qualifier I could have made concrete.

If author:
- [ ] I pinned the job (task, target model, inputs, output) or asked.
- [ ] I stress-tested for at least two failure or misreading modes.

If improve:
- [ ] I stated the original goal and preserved its intent.
- [ ] Every diagnosed weakness is tied to a principle and addressed in the
      rewrite.
- [ ] I flagged any change of scope rather than making it silently.
