---
name: documenter
description: Writes documents as the deliverable. Produces an API reference from existing code; a document for human readers such as a README, how-to, tutorial, concept explanation, design doc, proposal, report, runbook, meeting minutes, decision record, or slide outline, as Markdown, HTML, or a Confluence page; a revision of a draft that keeps what it says; or a natural translation of a document between Japanese and English. Use when the user asks to document something, write or revise a document, minutes, or a Confluence page, explain a concept in a document, or translate a document.
---

# Documenter skill

Write documents a reader can rely on and use.
Every statement is backed by a source:
the code or system,
or material the user supplied.

This skill runs under a parent system prompt.
The parent prompt's honesty and language rules always apply (standard honesty norms when no parent prompt is deployed);
this skill does not override them.

## Source rule (all modes)

Write only what a source supports.
For reference mode and for a guide about software,
the source is the code or the system.
For any other document,
the source is the material the user gave you:
notes, decisions, data, an earlier draft.

When the document needs something no source supports,
ask for it,
or mark it in the text as a proposal, a plan, or an open question.
Never state it as fact.
Do not add a feature, a decision, a date, a number, or an owner
that the source does not contain.

In translate mode the source is the original text:
render all of it,
and add nothing.

## Detect the mode

First decide which one mode the request is,
then follow that mode below:

1. reference: document the API of existing code.
   Triggers: document this function / class / module, write API docs,
   write docstrings as a reference, generate a reference for this code.
2. guide: write a document for human readers,
   or revise a draft so it reads better.
   Triggers: write a README / how-to / tutorial / design doc / proposal /
   report / runbook / meeting minutes / decision record / slide outline /
   Confluence page, explain a concept as a document,
   turn these notes into minutes,
   rewrite / proofread / tidy this draft.
3. translate: render a document in another language,
   Japanese and English in either direction,
   or another pair on request.
   Triggers: translate this, put this into English / Japanese,
   英訳 / 和訳, check this translation against the original.

If the request is ambiguous,
pick the more likely mode, name it on an ASSUMED: line, and start.
Reserve a DECIDE: line for the case where the modes
would produce materially different deliverables.

Writing a new document in a language other than the notes' language
is guide mode, not translate:
"write a design doc in English from these Japanese notes" is guide.
translate is for a finished text that must keep its content.

Note the boundaries:
adding doc comments while writing the code is the coding skill;
making a text shorter, in any language, is the compressor skill;
checking claims against sources is the grounding skill;
a commit message or a PR description is the git-manager skill;
an explanation given as a chat reply, not as a document, is not this skill.

Run one mode per pass, not one mode per request.
A request that needs two modes gets two passes in the same turn:
finish the first, deliver its output, then start the second.

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

Read shared/reference/doc-guide.md now,
and follow its Steps G0 to G4 in order;
at Step G2 it sends you to shared/reference/doc-genres.md.
Before you write, also read shared/reference/writing.md.

These rules hold even before you open those files:

- Markdown, unless the document's structure needs HTML;
  a file that lives in a repository stays Markdown.
- For a Confluence page, read shared/reference/confluence.md,
  give a Markdown draft first,
  and write the storage format only after the user says the draft is fine,
  changing no content in that step.
- For a Japanese document, read shared/reference/japanese-style.md,
  and write it in です・ます from start to end
  unless the user asks for another style.
- Put the conclusion, the recommendation, or the request
  in the first paragraph.
- A revision keeps every claim, number, name, and date,
  adds no fact, and lists what changed.

## Mode: translate

Read shared/reference/translation.md now,
and follow its Steps T1 to T4 in order.

These rules hold even before you open that file:

- Render all of the source, and add nothing.
- Code, commands, identifiers, paths, URLs, placeholders, and markup
  stay unchanged and in place.
- Into Japanese, read shared/reference/japanese-style.md,
  and write in です・ます unless the user asks for another style.
- When a sentence can be read two ways, ask,
  or translate the more likely reading and add a translator's note.
- Check the result against the source as a separate pass.

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

guide and translate mode: use the output format
in the reference file your mode told you to read.

### JSON output

For JSON output (when explicitly requested), use the two-step pattern:
a short reasoning block first, then a single fenced ```json``` block
with nothing after the closing fence.

## Self-check (run before sending)

Common:
- [ ] I picked exactly one mode and stated it (or asked when unclear).
- [ ] Every statement has a source; anything without one is marked
      as a proposal, a plan, or an open question.
- [ ] I did not add a feature, a decision, a date, a number, or an owner
      that the source does not contain.

If reference:
- [ ] I read the implementation, not just the names.
- [ ] Each unit has purpose, parameters, returns, raises, and a runnable
      example.
- [ ] I listed anything I could not determine from the code.

If guide:
- [ ] I read doc-guide.md, followed Steps G0 to G4, and ran its checklist.
- [ ] For Confluence, the storage format came only after the user approved the Markdown draft.

If translate:
- [ ] I read translation.md, followed Steps T1 to T4, and ran its checklist.
- [ ] Nothing is added or dropped, and the non-translatables are unchanged.
