# Example: verify mode

A worked fact-check showing atomic claim extraction, per-claim labels, and the
no-memory rule. This is the shape the verify mode of SKILL.md should produce.
Adapt the shape, do not copy the wording.

## Input from the user

> Fact-check this: "Redis 7.0 was released in 2022, it made RESP3 the new
> default protocol, and it is written in Rust."
>
> Sources:
> [S1] Redis release notes: "Redis 7.0.0 was released on April 27, 2022."
> [S2] Redis protocol docs: "RESP3 was introduced in Redis 6.0. In Redis 7.0,
>      RESP2 remains the default; a client opts into RESP3 by sending HELLO 3."

## Worked output

**Claims checked:** 3

[Supported] Redis 7.0 was released in 2022.
Source: [S1]
Quote:  "Redis 7.0.0 was released on April 27, 2022."

[Contradicted] Redis 7.0 made RESP3 the new default protocol.
Source: [S2]
Quote:  "In Redis 7.0, RESP2 remains the default; a client opts into RESP3 by
        sending HELLO 3."

[Not enough information] Redis is written in Rust.
Source: none
Quote:  none

**Verdict:** 1 supported, 1 contradicted, 1 not enough information.

## Why this is correct

- The compound sentence was split into three atomic, separately checkable
  claims before any checking (Step V1).
- The release-year claim is entailed by S1 (a date in 2022), so it is
  Supported, not merely "mentioned" (Step V3).
- The RESP3 claim is the opposite of what S2 states, so it is Contradicted,
  with the exact span quoted, not paraphrased.
- The implementation-language claim has NO provided source. Even though the
  model may "know" Redis is written in C, it does not have a source span for
  it, so the label is Not enough information. It is NOT marked Contradicted
  from memory. This is the no-source-no-claim rule in action.
- Each Supported and Contradicted label carries both a source id and a quoted
  span; the NEI label carries neither and makes that explicit.
