"""mpire Progress Bars - Copy-Paste Cheatsheet.

CPU-bound work with mpire: faster than the stdlib pools (shared objects, fork,
worker state) and a progress bar that is one keyword argument away.

| Function       | Best for                                   | Failures    |
|----------------|--------------------------------------------|-------------|
| run_mpire      | CPU-bound, max throughput (tqdm bar)       | raise first |
| run_mpire_rich | CPU-bound, max throughput (rich bar)       | raise first |
| run_mpire_lazy | mpire over a lazy iterable, finish order   | raise first |

Usage:
    1. Copy the function you need (its imports travel with it).
    2. Call it with your own TOP-LEVEL ``func`` (mpire pickles it like the
       stdlib pools do; under ``fork`` a closure happens to work, under
       ``spawn`` it does not).

Dependencies:
    pip install mpire rich

Note:
    - mpire raises the first worker exception in the parent and stops the
      pool. For per-item failures kept as data, wrap ``func`` so it returns
      the exception (see ``processes._apply_block``).
    - Results of ``map`` keep input order; ``imap_unordered`` streams in
      finish order.
"""

from collections.abc import Callable, Iterable, Sequence

# =============================================================================
# 1. map with a built-in bar
# =============================================================================


def run_mpire[T, R](
    items: Sequence[T], func: Callable[[T], R], max_workers: int = 4
) -> list[R]:
    """Run ``func`` on an mpire pool with its built-in tqdm bar.

    [Best for] Heavy CPU work that should go as fast as the machine allows.
    [Note] ``progress_bar_options`` takes tqdm keyword arguments.
    """
    from mpire import WorkerPool

    with WorkerPool(n_jobs=max_workers) as pool:
        return pool.map(
            func, items, progress_bar=True, progress_bar_options={"desc": "mpire"}
        )


def run_mpire_rich[T, R](
    items: Sequence[T], func: Callable[[T], R], max_workers: int = 4
) -> list[R]:
    """Run ``func`` on an mpire pool with its built-in bar in rich style.

    [Best for] The same run with a rich-rendered bar and no rich code.
    [Note] ``progress_bar_style="rich"`` (mpire >= 2.7) renders through
           ``tqdm.rich``; the options are still tqdm's.
    """
    from mpire import WorkerPool

    with WorkerPool(n_jobs=max_workers) as pool:
        return pool.map(
            func,
            items,
            progress_bar=True,
            progress_bar_style="rich",
            progress_bar_options={"desc": "mpire (rich)"},
        )


# =============================================================================
# 2. Lazy input, streaming output
# =============================================================================


def run_mpire_lazy[T, R](
    items: Iterable[T], func: Callable[[T], R], total: int, max_workers: int = 4
) -> list[R]:
    """Run ``func`` over a lazy iterable with ``imap_unordered`` and a bar.

    [Best for] Generators (cursor, file lines) where the whole input should
               not be materialised first.
    [Note] mpire needs ``iterable_len`` to size the bar and split chunks
           when the input has no ``len()``. Results arrive in finish order.
    """
    from mpire import WorkerPool

    with WorkerPool(n_jobs=max_workers) as pool:
        return list(
            pool.imap_unordered(
                func,
                items,
                iterable_len=total,
                progress_bar=True,
                progress_bar_options={"desc": "mpire (lazy)"},
            )
        )


# =============================================================================
# Quick Sanity Check
# =============================================================================


def _demo_task(item: int) -> int:
    """Dummy CPU work: sleep briefly and double the item."""
    import time

    time.sleep(0.02)
    return item * 2


if __name__ == "__main__":
    sample = list(range(20))
    expected = [item * 2 for item in sample]

    for name, results in (
        ("mpire", run_mpire(sample, _demo_task)),
        ("mpire rich", run_mpire_rich(sample, _demo_task)),
        ("mpire lazy", sorted(run_mpire_lazy(iter(sample), _demo_task, total=20))),
    ):
        if results != expected:
            raise SystemExit(f"{name}: unexpected results {results!r}")
        print(f"ok: {name} ({len(results)} results)")
    print("All sanity checks passed.")
