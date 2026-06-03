# Example: guide mode

A worked README for a small CLI, written for a new user with the sections in
reading order. This is the shape the guide mode of SKILL.md should produce.
Adapt the shape, do not copy the wording.

## Input from the user

> Write a README quickstart for `tally`, a CLI that counts lines, words, and
> bytes in text files and can emit JSON. Audience: someone using it for the
> first time.

## Worked output

# tally

`tally` counts the lines, words, and bytes in text files, like `wc`, with an
optional machine-readable JSON mode.

## Prerequisites
- Python 3.10 or newer on your PATH.

## Install
```
pip install tally-cli
```

## Quickstart
Count a single file:
```
tally report.txt
```
```
report.txt  120 lines  980 words  6.2 kB
```

## Common tasks
Emit JSON for scripts:
```
tally --json report.txt
```
Count several files at once:
```
tally *.md
```

## Gotchas
- `--json` prints one JSON object per file, newline-delimited (JSONL), not a
  single array. Parse it line by line.

**Assumes:** Python 3.10+ on PATH, and that the input files are UTF-8 text.

## Why this is correct

- The audience (first-time user) and goal (count files, optionally as JSON)
  were pinned, so the README is a quickstart, not a full reference (Step G1).
- The sections run in the order a new user needs them: what it is,
  prerequisites, install, quickstart, common tasks, gotchas (Step G2).
- Every command is runnable and shows its output, so the reader can confirm
  they are on track (Step G3).
- It documents only stated features. It does not invent flags like `--csv` or
  a config file that were never described; inventing them would violate the
  Faithfulness rule.
- Prerequisites and the UTF-8 assumption are stated, so a reader who follows
  the steps will not hit an unstated requirement (Step G4).
