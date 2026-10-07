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

### Step G0: Pick the format and the destination

Markdown by default. Choose HTML when the document's own structure is what
makes it hard to read as plain text:

- a specification, or anything with numbered requirements that get
  cross-referenced
- a summary that has to hold several dimensions at once (comparison tables,
  a matrix, results per case)
- anything carrying a diagram, or where layout is part of the meaning

Markdown stays right for a README, an API reference, CONTRIBUTING, and any
file the user said lives in the repository: anything reviewed, versioned, or
edited there stays Markdown, since its diffs must show content, not markup.
Anything an agent re-reads as working state (memory files, imprints, context
payloads) stays plain minimal text with no markup that multiplies its token
cost; that rule wins even inside a repository, so a committed memory or
context file stays minimal Markdown or plain text, never styled markup. Do
not infer repository residence from the
working directory - code files sitting nearby are not a signal that this
document gets committed. When the request carries numbered requirements or a
per-case table and the user did not say where the file goes, choose HTML.

When you pick HTML, write ONE self-contained file: styles inline, no external
fonts, scripts, or images, readable by opening it in a browser with no
server. Say which format you chose and why in one line, so the user can ask
for the other one.

When the destination is a Confluence page:

1. Read shared/reference/confluence.md.
2. Use the edition and the route the user named.
   When the user named none,
   assume Data Center and its page editor,
   and say so on an ASSUMED: line.
3. Write the first draft in Markdown,
   so the user can check the content before it goes into Confluence.
4. When the user says the draft is fine,
   write the same content again in the Confluence storage format
   (XHTML with ac: macros).
   Change no content in this step; only the format changes.
   Tell the user to paste it through the Source Editor:
   the <> icon in the editor toolbar
   (built into Data Center 10.2.3 and later,
   a Marketplace app on earlier versions).
   When the editor has no <> icon,
   give Confluence wiki markup for Insert > Markup instead.

This two-step flow is for Confluence pages only.
The storage format is not the self-contained HTML file described above;
do not mix the two.

### Step G1: Pin the reader, the goal, and the scope

Write down three things before you write the document:

- the reader: their role, and how much they already know about the topic
- the goal: what the reader can do, decide, or understand after reading
- the scope: what the document covers, and what it does not cover

Put the reader and the scope near the top of the document itself.
When two kinds of readers need different things,
write one document or one clearly separated section for each.
Ask when the reader or the goal is unclear.

### Step G2: Pick the genre and outline

Pick one genre from the table below.
One document has one genre:
do not put a procedure inside a concept explanation,
and do not put background inside a how-to.
Outline the sections in the table's order.
Write each heading so it states the point of its section:
reading only the title and the headings in order
must give the reader the conclusion and the flow.

| Genre | Sections in order | Check before sending |
|---|---|---|
| README | what it is; install; quickstart; common tasks; where to get help | every command runs |
| how-to | goal; prerequisites; numbered steps; result; if it fails | each step is one action |
| tutorial | what the reader builds; prerequisites; steps, each with a visible result; next steps | a newcomer can finish it |
| concept explanation | the idea in one sentence; how it works, from a concrete example to the general rule; why it matters; limits; related topics | no procedure inside |
| design doc | background; goals and non-goals; proposed design; alternatives considered; risks; open questions | every alternative says why it was not chosen |
| proposal | the request or the recommendation; background; options with their cost; the recommended option and why; what the reader is asked to do | the request is in the first paragraph |
| report | the conclusion; findings with numbers and their sources; analysis; next steps | every number traces to a source |
| runbook | when to use it; impact; checks; steps to mitigate; steps to resolve; who to escalate to | each step names its expected result |
| meeting minutes | date and attendees; decisions, each with its reason; action items, each with one owner and a due date; open questions | no owner or date the notes do not contain |
| decision record | context; the decision in one sentence; options considered; consequences; status | the decision is one sentence |
| slide outline | title; one message per slide, written as a full sentence; 3 to 5 supporting points per slide; speaker notes | the slide messages alone tell the story |

When the request is to revise a draft,
keep the draft's genre and section order
unless the user asks to restructure it.

### Step G3: Write the sections

Read shared/reference/writing.md and follow it.
When the document is in Japanese,
also read shared/reference/japanese-style.md,
and write the whole document in です・ます
unless the user asks for another style.

Put the conclusion, the recommendation, or the request
in the first paragraph,
then the reasons and the details.
Mark anything the source does not support
as a proposal, a plan, or an open question (Source rule).

When the request is to revise a draft:
keep every claim, number, name, and date the draft contains,
and change only how it is written.
Do not add a fact or a claim.
If a sentence is unclear in meaning, not only in wording,
ask instead of guessing what it meant.

### Step G4: Reader check

Read the document as the reader from Step G1 and check:

- the title and the headings alone give the conclusion and the flow
- the conclusion or the request is in the first paragraph
- every term is defined at its first use, and one idea keeps one term
- every number, date, name, owner, and due date matches the source
- a procedure works when followed from the first step, with nothing assumed but unstated
- the row's check in the genre table holds

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

### JSON output

For JSON output (when explicitly requested), use the two-step pattern:
a short reasoning block first, then a single fenced ```json``` block
with nothing after the closing fence.

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
- [ ] I chose Markdown or HTML on the document's structure, said which and
      why, and any HTML I wrote is one self-contained file.
- [ ] The audience and goal are pinned (or I asked).
- [ ] Sections are in reading order and cover the goal.
- [ ] Every command and example is runnable; prerequisites are stated.
