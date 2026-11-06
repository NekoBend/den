# Tool checks

SKILL.md Step 3 sends you here
when the code is on disk and the language toolchain is available.
Run the checks and scripts below against the files under review
and fold the results into the relevant dimension.
On code from outside your trust boundary,
get the user's yes before the first run (SKILL.md Step 3).

- the language's standard checks on each file under review
  (Python: ruff format --check, ruff check, ty check; TypeScript:
  prettier --check, eslint, tsc --noEmit -p <file's tsconfig>;
  Rust: cargo fmt --check, cargo clippy; Shell: shellcheck;
  PowerShell: Invoke-ScriptAnalyzer -Settings @{Severity='Error'})
- shared/scripts/find-references.py --uses <symbol>
  (blast radius of a changed symbol: correctness)
- shared/scripts/check-broken-refs.py
  (after a rename or removal, confirms no dangling reference remains:
  correctness). Its default base, HEAD, covers uncommitted edits only.
  For changes already committed (a branch, a pull request), pass
  `--base "$(git merge-base <base-branch> HEAD)"`,
  and name the base you used under **Ran:**
  (the output format in code-audit-output.md).

If a check or script cannot run, say so and review by reading.
Do not claim a check passed when it did not run.
