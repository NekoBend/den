# Example: green on Linux, red on Windows

A worked reproduce-into-repair chain where the platform is the variable and
the test, not the code, holds the bug. This is the shape SKILL.md should
produce when a failure will not reproduce locally. Adapt the shape, do not
copy the wording.

## Input from the user

> The windows CI job fails on the test I just added. Everything passes here.

## Worked output

**Reproduced:** not locally, and that is the finding. The test passes on
Linux every time. The failure exists only on the windows runner, so the
platform is a variable and not background.

The exact failure from the job log, not a paraphrase:

    >       assert not os.access(skill, os.X_OK)
    E       AssertionError: assert not True

**What changed:** the code is new (the test was added in this PR), so the
question is not what changed but what differs. One environment says a file
is not executable and the other says it is, for the same bytes.

**Hypotheses**

1. The install code sets the executable bit on Windows when it should not.
2. `os.access(path, os.X_OK)` does not mean the same thing on Windows.

**The observation that separates them:** run the check on a file the install
never touched. On Windows, `os.access(<any existing file>, os.X_OK)` returns
True for a plain text file too. That kills hypothesis 1 - the install is not
involved - and confirms hypothesis 2.

**Cause:** Windows has no executable permission bit. `os.access` reports
`X_OK` for every file that exists, so the negative half of the assertion
cannot hold there by construction. The production change is correct; the
test asserted something that is only meaningful on POSIX.

**Fix:** read `st_mode & 0o111` directly, which is the thing the install
actually sets, and skip the test on Windows where the concept does not
exist. This removes the cause; suppressing the failure by dropping the
negative assertion would have kept the test green while no longer checking
that content files stay unmarked.

**Regression test:** the test itself is the regression test. Confirmed it
still fails on the pre-fix install code (0644 stays 0644, no executable bit)
and passes after, on Linux; skipped on Windows.

**Elsewhere:** `grep -rn "os.access" tests/` finds no other permission
assertion. No further sites.
