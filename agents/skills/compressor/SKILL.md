---
name: compressor
description: Shorten existing text without changing its meaning. Summarize a document, article, transcript, or conversation into fewer words, OR compress a prompt / instruction / context payload to fewer tokens while preserving every directive's effect. Use this skill when the user asks to summarize / condense / shorten / tighten / TLDR a passage, OR to compress / reduce the token count of a prompt or context while keeping its behavior. Detects the mode (summarize general text for a reader, or compress a prompt/context preserving all instructions). Never adds information absent from the source. Distinct from prompt-engineering, which authors or improves a prompt's quality rather than shortening it; route there when the goal is to make a prompt work better, not shorter.
---

# Compressor skill

Make text shorter without changing what it means.
You remove and rephrase; you never add.

This skill runs under a parent system prompt.
<honesty_contract> and <language_policy> from the parent always apply;
this skill does not override them.

## Faithfulness rule (both modes)

The output contains no information, claim, or instruction that is absent from
the source. If the source is unclear or ambiguous, preserve that ambiguity;
do not resolve it by inventing detail.

## Detect the mode

First decide which one mode the request is, then follow that mode below:

1. summarize: condense a body of text for a human reader.
   Triggers: summarize, condense, TLDR, give me the gist, shorten this
   article / document / thread.
2. compress: reduce a prompt, instruction, or context to fewer tokens while
   keeping its behavior identical.
   Triggers: compress this prompt, reduce tokens, make this system prompt
   shorter without changing what it does, fit this into a smaller budget.

If the request is ambiguous, ASK. In particular, "shorten this prompt" is
ambiguous: fewer tokens with the same behavior is compress mode, but "make this
prompt better" is the prompt-engineering skill, not this one. Confirm which.
Run ONE mode per request.

## Mode: summarize

### Step S1: Pin the target
The length or ratio (for example "to 5 bullets", "to 100 words", "to 20%"),
the audience, and the purpose. If unspecified, state the target you are
assuming, or ask.

### Step S2: Extract what must survive
The thesis, the key claims, decisions, numbers, names, dates, and any action
items. These are non-droppable.

### Step S3: Write the summary
Write at the target length, faithful and neutral.
Preserve the source's stance; do not add opinion or interpretation.

### Step S4: Check coverage
Every must-survive item from S2 is present, and nothing absent from the source
was introduced.

## Mode: compress

### Step C1: Classify the content
- Operative (must survive in effect): instructions, constraints, format rules,
  definitions, decisive examples, and exact tokens (API names, format strings,
  magic values, identifiers).
- Removable: redundancy, repeated rules, filler, hedging, verbose phrasing,
  and prose that carries no directive.

### Step C2: Rewrite tighter
Collapse repetition, shorten phrasing, merge overlapping rules.
Keep exact tokens verbatim; do not paraphrase a format string or an identifier.

### Step C3: Preserve every directive
Each instruction and constraint in the original is still present in effect
after compression. You may merge two rules into one sentence, but you may not
drop either rule's requirement.

### Step C4: Verify behavior-equivalence
Walk the original directive by directive and confirm each one survives.
Confirm you added no new instruction.
Note the approximate token reduction if it is useful.

## Output format

### summarize mode

The summary at the target length (prose or bullets, as the target specifies).
Then, only when you left out a category of detail the reader might expect
(otherwise omit this line):

    **Dropped:** <kinds of detail left out, so the reader knows the boundary>

### compress mode

    ```
    <the compressed prompt / context>
    ```

    **Preserved:** <the directives carried over>
    **Removed:** <what kind of redundancy or filler was cut>
    **Approx reduction:** <before -> after, in tokens or words, if estimable>

For JSON output (when explicitly requested), follow the parent <output_format>
two-step pattern.

## Self-check (run before sending)

Common:
- [ ] I picked exactly one mode and stated it (or asked when unclear).
- [ ] The output adds nothing that is absent from the source.

If summarize:
- [ ] I met the target length or ratio (or stated the assumption).
- [ ] Every must-survive item (thesis, numbers, names, decisions, action
      items) is present.
- [ ] The summary is neutral, with no added opinion.

If compress:
- [ ] Every original directive survives in effect.
- [ ] Exact tokens (API names, format strings, identifiers) are kept verbatim.
- [ ] No new instruction was introduced.
- [ ] I reported what was removed.
