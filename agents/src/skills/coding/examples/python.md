# Python worked examples

Worked examples demonstrating the rules in `shared/reference/python.md` and the files it lists.
The shared domain is a small order-management system;
each block is a fragment of that system illustrating two or three rules.
Cross-references in the prose point to the corresponding `shared/reference/python.md` section
unless they name another reference file.

Code in these blocks contains only natural comments
(the kind a real developer writes for non-obvious WHY).
Instructional / meta comments belong in this prose, never in the code.

## Where each example lives

- examples/python-persistence.md (Example 2): read it when the code stores records,
  validates input at a boundary, or defines a class that takes arguments in `__init__`.
- examples/python-async.md (Example 3): read it when the code is async or calls an HTTP service.
- examples/python-cli.md (Examples 4 and 5): read it when you write a command-line entry point,
  load a config file, or lay out a new package.

Compare your code against every file you read.

## 1. Domain types and exceptions

This block demonstrates shared/reference/python.md section 2 (docstrings),
python-types.md section 5 (type annotations), and python-idioms.md section 10 (domain exceptions).

```python
"""Order domain types and exceptions.

Defines the core data structures and exception hierarchy used
throughout the order management system.
"""

from dataclasses import dataclass


class CustomerOrderNotFoundError(LookupError):
    """Raised when a customer order ID does not resolve to a row."""


class InsufficientStockError(ValueError):
    """Raised when requested quantity exceeds available stock."""


@dataclass(frozen=True)
class CustomerOrder:
    """An order placed by a customer.

    Args:
        id: Unique identifier assigned at creation.
        customer_id: Owner of the order.
        total_cents: Total charge in the currency's minor unit.
        sku_ids: Stock-keeping-unit identifiers; tuple keeps
            `CustomerOrder` immutable.
    """

    id: int
    customer_id: int
    total_cents: int
    sku_ids: tuple[str, ...]
```

`CustomerOrderNotFoundError` subclasses `LookupError`,
so callers can catch it via `except LookupError:` alongside stdlib lookup failures
(python-idioms.md section 10).
The combination of `@dataclass(frozen=True)` and `tuple[str, ...]` keeps `CustomerOrder` immutable;
the Python realization of `shared/reference/architecture.md` section 3
(immutability where the language supports it cheaply).
Modern `tuple[str, ...]` syntax requires Python 3.9+ (python-types.md section 5).

## Pitfalls

Common mistakes that the rules in `shared/reference/python.md` and the files it lists are designed to prevent.
Each is a real bug class that ships when the rule is forgotten.

- **Forgetting `await` on an async call.**
  `client.get(url)` returns a coroutine, not a response.
  Without `await`, the caller silently gets a coroutine where it expected the value,
  and the request never actually fires (python-io.md section 8).
- **Comparing to `None` with `==` instead of `is`.**
  Use `x is None` and `x is not None`.
  The `==` form invokes `__eq__` and can return surprising results on custom types;
  `is` checks identity, which is exactly what `None` semantics require (python-idioms.md section 11 idiom).
- **Catching `Exception` at non-top-level functions.**
  Broad catches hide bugs that should propagate.
  Reserve them for entry points (request handlers, CLI main, message consumers);
  catch narrower types everywhere else (python-idioms.md section 10, `shared/reference/architecture.md` section 5).
- **Mutable default arguments.**
  A list, dict, or set used as a default value is shared across every call.
  Use `None` as the default and initialize inside the body.
  This is the most common silent leak in Python; `ruff B006` catches it (python-idioms.md section 7).
- **Implicit `None` returns where the annotation is not `Optional`.**
  A function annotated `-> User` that returns `None` on the not-found path lies to its caller.
  Either change the return to `User | None`, or raise a domain exception (python-idioms.md section 10).
- **Reading TOML without binary mode.**
  Without `"rb"`, `tomllib.load` raises `TypeError`: the loader requires bytes, not a text stream.
  Use `Path.open("rb")` (Example 4 in examples/python-cli.md demonstrates the correct form).
- **`print` inside library code.**
  `print` writes to stdout and cannot be filtered, redirected, or silenced per-module.
  Use `logging.getLogger(__name__)` for library output;
  reserve `print` for the CLI entry layer that explicitly owns stdout
  (Example 4 in examples/python-cli.md is the place where `print` is appropriate).
