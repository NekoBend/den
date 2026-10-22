# Python reference: types and versions

Sections 5, 6, 13, and 14 of the Python reference:
annotations, modern syntax, version awareness, and import locations.
shared/reference/python.md lists where every section lives.

## 5. Type annotations: PEP 484/585/604/695

**Rule:** Annotate every public function signature (parameters and return).
Annotate non-obvious local variables.
Use the modern forms:

- `list[int]`, `dict[str, int]`, `tuple[int, ...]` instead of `typing.List[...]`
  (PEP 585, 3.9+).
- `X | Y` instead of `typing.Union[X, Y]` (PEP 604, 3.10+).
- `X | None` instead of `typing.Optional[X]` (PEP 604, 3.10+).
- `type Alias = ...` and `class Box[T]: ...` instead of `TypeAlias` / classic `TypeVar`
  (PEP 695, 3.12+).

**Why:** Newer forms are part of the language proper;
the `typing` module generics are legacy.
See architecture.md section 6 (Type safety)
for the generic rule about avoiding escape hatches.
**Defer to section 13** before applying.
The project's declared Python version determines which of these forms is admissible.
**Example:**

```python
def merge_settings(
    base: dict[str, str],
    override: dict[str, str] | None = None,
) -> dict[str, str]:
    return {**base, **(override or {})}
```

## 6. Modern syntax minimums

**Rule:** Use the highest-version form admissible by the project's declared Python version.
Common version-gated upgrades:

| Version | Modern form | Legacy form to avoid |
|---|---|---|
| 3.9+ | `list[int]`, `dict[str, X]` | `typing.List[int]`, `typing.Dict[str, X]` |
| 3.10+ | `X \| Y` | `typing.Union[X, Y]` |
| 3.10+ | `X \| None` | `typing.Optional[X]` |
| 3.10+ | `match` / `case` over a tagged union | nested `if` / `elif` chain |
| 3.11+ | `Self` from `typing` | `TypeVar` bound to the class |
| 3.11+ | `tomllib` (stdlib) | `tomli` (third-party) |
| 3.12+ | `type Alias = ...` | `TypeAlias` annotation |
| 3.12+ | `class Box[T]: ...` | classic `TypeVar` + `Generic[T]` |

**Why:** Each new form removes ceremony
and (for PEP 604 / PEP 695) is treated as the canonical syntax by current tooling.
**Defer to section 13**.
Never propose a form newer than what the project's `python_requires` admits.

## 13. Version awareness

**Rule:** Before proposing any version-gated form (sections 5 and 6, python-io.md section 8),
read the project's declared Python version:

- `pyproject.toml` `[project] requires-python`: the source of truth.
- `[tool.ruff] target-version`: what ruff lints against.
- `[tool.ty.environment] python-version` or `[tool.mypy] python_version`:
  what the type checker assumes.

If the declared floor is `>=3.10`,
do not propose `Self`, PEP 695 generic syntax, or `tomllib`.
If the declared floor is `>=3.12`,
all forms in section 6 are admissible.
**Why:** Code written against a version newer than the project's floor
breaks for at least one declared platform.
The cost of checking the declaration once is far smaller
than a CI failure on a downstream Python version.
**When the declaration is absent:** assume the oldest currently-supported CPython per python.org status,
and surface the absence as a clarifying question to the user
before proposing modern syntax.

## 14. Standard library import location map

**Rule:** Before importing a symbol that may be version-gated,
verify the import location matches the project's declared Python version (section 13).
Several names moved between `typing_extensions`, third-party backports, and the stdlib across recent versions;
using the wrong path either fails at runtime on the project's floor
or carries an unnecessary dependency.
**Why:** The same symbol can exist in two locations during a transition window
(e.g., `Self` lives in both `typing_extensions` and `typing` on 3.11+).
Importing from the wrong location either breaks the build on the project's declared floor
(`Self` is unimportable from `typing` on 3.10)
or carries a dead third-party dependency on 3.11+.
Listing the canonical location per version removes the guesswork.

### Added to stdlib in 3.11 / 3.12

| Symbol | Stdlib import | Pre-stdlib alternative |
|---|---|---|
| `tomllib` (module, read-only) | `tomllib` (3.11+) | third-party `tomli` |
| `Self` | `typing` (3.11+) | `typing_extensions` |
| `LiteralString` | `typing` (3.11+) | `typing_extensions` |
| `assert_type`, `assert_never` | `typing` (3.11+) | `typing_extensions` |
| `Never`, `NotRequired`, `Required` | `typing` (3.11+) | `typing_extensions` |
| `StrEnum`, `ReprEnum` | `enum` (3.11+) | not previously available |
| `override` | `typing` (3.12+) | `typing_extensions` |
| `Buffer` protocol | `collections.abc` (3.12+) | `typing_extensions` |

### Removed in 3.12 (do not import on 3.12+)

| Module | Replacement |
|---|---|
| `distutils` | `setuptools` (third-party) or `packaging` |
| `asyncore`, `asynchat`, `smtpd` | `asyncio` |
| `imp` | `importlib` |

### Relocated within stdlib

| Old | New | Since |
|---|---|---|
| `pkg_resources` (`setuptools`) | `importlib.metadata` | 3.8 |
| Ad-hoc `__file__` resource lookup | `importlib.resources` (`files()` API) | 3.9 |

**Backport convention:** when supporting Python versions older than the stdlib introduction year,
import from `typing_extensions` (for typing symbols)
or the third-party backport (`tomli` for TOML read).
A single project should consistently use either the stdlib or the backport gated on section 13,
not both.
