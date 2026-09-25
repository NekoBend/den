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
    - Every runner collects inside a ``try`` whose ``finally`` calls
      ``executor.shutdown(wait=True, cancel_futures=True)``: Ctrl-C then drops
      the queued items instead of running them all through the executor's own
      ``__exit__``. ``ThreadPoolExecutor`` drains and cancels them inside that
      call whatever ``wait`` says; ``wait=True`` keeps the line identical to
      the one in ``processes.py``, where it IS load-bearing, and means the
      pool has really stopped by the time the function returns.
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
    [Note] Results keep input order. The first exception propagates once its
           result is collected; ``Executor.map``'s iterator then cancels every
           item that has not started (``thread_map`` returns
           ``list(ex.map(...))``), so only the ones already running finish.
    """
    from tqdm.contrib.concurrent import thread_map

    return thread_map(func, items, max_workers=max_workers, desc="Threads (easy)")


def run_thread_tqdm_manual[T, R](
    items: Sequence[T], func: Callable[[T], R], max_workers: int = 8
) -> list[R | BaseException]:
    """Run ``func`` on a thread pool, tqdm bar, every failure kept as data.

    [Best for] Batch IO where one bad item must not stop the rest.
    [Note] ``future.exception()`` avoids a try/except per item;
           ``tqdm.write`` logs the failure without breaking the bar. The
           ``finally`` drops the queued items, so Ctrl-C ends the run instead
           of letting the pool drain (see the module Note on ``wait=True``).
    """
    from concurrent.futures import ThreadPoolExecutor, as_completed

    from tqdm import tqdm

    outcomes: dict[int, R | BaseException] = {}
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        index_of = {
            executor.submit(func, item): index for index, item in enumerate(items)
        }
        try:
            for future in tqdm(
                as_completed(index_of), total=len(items), desc="Threads (manual)"
            ):
                index = index_of[future]
                error = future.exception()
                if error is not None:
                    tqdm.write(f"item {index} failed: {error!r}")
                outcomes[index] = error if error is not None else future.result()
        finally:
            executor.shutdown(wait=True, cancel_futures=True)
    return [outcomes[index] for index in range(len(items))]


def run_thread_rich[T, R](
    items: Sequence[T], func: Callable[[T], R], max_workers: int = 8
) -> list[R | BaseException]:
    """Run ``func`` on a thread pool, rich bar, every failure kept as data.

    [Best for] The same batch IO with count, elapsed and ETA columns.
    [Note] ``progress.log`` prints above the bar with a timestamp. Rich's
           ``Progress`` is thread-safe, so workers may call ``advance`` too.
           The ``finally`` drops the queued items on Ctrl-C.
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
        try:
            for future in as_completed(index_of):
                index = index_of[future]
                error = future.exception()
                if error is not None:
                    progress.log(f"item {index} failed: {error!r}")
                outcomes[index] = error if error is not None else future.result()
                progress.advance(task)
        finally:
            executor.shutdown(wait=True, cancel_futures=True)
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
           Finished item bars are hidden to keep the display bounded, and the
           ``finally`` drops the queued items on Ctrl-C.
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
        try:
            for future in as_completed(index_of):
                index = index_of[future]
                error = future.exception()
                outcomes[index] = error if error is not None else future.result()
                progress.advance(overall)
        finally:
            executor.shutdown(wait=True, cancel_futures=True)
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
    """Dummy transfer: report 100 steps, then double the item; item 3 fails."""
    import time

    for _ in range(10):
        time.sleep(0.01)
        advance(10)
    if item == 3:
        raise ValueError("item 3 is broken on purpose")
    return item * 2


def _check_outcomes(
    name: str,
    outcomes: list[int | BaseException],
    *,
    expected: int,
    failing: Callable[[int], bool],
) -> None:
    """Assert ``expected`` outcomes, in input order, failed exactly where promised."""
    if len(outcomes) != expected:
        raise SystemExit(f"{name}: expected {expected} outcomes, got {len(outcomes)}")
    for index, outcome in enumerate(outcomes):
        want_error = failing(index)
        if isinstance(outcome, BaseException) != want_error:
            raise SystemExit(f"{name}: outcome {index} is {outcome!r}")
        if not want_error and outcome != index * 2:
            raise SystemExit(f"{name}: outcome {index} is {outcome!r}")
    failures = sum(isinstance(outcome, BaseException) for outcome in outcomes)
    print(f"ok: {name} ({expected} outcomes in input order, {failures} failed)")


if __name__ == "__main__":
    import threading
    import time

    sample = list(range(20))
    clean = [item for item in sample if item != 7]

    easy = run_thread_tqdm_easy(clean, _demo_task, max_workers=4)
    if easy != [item * 2 for item in clean]:
        raise SystemExit(f"thread tqdm easy: unexpected results {easy!r}")
    print(f"ok: thread tqdm easy ({len(easy)} results in input order)")

    _check_outcomes(
        "thread tqdm manual",
        run_thread_tqdm_manual(sample, _demo_task),
        expected=len(sample),
        failing=lambda index: index == 7,
    )
    _check_outcomes(
        "thread rich",
        run_thread_rich(sample, _demo_task),
        expected=len(sample),
        failing=lambda index: index == 7,
    )
    _check_outcomes(
        "thread rich per task",
        run_thread_rich_per_task(sample[:6], _demo_step_task, max_workers=3),
        expected=6,
        failing=lambda index: index == 3,
    )

    # "raise (first)" also means the queued items are cancelled, not run.
    ran: list[int] = []
    lock = threading.Lock()

    def _recorded(item: int) -> int:
        """Record the items that really ran; item 0 fails before any other."""
        with lock:
            ran.append(item)
        if item == 0:
            raise ValueError("item 0 is broken on purpose")
        time.sleep(0.05)
        return item * 2

    try:
        run_thread_tqdm_easy(list(range(40)), _recorded, max_workers=2)
    except ValueError:
        time.sleep(0.3)  # let the threads that were already running finish
    else:
        raise SystemExit("thread tqdm easy: expected the first failure to propagate")
    if len(ran) > 10:
        raise SystemExit(f"thread tqdm easy: {len(ran)}/40 ran, nothing was cancelled")
    print(f"ok: thread tqdm easy raised, {40 - len(ran)} of 40 items never started")
    print("All sanity checks passed.")
