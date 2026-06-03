# Python worked examples

Worked examples demonstrating the rules in `shared/reference/python.md`.
The shared domain is a small order-management system;
each block is a fragment of that system illustrating two or three rules.
Cross-references in the prose point to the corresponding `shared/reference/python.md` section.

Code in these blocks contains only natural comments
(the kind a real developer writes for non-obvious WHY).
Instructional / meta comments belong in this prose, never in the code.

## 1. Domain types and exceptions

This block demonstrates shared/reference/python.md section 2 (docstrings),
section 5 (type annotations), and section 10 (domain exceptions).

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
(reference section 10).
The combination of `@dataclass(frozen=True)` and `tuple[str, ...]` keeps `CustomerOrder` immutable;
the Python realization of `shared/reference/architecture.md` section 3
(immutability where the language supports it cheaply).
Modern `tuple[str, ...]` syntax requires Python 3.9+ (reference section 5).

## 2. Persistence with validation

This block demonstrates shared/reference/python.md section 7 (mutable default argument trap)
and section 12 (validation at boundaries).

```python
"""Order persistence layer.

Stores customer orders in memory. The public entry point validates
raw input via Pydantic; internal helpers receive typed objects and
trust them.
"""

from pydantic import BaseModel, Field

from .models import CustomerOrder, CustomerOrderNotFoundError


class CreateCustomerOrderRequest(BaseModel):
    """Validated payload for creating a customer order.

    Pydantic raises `ValidationError` on shape mismatch; downstream
    code receives a typed instance and trusts the fields.
    """

    customer_id: int
    total_cents: int = Field(gt=0)
    sku_ids: tuple[str, ...] = Field(min_length=1)


class CustomerOrderRepository:
    """In-memory persistence for `CustomerOrder` records.

    Args:
        initial: Pre-seeded orders keyed by `id`; defaults to empty.
    """

    def __init__(
        self,
        initial: dict[int, CustomerOrder] | None = None,
    ) -> None:
        # Defensive copy: the caller's dict must not alias the store.
        self._store: dict[int, CustomerOrder] = (
            dict(initial) if initial else {}
        )

    def create(self, request: CreateCustomerOrderRequest) -> CustomerOrder:
        next_id = max(self._store, default=0) + 1
        order = CustomerOrder(
            id=next_id,
            customer_id=request.customer_id,
            total_cents=request.total_cents,
            sku_ids=request.sku_ids,
        )
        self._store[next_id] = order
        return order

    def fetch(self, order_id: int) -> CustomerOrder:
        try:
            return self._store[order_id]
        except KeyError as exc:
            raise CustomerOrderNotFoundError(
                f"customer order {order_id}"
            ) from exc
```

`CustomerOrderRepository.__init__` uses `None` as the sentinel for `initial`
instead of a mutable default like `{}` (reference section 7).
The `dict(initial)` call is a defensive copy;
without it, the caller could later mutate their original dict
and silently change the repository's internal state.

`CreateCustomerOrderRequest` is the validation boundary (reference section 12):
Pydantic v2 parses the raw payload and raises `ValidationError` on shape mismatch
(negative `total_cents`, empty `sku_ids`, wrong types, ...).
Downstream methods (`create`, `fetch`) accept already-typed parameters and do not re-validate.

`fetch` re-raises `KeyError` as `CustomerOrderNotFoundError` using exception chaining (`from exc`),
preserving the original cause for debugging (reference section 10 + `shared/reference/architecture.md` section 5).

## 3. Async fetching

This block demonstrates shared/reference/python.md section 8 (async hygiene),
section 11 (Pythonic patterns: generator expressions, `zip`),
and section 12 (validation at boundaries) applied to external responses.

```python
"""Async order adapter.

Fetches customer orders from an external HTTP service. All I/O is
async; blocking operations (synchronous `open`, `requests.get`,
`time.sleep`) are forbidden inside async functions because they
freeze the event loop.
"""

import asyncio

import httpx
from pydantic import BaseModel

from .models import CustomerOrder, CustomerOrderNotFoundError


class _OrderResponse(BaseModel):
    """Validated JSON shape for the `/orders/{id}` endpoint."""

    id: int
    customer_id: int
    total_cents: int
    sku_ids: list[str]


async def fetch_orders(
    client: httpx.AsyncClient,
    order_ids: tuple[int, ...],
) -> list[CustomerOrder]:
    """Fetch multiple customer orders concurrently.

    Args:
        client: An open `httpx.AsyncClient` session reused across calls.
        order_ids: Order IDs to fetch.

    Returns:
        Orders in the same order as `order_ids`.

    Raises:
        CustomerOrderNotFoundError: If any requested ID is missing.
        ValidationError: If a response payload has the wrong shape.
    """
    responses = await asyncio.gather(
        *(client.get(f"/orders/{oid}") for oid in order_ids)
    )
    orders: list[CustomerOrder] = []
    for oid, response in zip(order_ids, responses):
        if response.status_code == 404:
            raise CustomerOrderNotFoundError(f"customer order {oid}")
        response.raise_for_status()
        payload = _OrderResponse.model_validate(response.json())
        orders.append(
            CustomerOrder(
                id=payload.id,
                customer_id=payload.customer_id,
                total_cents=payload.total_cents,
                sku_ids=tuple(payload.sku_ids),
            )
        )
    return orders
```

`fetch_orders` is `async def`;
every I/O call inside (`client.get`) is itself awaitable,
so the event loop is never blocked (reference section 8).
`asyncio.gather` with a generator expression
(`(client.get(f"/orders/{oid}") for oid in order_ids)`)
issues all requests concurrently without building an intermediate list.

`zip(order_ids, responses)` pairs each requested ID with its response without manual indexing
(reference section 11).
The 404 case is checked explicitly before `raise_for_status`,
which surfaces any other HTTP failure as `httpx.HTTPStatusError`.

`_OrderResponse` is the boundary validator (reference section 12).
The leading underscore marks it as module-private (reference section 4);
external callers do not need this intermediate type.
`model_validate` raises `ValidationError` when the HTTP payload diverges from the declared shape,
surfacing API contract drift early
instead of propagating wrong data into typed `CustomerOrder` instances.

`tuple(payload.sku_ids)` converts the Pydantic list field to a `tuple` matching `CustomerOrder.sku_ids`,
preserving the frozen-dataclass contract.

## 4. CLI entry with config loading

This block demonstrates shared/reference/python.md section 13 (version awareness)
and section 14 (standard library import location map),
with reinforcement of section 12 (validation at boundaries).

```python
"""Command-line entry point for the order service.

Loads structured configuration from a TOML file via
`ServiceConfig.load`, then dispatches subcommands.
"""

import argparse
import sys
import tomllib
from pathlib import Path
from typing import Self

from pydantic import BaseModel


class ServiceConfig(BaseModel):
    """Validated service configuration.

    Loaded from the `[service]` table of a TOML file. Pydantic
    raises `ValidationError` on shape mismatch.
    """

    endpoint: str
    timeout_seconds: int
    log_level: str

    @classmethod
    def load(cls, path: Path) -> Self:
        """Read and validate configuration from a TOML file.

        Args:
            path: Path to the TOML configuration file.

        Returns:
            Validated `ServiceConfig` instance.

        Raises:
            FileNotFoundError: If `path` does not exist.
            KeyError: If the `[service]` table is missing.
            ValidationError: If the table has the wrong shape.
        """
        with path.open("rb") as fh:
            document = tomllib.load(fh)
        return cls.model_validate(document["service"])


def main(argv: list[str] | None = None) -> int:
    """Parse arguments and dispatch the requested subcommand.

    Returns:
        Process exit code: 0 on success, non-zero on user error.
    """
    parser = argparse.ArgumentParser(prog="orders")
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("orders.toml"),
        help="Path to the configuration TOML.",
    )
    args = parser.parse_args(argv)
    config = ServiceConfig.load(args.config)
    print(f"connected to {config.endpoint}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

`ServiceConfig` is a Pydantic model that captures the shape of the `[service]` TOML table.
The classmethod `load` is an alternate constructor:
it reads the file, then calls `cls.model_validate` to convert the raw dict into a typed `ServiceConfig`.
Callers read `config.endpoint`, not `config["endpoint"]` (reference section 12).

Colocating the loader with the type via `@classmethod` keeps construction logic next to the data shape;
a free-standing `load_config(path) -> ServiceConfig` would put the same logic in a separate module
and force readers to discover it.
The classmethod form also propagates correctly to subclasses through `Self`.

`Self` (from `typing`, Python 3.11+) annotates the classmethod return as "the enclosing class".
A subclass's `.load()` returns a subclass instance without changing the annotation
(reference section 14, `Self` row).

Both `tomllib` and `Self` require Python 3.11+.
On older versions the imports become `import tomli as tomllib` and `from typing_extensions import Self`
(reference section 13 gating; reference section 14 backport convention).

`with path.open("rb")` opens the file in binary mode because `tomllib.load` requires bytes.
`argv: list[str] | None = None` uses PEP 604 union with a `None` sentinel;
passing `None` defers to `argparse`'s default of reading `sys.argv` (reference sections 5 and 7).

## 5. Project layout

This block demonstrates shared/reference/python.md section 4 (naming)
and section 9 (module structure).

```
orders/
├── __init__.py
├── __main__.py
├── models.py
├── core.py
├── adapters.py
└── cli.py

tests/
├── test_models.py
├── test_core.py
├── test_adapters.py
└── test_cli.py
```

Each module holds one concern (reference section 9):

- `__init__.py` is typically empty (when callers import from concrete submodules)
  or re-exports the public API (e.g., `from .models import CustomerOrder`).
- `models.py` carries pure data classes and exception types; no I/O.
  Holds Example 1's `CustomerOrder`, `CustomerOrderNotFoundError`, `InsufficientStockError`.
- `core.py` carries business logic and persistence orchestration.
  Validates input at its boundary, calls models.
  Holds Example 2's `CreateCustomerOrderRequest` and `CustomerOrderRepository`.
- `adapters.py` carries side-effectful I/O (network, disk, DB).
  The only place where a synchronous-in-async-context bug would appear.
  Holds Example 3's `fetch_orders`.
- `cli.py` is the user-facing entry surface: argument parsing, config loading, dispatch.
  Holds Example 4's `ServiceConfig` and `main`.
- `__main__.py` is the smallest possible launcher (`sys.exit(cli.main())`),
  enabling `python -m orders` without duplicating code.

`tests/` mirrors the source layout:
one test module per source module, named with the `test_` prefix expected by `pytest`.

All module names are `snake_case`, all class names are `PascalCase` (reference section 4).
No module is named `io.py`,
which would shadow the stdlib `io` module inside the package (reference section 9).

## Pitfalls

Common mistakes that the rules in `shared/reference/python.md` are designed to prevent.
Each is a real bug class that ships when the rule is forgotten.

- **Forgetting `await` on an async call.**
  `client.get(url)` returns a coroutine, not a response.
  Without `await`, the caller silently gets a coroutine where it expected the value,
  and the request never actually fires (reference section 8).
- **Comparing to `None` with `==` instead of `is`.**
  Use `x is None` and `x is not None`.
  The `==` form invokes `__eq__` and can return surprising results on custom types;
  `is` checks identity, which is exactly what `None` semantics require (reference section 11 idiom).
- **Catching `Exception` at non-top-level functions.**
  Broad catches hide bugs that should propagate.
  Reserve them for entry points (request handlers, CLI main, message consumers);
  catch narrower types everywhere else (reference section 10, `shared/reference/architecture.md` section 5).
- **Mutable default arguments.**
  A list, dict, or set used as a default value is shared across every call.
  Use `None` as the default and initialize inside the body.
  This is the most common silent leak in Python; `ruff B006` catches it (reference section 7).
- **Implicit `None` returns where the annotation is not `Optional`.**
  A function annotated `-> User` that returns `None` on the not-found path lies to its caller.
  Either change the return to `User | None`, or raise a domain exception (reference section 10).
- **Reading TOML without binary mode.**
  Without `"rb"`, `tomllib.load` raises `TypeError`: the loader requires bytes, not a text stream.
  Use `Path.open("rb")` (Example 4 demonstrates the correct form).
- **`print` inside library code.**
  `print` writes to stdout and cannot be filtered, redirected, or silenced per-module.
  Use `logging.getLogger(__name__)` for library output;
  reserve `print` for the CLI entry layer that explicitly owns stdout
  (Example 4 is the place where `print` is appropriate).
