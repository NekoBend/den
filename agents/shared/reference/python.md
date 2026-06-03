# Python language reference

Python-specific conventions for the `coding` skill.
Layered on top of `architecture.md` (12 generic rules).
When both apply, this file refines or specializes the generic rule.
Never contradict.

Apply with version awareness:
section 13 governs which constructs are admissible based on the project's declared Python version.
Always read that section before proposing modern syntax.

## 1. Style guide: PEP 8 + Google Python Style Guide

**Rule:** Follow PEP 8 as the baseline.
Layer the Google Python Style Guide on top for module-level conventions
(docstring sections, import grouping, naming defaults).
**Why:** PEP 8 covers syntax-level layout.
Google adds module-level conventions that PEP 8 leaves unspecified.
This combination is the standard this skill applies;
teams with their own style guide override via project config (see section 3).

## 2. Docstrings: Google style, imperative summary

**Rule:** Every public function, class, method, and module gets a Google-style docstring.
Summary line is imperative
(`Parse the version...`, not `Parses the version...`) and ≤ 1 sentence.
Use `Args:` / `Returns:` / `Raises:` / `Yields:` sections
only when the signature alone is not self-evident.
Document `__init__` parameters inside the class docstring,
not in `__init__` itself.
**Why:** PEP 257 + Google style produce uniform output
that ruff and IDE tooling both parse correctly.
Documenting `__init__` at the class level matches how readers approach the class.
**Example:**

```python
class CustomerOrderRepository:
    """Persistence layer for customer orders.

    Args:
        session: An open SQLAlchemy session.
    """

    def __init__(self, session: Session) -> None:
        self.session = session

    def fetch(self, order_id: int) -> CustomerOrder:
        """Return the customer order with `order_id`.

        Raises:
            CustomerOrderNotFoundError: If no row matches.
        """
```

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

## 4. Naming

**Rule:**

- Functions, methods, variables, modules: `snake_case`.
- Classes, type aliases, type variables: `PascalCase`.
- Module-level constants: `UPPER_SNAKE`.
- Single leading underscore (`_helper`): module- or class-private by convention;
  tools don't enforce it, readers respect it.
- Double leading underscore (`__name`) inside a class: triggers name mangling.
  Reserved for genuine conflict avoidance, not "really private".
- Dunder (`__name__`): reserved for Python; do not define your own.

**Why:** Mismatches make grep harder and signal intent to readers.
ruff flags PEP 8 naming violations under the `N` ruleset.
**Example:**

```python
MAX_RETRIES = 5

class CustomerOrderRepository: ...

def fetch_customer_order(order_id: int) -> CustomerOrder: ...
```

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

## 7. Mutable default argument trap

**Rule:** Never use a mutable object
(`list`, `dict`, `set`, instance) as a default argument value.
Default expressions are evaluated **once at function-definition time**
and shared across every subsequent call,
so a list default leaks state silently between invocations.
Use `None` as the sentinel and construct the real value inside the body.
**Why:** The bug is silent.
Code looks correct on first read,
and unit tests in isolation pass.
The leak surfaces only under repeated invocation, often in production.
ruff's flake8-bugbear `B006` flags this automatically.
**Example:**

```python
def append_id(ids: list[int] | None = None) -> list[int]:
    if ids is None:
        ids = []
    ids.append(1)
    return ids
```

## 8. Async hygiene

**Rule:** Inside `async def`,
only call functions that are themselves async or known to be non-blocking.
Replace blocking stdlib / library calls with their async counterparts:

- `asyncio.sleep` instead of `time.sleep`.
- `httpx.AsyncClient` (or `aiohttp`) instead of `requests`.
- `aiofiles` instead of synchronous `open` for non-trivial file I/O.
- `asyncio.to_thread` (3.9+) to delegate genuinely blocking work to a thread pool
  when no async equivalent exists;
  on older Python, use `asyncio.get_running_loop().run_in_executor(None, func, *args)`.

**Why:** A single blocking call freezes the event loop
and stalls every other coroutine waiting on it.
This collapses async throughput to worse than synchronous.
**Example:**

```python
async def fetch_all(urls: list[str]) -> list[bytes]:
    async with httpx.AsyncClient() as client:
        responses = await asyncio.gather(*(client.get(u) for u in urls))
    return [r.content for r in responses]
```

## 9. Module structure

**Rule:** Split a module when it crosses any of these thresholds:

- ≥ 3 top-level classes, or
- ≥ 200 lines of executable code, or
- mixes I/O (network, disk, DB) and pure logic in the same file.

Typical split: `models.py` (data classes, types), `core.py` (business logic),
`utils.py` (pure helpers), `adapters.py` (I/O: network, disk, DB).
Avoid naming a project module `io.py`:
it shadows the stdlib `io` module inside the package.
**Why:** Smaller, intention-named files diff more cleanly,
are easier to hold in working memory,
and discourage hidden cross-coupling.
The threshold is a heuristic:
apply when the file becomes hard to navigate, not blindly at 199 lines.
**When over:** Identify the densest dependency edge
(e.g., "every function imports `db.session`") and extract that subsystem first.

## 10. Domain exceptions

**Rule:** Define a domain-specific exception class
subclassing the most appropriate stdlib base
(`LookupError`, `ValueError`, `RuntimeError`, `OSError`, ...).
Raise these for business errors instead of bare `ValueError` / `RuntimeError`.
**Why:** Subclassing the right stdlib base lets callers `except LookupError:`
and catch your domain error alongside stdlib ones;
the domain class name documents what failed
without forcing the reader to parse the message string.
**Cross-ref:** architecture.md section 5 (catch narrow, propagate broad)
covers the generic rule.
This section adds the Python-specific stdlib hierarchy to subclass against.
**Example:**

```python
class CustomerOrderNotFoundError(LookupError):
    """Raised when a customer order ID does not resolve to a row."""


def fetch_customer_order(order_id: int) -> CustomerOrder:
    try:
        return _repository[order_id]
    except KeyError as exc:
        raise CustomerOrderNotFoundError(f"customer order {order_id}") from exc
```

## 11. Pythonic patterns

**Rule:** Prefer the language-native idiom over a manual equivalent
when the idiom is well-known to Python readers:

- **Comprehensions** for transforming an iterable into a list / dict / set / generator.
  Limit to one filter and one map per comprehension.
  Nested comprehensions become unreadable past two levels.
- **Context managers** (`with`) for any resource that requires cleanup
  (file, lock, transaction, temporary directory).
- **`pathlib.Path`** instead of `os.path` / `os` string manipulation.
- **`enumerate`** instead of `range(len(...))` when you need the index.
- **`zip`** instead of parallel indexing into two iterables.
- **EAFP** (`try` / `except`) over **LBYL** (`hasattr` + conditional)
  when the success case is the common one.
- **f-strings** for interpolation;
  reserve `%` / `.format()` for legacy code and logging format strings.
- **`dict.get(key, default)`** instead of `key in d` + lookup.
- **`is` / `is not`** for identity checks against `None`, `True`, `False`
  (`x is None`, never `x == None`):
  `==` invokes `__eq__` and can give surprising results on custom types.

**Why:** See architecture.md section 12 (Idiomatic over portable).
Python's idioms are widely-known shorthand;
rewriting them in long form makes readers spend cycles on syntax rather than logic.
**Example:**

```python
log_files = [p for p in Path("logs").iterdir() if p.suffix == ".log"]
for index, path in enumerate(log_files):
    print(f"[{index}] {path.name}")
```

## 12. Validation at boundaries

**Rule:** Concentrate input validation at public API entry points
and external-data deserialization points.
Internal helpers trust their typed inputs.
Use:

- **Pydantic v2** for structured deserialization (HTTP bodies, JSON files, config files).
  Generates field-level error messages
  and converts raw `dict` to a typed model in one step.
- **`isinstance` checks** at narrower boundaries
  when the input is genuinely `unknown` and Pydantic would be overkill
  (e.g., a single callback parameter).

Do not re-validate the same data after the boundary.
After the model is constructed, downstream code reads attributes directly.
**Why:** See architecture.md section 9 (Validate at boundaries, trust internals).
Repeated validation duplicates logic
and creates places where the rule can drift between layers.
**Example:**

```python
class CreateCustomerOrderRequest(BaseModel):
    customer_id: int
    sku_ids: list[str]


def create_customer_order_endpoint(payload: dict) -> Response:
    request = CreateCustomerOrderRequest.model_validate(payload)  # boundary
    return _create_customer_order(request)                         # trust the type


def _create_customer_order(request: CreateCustomerOrderRequest) -> Response:
    # No re-checking of request.customer_id or request.sku_ids.
    ...
```

## 13. Version awareness

**Rule:** Before proposing any version-gated form (sections 5, 6, 8),
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
