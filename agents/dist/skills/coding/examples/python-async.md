# Python worked examples: async

Example 3 of the Python worked examples: fetching customer orders concurrently over HTTP.

## 3. Async fetching

This block demonstrates shared/reference/python-io.md section 8 (async hygiene),
python-idioms.md section 11 (Pythonic patterns: generator expressions, `zip`),
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
so the event loop is never blocked (python-io.md section 8).
`asyncio.gather` with a generator expression
(`(client.get(f"/orders/{oid}") for oid in order_ids)`)
issues all requests concurrently without building an intermediate list.

`zip(order_ids, responses)` pairs each requested ID with its response without manual indexing
(python-idioms.md section 11).
The 404 case is checked explicitly before `raise_for_status`,
which surfaces any other HTTP failure as `httpx.HTTPStatusError`.

`_OrderResponse` is the boundary validator (python-idioms.md section 12).
The leading underscore marks it as module-private (reference section 4);
external callers do not need this intermediate type.
`model_validate` raises `ValidationError` when the HTTP payload diverges from the declared shape,
surfacing API contract drift early
instead of propagating wrong data into typed `CustomerOrder` instances.

`tuple(payload.sku_ids)` converts the Pydantic list field to a `tuple` matching `CustomerOrder.sku_ids`,
preserving the frozen-dataclass contract.
