# Python reference: correctness idioms

Sections 7, 10, 11, and 12 of the Python reference:
mutable defaults, domain exceptions, Pythonic patterns, and validation at boundaries.
shared/reference/python.md lists where every section lives.

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
    return _create_customer_order(request)  # trust the type


def _create_customer_order(request: CreateCustomerOrderRequest) -> Response:
    # No re-checking of request.customer_id or request.sku_ids.
    ...
```
