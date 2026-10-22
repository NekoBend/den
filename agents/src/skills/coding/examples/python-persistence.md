# Python worked examples: persistence

Example 2 of the Python worked examples: a repository behind a validated request model.

## 2. Persistence with validation

This block demonstrates shared/reference/python-idioms.md section 7 (mutable default argument trap)
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
        self._store: dict[int, CustomerOrder] = dict(initial) if initial else {}

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
            raise CustomerOrderNotFoundError(f"customer order {order_id}") from exc
```

`CustomerOrderRepository.__init__` uses `None` as the sentinel for `initial`
instead of a mutable default like `{}` (python-idioms.md section 7).
The `dict(initial)` call is a defensive copy;
without it, the caller could later mutate their original dict
and silently change the repository's internal state.

`CreateCustomerOrderRequest` is the validation boundary (python-idioms.md section 12):
Pydantic v2 parses the raw payload and raises `ValidationError` on shape mismatch
(negative `total_cents`, empty `sku_ids`, wrong types, ...).
Downstream methods (`create`, `fetch`) accept already-typed parameters and do not re-validate.

`fetch` re-raises `KeyError` as `CustomerOrderNotFoundError` using exception chaining (`from exc`),
preserving the original cause for debugging (python-idioms.md section 10 + `shared/reference/architecture.md` section 5).
