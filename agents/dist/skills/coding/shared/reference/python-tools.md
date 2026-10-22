# Python reference: tools

Sections 3, 15, and 16 of the Python reference:
tooling, testing with pytest, and packaging with uv.
shared/reference/python.md lists where every section lives.

## 3. Tooling: ruff + ty

**Rule:** Default formatter is `ruff format`.
Default linter is `ruff check`.
Default type checker is `ty check`.
Prefer ty over mypy for new code.
ty is currently in beta;
if its beta limitations block progress
(missing feature, fatal error, low conformance on an edge case),
fall back to `pyrefly` before reaching for mypy.
If `pyproject.toml` declares a different toolchain
(black, isort, flake8, mypy, pyright, pyrefly),
defer to it on the existing codebase.
Project config wins on in-place edits.
For greenfield projects and new modules, choose ty.
**Why:** ruff consolidates format / lint / import-sort into one binary at native speed.
ty is Astral's type checker,
sharing ruff's engineering principles and language-server speed.
pyrefly (Meta's Rust-based type checker) is the documented fallback:
same 10-50x speed margin over mypy without ty's beta-period gaps.
mypy is correct and feature-complete
but heavy enough that developers stop running it locally;
fast feedback wins the typecheck race in practice.
Teams with an existing mypy / pyright setup have already committed to its rules and ignore lists,
so defer there rather than fragment.
**Run order:** `ruff format` → `ruff check --fix` → `ty check`.

## 15. Testing: pytest

**Rule:** New tests use pytest.
An existing unittest suite keeps its style
(pytest runs `unittest.TestCase` natively,
so adopting pytest as the runner without rewriting old tests is normal);
do not write NEW tests in unittest style alongside pytest ones.

**Why:** one assertion idiom and one fixture model per project.
These pins are the ecosystem's settled choices;
the model knows all the alternatives equally well,
and this section decides which one applies.

- Test functions follow the same rules as the code they test:
  a one-line docstring naming the behavior the test pins down,
  and a `-> None` return annotation
  (python.md section 2 and python-types.md section 5 apply to tests too).
- Plain `assert` with an expressive expression; no `self.assertEqual`.
- Exception checks are `pytest.raises(SomeError, match=...)`.
- Temporary files and directories default to the `tmp_path` fixture
  (`tmp_path_factory` when a wider scope is genuinely needed),
  not `tempfile` calls in the test body.
- Environment variables, attributes, and cwd change through `monkeypatch`
  (`setenv`, `setattr`, `chdir`);
  mutating `os.environ` directly leaks into every later test.
  Note `monkeypatch` is function-scoped:
  it cannot serve a module- or session-scoped fixture.
- Captured stdout/stderr is read from `capsys`;
  output written by child PROCESSES needs `capfd`
  (`capsys` sees only Python-level writes).
- Repeating a test over inputs is `@pytest.mark.parametrize`,
  not a for-loop in the test body
  (a loop stops at the first failure and hides the rest).
- Shared setup is a fixture,
  scoped as narrowly as correctness allows (function scope by default).
- Platform-conditional tests use `pytest.mark.skipif` with the reason
  stated, not an if-return that silently passes.
- Optional dependencies gate with `pytest.importorskip`.

Determinism rules (seeds, clocks, network) are language-neutral
and live in the testing reference; they apply unchanged.

## 16. Environments and packaging: uv

**Rule:** Default tool for environments, dependencies, builds, and tool
installs is `uv`, driven through `uv add` / `uv sync` / `uv run` -
the interface that maintains `uv.lock`.
(`uv pip` is the compatibility surface for projects staying on
`requirements.txt`; it never writes a lockfile.)
Defer to what the project already chose:
a `poetry.lock` means poetry, a `Pipfile` means pipenv,
and converting a project's packaging uninvited is out of scope.

**Why:** the model knows every packaging tool;
this section decides which one,
and the lockfile is what makes that choice reproducible.

- Project metadata lives in `pyproject.toml`;
  no `setup.py` or `setup.cfg` in new pure-Python projects
  (a native-extension build is the exception that still needs one).
- Applications commit their lockfile; libraries do not.
- Linters and dev tools: a version-pinned dev-dependency group run via
  `uv run`, or ephemeral `uvx` for one-offs - both are legitimate.
  What must exist somewhere is the PIN:
  an unpinned linter turns CI red on code that did not change.
