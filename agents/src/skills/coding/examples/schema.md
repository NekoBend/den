# Schema design worked example

A canonical schema: a typed, validated model for the order domain.
It demonstrates the methodology in shared/reference/schema-design.md.
The form here is language types with boundary validation (Pydantic v2),
chosen because the schema is an in-process contract
that also validates external input.
Notes below show how the same model maps to SQL DDL.

## The schema

`models.py`:

```python
from pydantic import BaseModel, ConfigDict, Field


class LineItem(BaseModel):
    """One line of an order: a product and how many units."""

    model_config = ConfigDict(frozen=True)

    sku: str = Field(min_length=1)
    quantity: int = Field(gt=0)


class CustomerOrder(BaseModel):
    """A customer's order. Validated at the system boundary."""

    model_config = ConfigDict(frozen=True)

    id: int
    customer_id: int
    line_items: tuple[LineItem, ...] = Field(min_length=1)
    note: str | None = None
```

Validate external input at the boundary:

```python
order = CustomerOrder.model_validate(raw_payload)  # raises on a bad shape
```

## Why this shape

- Identity: `id` and `customer_id` are required keys.
- Required vs optional: `line_items` is required with at least one entry
  (`min_length=1`); `note` is explicitly optional (`str | None = None`).
- Domain constraints: `quantity` must be positive (`gt=0`),
  `sku` must be non-empty (`min_length=1`).
- Immutability: `frozen=True` makes a validated order safe to share.
- Boundary validation: `model_validate` enforces the schema on raw input;
  trusted code downstream receives a valid `CustomerOrder`.

## Mapping to SQL DDL (if persisted)

The same model as relational tables carries the constraints in DDL:

- `customer_order(id PRIMARY KEY,
  customer_id NOT NULL REFERENCES customer(id))`
- `line_item(order_id NOT NULL REFERENCES customer_order(id),
  sku NOT NULL, quantity INTEGER NOT NULL CHECK (quantity > 0))`
- a uniqueness rule such as `UNIQUE(order_id, sku)` to forbid duplicate lines.

## Evolution

Add new fields as OPTIONAL (as `note` was added) so existing payloads still
validate. A breaking change (renaming `sku`, or requiring a new field) needs a
version bump or a migration.
