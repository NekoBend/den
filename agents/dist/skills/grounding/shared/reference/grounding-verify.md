# grounding: verify mode

Steps V1 to V4 of grounding's verify mode.
grounding's SKILL.md sends you here when the mode is verify.

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
