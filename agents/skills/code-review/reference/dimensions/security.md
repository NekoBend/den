# Security review

Review lens: can a hostile or malformed input cause harm,
such as data exposure, an unauthorized action, code execution,
or resource exhaustion?
This pass is ONLY about security.
Correct behavior for trusted input belongs to the correctness pass;
speed belongs to the performance pass.
Here you assume the input is controlled by an attacker.

## What to look for

- Trust boundaries: every place external input enters the code
  (HTTP request, CLI argument, file, environment variable, network reply)
  is validated or sanitized before it is used.
- Injection: user-controlled data reaching a SQL query, a shell command,
  a file path, a template, or a deserializer without escaping
  or parameterization.
- Authorization: every privileged action checks that the caller
  is allowed to perform it.
  A check that trusts a client-supplied identity or role is not a check.
- Secrets: no credential, API key, or token hardcoded in source,
  written to logs, or returned in an error message.
- Sensitive data: personal or confidential data is not logged,
  not put in verbose errors, and not sent to an unintended destination.
- Cryptography: no home-made crypto, no outdated algorithm,
  no disabled certificate verification,
  no predictable randomness used for a security purpose.
- Resource limits: external input that controls a size, a count,
  or a loop has an upper bound, so a large input cannot exhaust
  memory or CPU.
- Dependencies: no obviously abandoned or untrusted package
  pulled in for a security-relevant job.

## Common defects in this dimension

- User-controlled data concatenated into a query, command, or path
  instead of being parameterized or escaped.
- Authorization decided from a value the client can set.
- A secret committed in source or printed to a log.
- Untrusted data deserialized directly into live objects.
- An external size or count used with no upper limit.
- An error message that leaks a stack trace, a query, or a secret.

## How to verify

- run-checks.sh: the linter flags some classes
  (for example shellcheck catches unsafe shell expansion).
  See SKILL.md Step 3 for invocation.
- Trace each trust boundary by hand:
  mark where attacker-controlled input enters,
  then follow it to every place it is used.
- These scripts do NOT do dynamic scanning or dependency CVE auditing.
  When the change is security-sensitive,
  recommend the user run a dedicated SAST tool and a dependency scanner;
  state plainly that this review did not perform those.

## Language specifics

For the safe API in the target language
(parameterized queries, running a subprocess without a shell,
the vetted crypto library),
consult the shared reference for the target language
(SKILL.md Step 4 gives the path).
