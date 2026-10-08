# Python language reference

Python-specific conventions for the `coding` skill.
Layered on top of `architecture.md` (12 generic rules).
When both apply, this file refines or specializes the generic rule.
Never contradict.

Apply with version awareness:
section 13 governs which constructs are admissible based on the project's declared Python version.
Always read that section before proposing modern syntax.

## Where each section lives

This file holds sections 1, 2, 4, and 9.

- shared/reference/python-types.md (sections 5, 6, 13, and 14): read it now as well.
- shared/reference/python-idioms.md (sections 7, 10, 11, and 12): read it now as well.
- shared/reference/python-tools.md (sections 3, 15, and 16): read it when you pick a checker,
  write or review tests, or manage dependencies.
- shared/reference/python-io.md (sections 8, 17, and 20): read it when the code is async,
  runs a child process, or waits on a network peer, a lock, a queue, or a thread.
- shared/reference/python-entry-point.md (sections 18 and 21): read it when the code has a program's entry point,
  logs, or shows progress.
- shared/reference/python-progress.md (section 19): read it when the code shows progress over many items.

"section N" in any of these files means the section with that number;
this list names the file that holds it.

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
