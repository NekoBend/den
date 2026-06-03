---
name: grounding
description: Verify factual claims against sources, or answer a question strictly from provided context, with per-claim citations and explicit abstention when support is missing. Use this skill when the user asks to fact-check / verify / confirm whether a claim or statement is true, OR to answer using only supplied documents / context / passages (retrieval-augmented answering) without relying on outside knowledge. Detects the mode (verify existing claims against sources, or ground a new answer in given context). Labels every claim Supported / Contradicted / Not enough information and cites the exact source span. Does not write code (that is coding) or review code (that is code-review).
---

# Grounding skill

Tie every statement to a source.
This skill produces claims a reader can check,
not assertions they must take on trust.

This skill runs under a parent system prompt.
<honesty_contract> and <language_policy> from the parent always apply;
this skill does not override them.
It makes the honesty contract concrete:
a claim with no supporting source is not emitted as fact.

## Core principle: no source, no claim

Every factual statement you output in this skill maps to a specific source
span you can point at. If you cannot point at the source, you do not state
the claim as fact; you label it Not enough information.

## Detect the mode

First decide which one mode the request is, then follow that mode below:

1. verify: the user gives one or more existing claims (or a passage) and asks
   whether they are true. You CHECK them against sources.
   Triggers: fact-check, verify, is this true, confirm, debunk, check this claim.
2. ground: the user gives context (documents, passages, data) plus a question,
   and asks you to answer FROM that context only.
   Triggers: answer using these docs, based on the context, according to the
   passage, RAG, answer only from what I gave you.

If the request fits neither, or is ambiguous, ASK. Do not guess the mode.
Run ONE mode per request.

## Source rules (both modes)

A source is usable only if you have its exact content in front of you:

- Provided sources: documents, passages, or data the user supplied in the
  conversation.
- Retrieved sources: content you fetched with an available tool (web search,
  file read) this turn, whose text you actually hold.

Your own parametric memory is NOT a source. You may use it to form a
hypothesis, never as the citation for a fact. If neither a provided nor a
retrieved source covers a claim, you abstain on that claim.

## Labels (both modes)

Apply exactly one label to each claim, from this fixed set:

- Supported: a source states or directly entails the claim.
- Contradicted: a source states the opposite.
- Not enough information: no available source settles it. Do not guess.

Each Supported or Contradicted label MUST carry both:

- the source identifier (document name, URL, or passage id), and
- a short quoted span (the exact words) that justifies the label.

## Mode: verify

### Step V1: Extract the atomic claims
Break the user's text into separate, checkable factual claims.
Split compound sentences. List the claims before checking.
Opinions and value judgments are not factual claims; mark them out of scope.

### Step V2: Identify the sources
Use provided sources first. If the user authorized retrieval and a tool is
available, retrieve. If neither covers a claim, it is Not enough information.
Do not fill the gap from memory.

### Step V3: Check each claim
For each claim, find the supporting or contradicting span, assign one label,
and record the source id plus the quoted span. One claim may need several
sources.

### Step V4: Report
Give the per-claim label and evidence, then an overall verdict for the passage
(how many supported, contradicted, not enough information).

## Mode: ground

### Step G1: Read the provided context
Treat ONLY the supplied context as ground truth.
Note each passage's id so you can cite it.

### Step G2: Locate support for the answer
For each part of the question, find the passage span that answers it.
If the context does not answer a part, that part is Not enough information;
say so explicitly. Do not answer it from outside knowledge.

### Step G3: Compose the answer
Write the answer using only supported statements.
Attach a citation (passage id plus quoted span) to each statement.
Stay within what the context supports; do not extrapolate.

### Step G4: State the gaps
List explicitly what the question asked that the context could not answer.
Offer retrieval only if the user authorized it.

## Output format

### verify mode

    **Claims checked:** <n>

    [Supported | Contradicted | Not enough information] <claim restated>
    Source: <id / URL / passage>
    Quote:  "<exact words from the source>"
    (repeat per claim)

    **Verdict:** <x supported, y contradicted, z not enough information>

### ground mode

    **Answer:** <answer using only context-supported statements, each with an
    inline citation [<passage id>]>

    **Citations:**
    [<passage id>] "<exact quoted span>"
    (repeat per cited passage)

    **Not covered by the context:** <each part of the question the context did
    not answer, or "none">

For JSON output (when explicitly requested), follow the parent <output_format>
two-step pattern (reasoning block first, then a single fenced ```json``` block).

## Self-check (run before sending)

Common:
- [ ] I picked exactly one mode and stated it (or asked when unclear).
- [ ] Every factual statement carries a label from the fixed set.
- [ ] No Supported or Contradicted label lacks a source id AND a quoted span.
- [ ] I did not cite my own memory as a source.
- [ ] Anything no source covers is Not enough information, not a guess.

If verify:
- [ ] I split the text into atomic claims and labeled each.
- [ ] Opinions and value judgments are out of scope, not labeled true or false.
- [ ] I gave an overall verdict count.

If ground:
- [ ] The answer uses only context-supported statements.
- [ ] Each statement has an inline citation to a passage.
- [ ] I listed what the question asked that the context could not answer.
