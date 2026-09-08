"""ThreadPoolExecutor Progress Bars - Copy-Paste Cheatsheet.

IO-bound work (network, disk, APIs) on threads with tqdm / rich bars.

| Function                 | Best for                              | Failures    |
|--------------------------|---------------------------------------|-------------|
| run_thread_tqdm_easy     | IO-bound one-liner                    | raise first |
| run_thread_tqdm_manual   | IO-bound, per-item failures kept      | as outcomes |
| run_thread_rich          | IO-bound, pretty UI, failures kept    | as outcomes |
| run_thread_rich_per_task | One bar per running item (downloads)  | as outcomes |

Usage:
    1. Copy the function you need (its imports travel with it).
    2. Call it with your own ``func(item) -> result``.

Dependencies:
    pip install tqdm rich

Note:
    - "as outcomes": the result is ``list[R | BaseException]`` in INPUT order.
      A failed item holds its exception; nothing is dropped, nothing raised.
    - ``as_completed`` yields in finish order; each future is mapped back to
      its input index so the returned list keeps the input order.
    - Threads share the GIL: use ``processes.py`` for CPU-bound work.
"""

from collections.abc import Callable, Sequence

# =============================================================================
# 1. One overall bar
# =============================================================================


def run_thread_tqdm_easy[T, R](
    items: Sequence[T], func: Callable[[T], R], max_workers: int = 8
) -> list[R]:
    """Run ``func`` on a thread pool with tqdm's ``thread_map`` one-liner.

    [Best for] Fire-and-forget IO parallelism.
    [Note] Results keep input order. The first exception propagates once
           its result is collected; the other threads still run to the end.
    """
    from tqdm.contrib.concurrent import thread_map

    return thread_map(func, items, max_workers=max_workers, desc="Threads (easy)")


def run_thread_tqdm_manual[T, R](
    items: Sequence[T], func: Callable[[T], R], max_workers: int = 8
) -> list[R | BaseException]:
    """Run ``func`` on a thread pool, tqdm bar, every failure kept as data.

    [Best for] Batch IO where one bad item must not stop the rest.
    [Note] ``future.exception()`` avoids a try/except per item;
           ``tqdm.write`` logs the failure without breaking the bar.
    """
    from concurrent.futures import ThreadPoolExecutor, as_completed

    from tqdm import tqdm

    outcomes: dict[int, R | BaseException] = {}
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        index_of = {
            executor.submit(func, item): index for index, item in enumerate(items)
        }
        for future in tqdm(
            as_completed(index_of), total=len(items), desc="Threads (manual)"
        ):
            index = index_of[future]
            error = future.exception()
            if error is not None:
                tqdm.write(f"item {index} failed: {error!r}")
            outcomes[index] = error if error is not None else future.result()
    return [outcomes[index] for index in range(len(items))]


def run_thread_rich[T, R](
    items: Sequence[T], func: Callable[[T], R], max_workers: int = 8
) -> list[R | BaseException]:
    """Run ``func`` on a thread pool, rich bar, every failure kept as data.

    [Best for] The same batch IO with count, elapsed and ETA columns.
    [Note] ``progress.log`` prints above the bar with a timestamp. Rich's
           ``Progress`` is thread-safe, so workers may call ``advance`` too.
    """
    from concurrent.futures import ThreadPoolExecutor, as_completed

    from rich.progress import (
        BarColumn,
        MofNCompleteColumn,
        Progress,
        SpinnerColumn,
        TextColumn,
        TimeElapsedColumn,
        TimeRemainingColumn,
    )

    outcomes: dict[int, R | BaseException] = {}
    with (
        Progress(
            SpinnerColumn(),
            TextColumn("[bold blue]{task.description}"),
            BarColumn(),
            MofNCompleteColumn(),
            TimeElapsedColumn(),
            TimeRemainingColumn(),
        ) as progress,
        ThreadPoolExecutor(max_workers=max_workers) as executor,
    ):
        task = progress.add_task("Threads (rich)", total=len(items))
        index_of = {
            executor.submit(func, item): index for index, item in enumerate(items)
        }
        for future in as_completed(index_of):
            index = index_of[future]
            error = future.exception()
            if error is not None:
                progress.log(f"item {index} failed: {error!r}")
            outcomes[index] = error if error is not None else future.result()
            progress.advance(task)
    return [outcomes[index] for index in range(len(items))]


# =============================================================================
# 2. One bar per running item
# =============================================================================


def run_thread_rich_per_task[T, R](
    items: Sequence[T],
    func: Callable[[T, Callable[[int], None]], R],
    max_workers: int = 4,
    steps_per_item: int = 100,
) -> list[R | BaseException]:
    """Run ``func(item, advance)`` with an overall bar plus one bar per item.

    [Best for] Parallel downloads / uploads where each item has its own
               length and the user wants to see every transfer.
    [Note] ``func`` receives ``advance(n)`` and calls it as it makes progress
           (``steps_per_item`` is the per-item total). Threads share memory,
           so the callback updates the live display directly; for processes
           see ``processes.run_process_rich_per_worker``.
           Finished item bars are hidden to keep the display bounded.
    """
    from concurrent.futures import ThreadPoolExecutor, as_completed

    from rich.progress import (
        BarColumn,
        MofNCompleteColumn,
        Progress,
        TaskID,
        TextColumn,
        TimeRemainingColumn,
    )

    outcomes: dict[int, R | BaseException] = {}
    with (
        Progress(
            TextColumn("[bold blue]{task.description}"),
            BarColumn(),
            MofNCompleteColumn(),
            TimeRemainingColumn(),
        ) as progress,
        ThreadPoolExecutor(max_workers=max_workers) as executor,
    ):
        overall = progress.add_task("Overall", total=len(items))

        def tracked(item: T, bar: TaskID) -> R:
            progress.update(bar, visible=True)
            try:
                return func(item, lambda amount: progress.advance(bar, amount))
            finally:
                progress.update(bar, visible=False)

        index_of = {
            executor.submit(
                tracked,
                item,
                progress.add_task(repr(item), total=steps_per_item, visible=False),
            ): index
            for index, item in enumerate(items)
        }
        for future in as_completed(index_of):
            index = index_of[future]
            error = future.exception()
            outcomes[index] = error if error is not None else future.result()
            progress.advance(overall)
    return [outcomes[index] for index in range(len(items))]


# =============================================================================
# Quick Sanity Check
# =============================================================================


def _demo_task(item: int) -> int:
    """Dummy IO: sleep briefly and double the item; item 7 always fails."""
    import time

    time.sleep(0.05)
    if item == 7:
        raise ValueError("item 7 is broken on purpose")
    return item * 2


def _demo_step_task(item: int, advance: Callable[[int], None]) -> int:
    """Dummy transfer: report 100 steps of progress, then return the item."""
    import time

    for _ in range(10):
        time.sleep(0.01)
        advance(10)
    return item * 2


def _check_outcomes(name: str, outcomes: list[int | BaseException]) -> None:
    """Assert the outcome list mirrors the sample: item 7 failed, rest doubled."""
    if len(outcomes) != 20:
        raise SystemExit(f"{name}: expected 20 outcomes, got {len(outcomes)}")
    for index, outcome in enumerate(outcomes):
        want_error = index == 7
        if isinstance(outcome, BaseException) != want_error:
            raise SystemExit(f"{name}: outcome {index} is {outcome!r}")
        if not want_error and outcome != index * 2:
            raise SystemExit(f"{name}: outcome {index} is {outcome!r}")
    print(f"ok: {name} (20 outcomes, item 7 failed as expected)")


if __name__ == "__main__":
    sample = list(range(20))
    clean = [item for item in sample if item != 7]

    if run_thread_tqdm_easy(clean, _demo_task, max_workers=4) != [
        item * 2 for item in clean
    ]:
        raise SystemExit("thread tqdm easy: unexpected results")
    print("ok: thread tqdm easy (19 results)")

    _check_outcomes("thread tqdm manual", run_thread_tqdm_manual(sample, _demo_task))
    _check_outcomes("thread rich", run_thread_rich(sample, _demo_task))

    per_task = run_thread_rich_per_task(sample[:6], _demo_step_task, max_workers=3)
    if per_task != [item * 2 for item in sample[:6]]:
        raise SystemExit(f"thread rich per task: unexpected results {per_task!r}")
    print("ok: thread rich per task (6 results)")
    print("All sanity checks passed.")
