# Testing worked example

A canonical test file: good tests for correct code.
The tests demonstrate the criteria in shared/reference/testing.md.
Shown first is the function under test, then its pytest suite.

## Function under test

`order.py`:

```python
def order_total_cents(quantities: list[int], unit_cents: int) -> int:
    """Return the total price in cents.

    Args:
        quantities: per-line quantities; each must be >= 0.
        unit_cents: price per unit in cents; must be >= 0.

    Raises:
        ValueError: if unit_cents or any quantity is negative.
    """
    if unit_cents < 0:
        raise ValueError("unit_cents must not be negative")
    total = 0
    for quantity in quantities:
        if quantity < 0:
            raise ValueError("quantity must not be negative")
        total += quantity * unit_cents
    return total
```

## The tests

`test_order.py`:

```python
import pytest

from order import order_total_cents


def test_empty_quantities_returns_zero():
    assert order_total_cents([], 500) == 0


def test_single_line():
    assert order_total_cents([3], 500) == 1500


def test_multiple_lines_sum():
    assert order_total_cents([1, 2, 3], 100) == 600


def test_zero_unit_price_is_allowed():
    assert order_total_cents([4], 0) == 0


def test_negative_quantity_raises():
    with pytest.raises(ValueError, match="quantity"):
        order_total_cents([1, -1], 500)


def test_negative_unit_price_raises():
    with pytest.raises(ValueError, match="unit_cents"):
        order_total_cents([1], -1)
```

## Why these tests

- Behavior coverage: empty, single, multiple, and the zero-price boundary.
- Error paths: both ValueError conditions in the contract are triggered.
- Meaningful assertions: each asserts the exact result, or the exact error.
- Determinism and independence: no clock, randomness, or shared state;
  each test stands alone.
- Clear intent: each name states the behavior, so a failure names what broke.

Run with: `pytest test_order.py`
