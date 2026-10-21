# Python worked examples: CLI and layout

Examples 4 and 5 of the Python worked examples:
a command-line entry point that loads a TOML config, and the package layout.

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
