"""ProcessPoolExecutor Progress Bars - Copy-Paste Cheatsheet.

CPU-bound work on processes (bypasses the GIL) with tqdm / rich bars, from a
one-liner to per-worker bars fed from inside the workers.

| Function                       | Best for                              | Failures    |
|--------------------------------|---------------------------------------|-------------|
| run_process_tqdm_easy          | CPU-bound one-liner                   | raise first |
| run_process_tqdm_manual        | CPU-bound, per-item failures kept     | as outcomes |
| run_process_rich               | CPU-bound, pretty UI, failures kept   | as outcomes |
| run_process_rich_ordered       | Stream results in input order         | raise+cancel|
| run_process_rich_bounded       | Huge / lazy iterables, bounded memory | as outcomes |
| run_process_rich_chunked       | Millions of tiny items (less IPC)     | as outcomes |
| run_process_rich_sharded       | N records -> shard per CPU -> blocks  | as outcomes |
| run_process_thread_rich_nested | Shard per CPU, threads inside for IO  | as outcomes |
| run_process_rich_per_worker    | One bar per worker + inner progress   | as outcomes |
| run_process_rich_fail_fast     | Stop everything on the first failure  | raise+cancel|
| run_pool_rich_imap             | stdlib Pool, incremental, finish order| raise first |

Usage:
    1. Copy the function you need (its imports travel with it). Functions
       that run inside the workers (``_apply_block``, ``_process_shard``,
       ``_threaded_block``, ``_report_to_queue``) sit next to their callers:
       copy them too, together with the ``ShardProgress`` / ``WorkerProgress``
       / ``WorkerLog`` messages they put on the queue - those are the only
       names in this sheet that live at module level, because worker and
       parent both have to see the same class.
    2. Call it with your own TOP-LEVEL ``func`` (see Note).

Dependencies:
    pip install tqdm rich

Note:
    - Process pools pickle ``func`` and every item. ``func`` must be a
      top-level ``def``: no lambda, no closure, nothing defined inside
      ``if __name__ == "__main__":``. Under the ``spawn`` start method (macOS,
      Windows, Python 3.14 on Linux) the child re-imports your module, so a
      function that only exists in the main guard is missing there. The sanity
      check below runs under ``spawn`` for that reason.
    - "as outcomes": the result is ``list[R | BaseException]`` in INPUT order.
      A failed item holds its exception; nothing is dropped, nothing raised.
    - ``as_completed`` yields in finish order; futures are mapped back to
      their input index so the returned list keeps the input order.
    - A running process cannot be cancelled: ``cancel_futures=True`` drops the
      queued items, the ones already running finish first. Every runner does
      it in a ``finally`` so Ctrl-C ends the run, and it has to be
      ``shutdown(wait=True, cancel_futures=True)``: with ``wait=False`` the
      ``with`` block's own ``__exit__`` calls ``shutdown(wait=True)`` right
      after, which resets the cancel flag (and clears the manager thread the
      first call left behind) before the pool ever acts on it - the pool then
      runs every queued item while the parent has already moved on.
    - Chunked vs sharded: chunked submits many small futures (dynamic load
      balancing, one overall bar); sharded submits one future per worker
      (static split, a bar per shard, block-level progress from inside).
    - Never print from a worker, not even through "the same" Console: a
      process cannot share the parent's ``Progress`` (its lock is a
      ``threading.RLock``, a ``Console`` does not pickle), so the worker's
      bytes land inside the live area and leave stale copies of the bars.
      The sharded and per-worker runners hand the worker a ``log(text)``
      callback instead; it travels over the same queue as the progress
      messages and the parent prints it above the bars with ``progress.log``.
"""

from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass
from queue import Queue


@dataclass(frozen=True)
class ShardProgress:
    """Progress message from ``_process_shard``: records done in one shard."""

    shard_id: int
    done: int
    total: int


@dataclass(frozen=True)
class WorkerProgress:
    """Progress message from ``_report_to_queue``: one worker's current item."""

    pid: int
    label: str
    done: int
    total: int


@dataclass(frozen=True)
class WorkerLog:
    """Log line from a worker; the parent prints it above the bars."""

    text: str


# =============================================================================
# 1. One overall bar
# =============================================================================


def run_process_tqdm_easy[T, R](
    items: Sequence[T], func: Callable[[T], R], max_workers: int = 4, chunksize: int = 1
) -> list[R]:
    """Run ``func`` on a process pool with tqdm's ``process_map`` one-liner.

    [Best for] Heavy CPU work with no per-item error handling.
    [Note] Results keep input order; the first exception propagates.
           Raise ``chunksize`` for tiny items: every chunk is one pickle
           round-trip, and the bar still advances per item.
    """
    from tqdm.contrib.concurrent import process_map

    return process_map(
        func,
        items,
        max_workers=max_workers,
        chunksize=chunksize,
        desc="Processes (easy)",
    )


def run_process_tqdm_manual[T, R](
    items: Sequence[T], func: Callable[[T], R], max_workers: int = 4
) -> list[R | BaseException]:
    """Run ``func`` on a process pool, tqdm bar, every failure kept as data.

    [Best for] CPU batches where one bad item must not stop the rest.
    [Note] ``future.exception()`` avoids a try/except per item;
           ``tqdm.write`` logs the failure without breaking the bar. The
           ``finally`` drops the queued items on Ctrl-C (see the module Note).
    """
    from concurrent.futures import ProcessPoolExecutor, as_completed

    from tqdm import tqdm

    outcomes: dict[int, R | BaseException] = {}
    with ProcessPoolExecutor(max_workers=max_workers) as executor:
        index_of = {
            executor.submit(func, item): index for index, item in enumerate(items)
        }
        try:
            for future in tqdm(
                as_completed(index_of), total=len(items), desc="Processes (manual)"
            ):
                index = index_of[future]
                error = future.exception()
                if error is not None:
                    tqdm.write(f"item {index} failed: {error!r}")
                outcomes[index] = error if error is not None else future.result()
        finally:
            executor.shutdown(wait=True, cancel_futures=True)
    return [outcomes[index] for index in range(len(items))]


def run_process_rich[T, R](
    items: Sequence[T], func: Callable[[T], R], max_workers: int = 4
) -> list[R | BaseException]:
    """Run ``func`` on a process pool, rich bar, every failure kept as data.

    [Best for] The same CPU batch with count, elapsed and ETA columns.
    [Note] ``progress.log`` prints above the bar with a timestamp. Only the
           parent touches ``progress``: a worker process cannot update it
           (see ``run_process_rich_per_worker`` for progress from inside).
           The ``finally`` drops the queued items on Ctrl-C.
    """
    from concurrent.futures import ProcessPoolExecutor, as_completed

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
        ProcessPoolExecutor(max_workers=max_workers) as executor,
    ):
        task = progress.add_task("Processes (rich)", total=len(items))
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


def run_process_rich_ordered[T, R](
    items: Sequence[T], func: Callable[[T], R], max_workers: int = 4, chunksize: int = 1
) -> list[R]:
    """Stream results in input order with ``executor.map`` under rich's ``track``.

    [Best for] Pipelines that consume results in order as they arrive
               (write to a file, feed the next stage) without waiting for all.
    [Note] ``map`` submits every item up front and yields results in input
           order, so one slow early item delays the later ones. The first
           exception propagates when its position is reached and the
           not-yet-started items are cancelled.
    """
    from concurrent.futures import ProcessPoolExecutor

    from rich.progress import track

    with ProcessPoolExecutor(max_workers=max_workers) as executor:
        return list(
            track(
                executor.map(func, items, chunksize=chunksize),
                total=len(items),
                description="Processes (ordered)",
            )
        )


# =============================================================================
# 2. Large inputs: bounded in-flight window, chunks, shards
# =============================================================================


def run_process_rich_bounded[T, R](
    items: Iterable[T],
    func: Callable[[T], R],
    max_workers: int = 4,
    total: int | None = None,
    in_flight: int | None = None,
) -> list[R | BaseException]:
    """Run ``func`` with at most ``in_flight`` items submitted at any time.

    [Best for] Millions of items or a lazy generator (database cursor, file
               lines): only the window is pickled and held in memory.
    [Note] ``in_flight`` defaults to ``2 * max_workers``: enough that no
           worker idles, small enough to bound memory. Pass ``total`` when
           the iterable has no ``len()`` and you still want an ETA.
    """
    from concurrent.futures import FIRST_COMPLETED, Future, ProcessPoolExecutor, wait

    from rich.progress import (
        BarColumn,
        MofNCompleteColumn,
        Progress,
        TextColumn,
        TimeRemainingColumn,
    )

    window = in_flight or 2 * max_workers
    outcomes: dict[int, R | BaseException] = {}
    index_of: dict[Future[R], int] = {}
    with (
        Progress(
            TextColumn("[bold blue]{task.description}"),
            BarColumn(),
            MofNCompleteColumn(),
            TimeRemainingColumn(),
        ) as progress,
        ProcessPoolExecutor(max_workers=max_workers) as executor,
    ):
        task = progress.add_task("Processes (bounded)", total=total)

        def collect(done: set[Future[R]]) -> None:
            for future in done:
                error = future.exception()
                outcomes[index_of.pop(future)] = (
                    error if error is not None else future.result()
                )
                progress.advance(task)

        pending: set[Future[R]] = set()
        for index, item in enumerate(items):
            if len(pending) >= window:
                done, pending = wait(pending, return_when=FIRST_COMPLETED)
                collect(done)
            future = executor.submit(func, item)
            index_of[future] = index
            pending.add(future)
        collect(wait(pending).done)
    return [outcomes[index] for index in range(len(outcomes))]


def _apply_block[T, R](
    func: Callable[[T], R], block: Sequence[T]
) -> list[R | BaseException]:
    """Apply ``func`` to every item of ``block`` inside a worker, failures kept.

    Runs in the worker process. The per-item exception is returned as data
    so one bad item does not fail the whole block.
    """
    outcomes: list[R | BaseException] = []
    for item in block:
        try:
            outcomes.append(func(item))
        except Exception as exc:  # ruff: ignore[blind-except] - returned to the parent as data
            outcomes.append(exc)
    return outcomes


def run_process_rich_chunked[T, R](
    items: Sequence[T],
    func: Callable[[T], R],
    max_workers: int = 4,
    chunk_size: int = 1_000,
) -> list[R | BaseException]:
    """Run ``func`` over ``items`` in chunks: one future per chunk, not per item.

    [Best for] Millions of tiny items where per-item pickling and future
               bookkeeping would cost more than the work itself.
    [Note] Chunks are handed out as workers free up (dynamic load balancing).
           The bar advances by ``len(chunk)`` as each chunk completes, so it
           moves in steps: pick ``chunk_size`` so a chunk takes ~1 second.
           The ``finally`` drops the queued chunks on Ctrl-C.
           ``_apply_block`` keeps per-ITEM failures as data; a CHUNK-level one
           (a result that will not pickle, a worker the OOM killer took, a
           ``BrokenProcessPool``) reaches the parent as the future's exception,
           so it is written across that chunk's records - ``future.result()``
           here would raise instead and throw away every chunk already
           collected. Pair with ``_apply_block``.
    """
    from concurrent.futures import ProcessPoolExecutor, as_completed

    from rich.progress import (
        BarColumn,
        MofNCompleteColumn,
        Progress,
        TextColumn,
        TimeRemainingColumn,
    )

    chunks = [
        items[start : start + chunk_size] for start in range(0, len(items), chunk_size)
    ]
    outcomes_by_chunk: list[list[R | BaseException]] = [[] for _ in chunks]
    with (
        Progress(
            TextColumn("[bold blue]{task.description}"),
            BarColumn(),
            MofNCompleteColumn(),
            TimeRemainingColumn(),
        ) as progress,
        ProcessPoolExecutor(max_workers=max_workers) as executor,
    ):
        task = progress.add_task("Processes (chunked)", total=len(items))
        index_of = {
            executor.submit(_apply_block, func, chunk): index
            for index, chunk in enumerate(chunks)
        }
        try:
            for future in as_completed(index_of):
                index = index_of[future]
                error = future.exception()
                outcomes_by_chunk[index] = (  # ty: ignore[invalid-assignment] - _apply_block's R is not bound through submit (ty 0.0.55)
                    [error] * len(chunks[index])
                    if error is not None
                    else future.result()
                )
                progress.advance(task, len(chunks[index]))
        finally:
            executor.shutdown(wait=True, cancel_futures=True)
    return [outcome for chunk in outcomes_by_chunk for outcome in chunk]


def _process_shard[T, R](
    shard_id: int,
    shard: Sequence[T],
    block_func: Callable[[Sequence[T], Callable[[str], None]], Sequence[R]],
    block_size: int,
    reports: Queue[ShardProgress | WorkerLog | None],
) -> list[R | BaseException]:
    """Process one shard block by block, reporting after every block.

    Runs in the worker process. Calls ``block_func(block, log)`` and puts a
    ``ShardProgress`` on ``reports`` after each block; ``log(text)`` puts a
    ``WorkerLog`` on the same queue. A block that raises, or returns the wrong
    number of results, yields that exception once per record of the block
    and logs it.
    """

    def log(text: str) -> None:
        reports.put(WorkerLog(f"shard {shard_id}: {text}"))

    outcomes: list[R | BaseException] = []
    for start in range(0, len(shard), block_size):
        block = shard[start : start + block_size]
        try:
            results: list[R | BaseException] = list(block_func(block, log))
        except Exception as exc:  # ruff: ignore[blind-except] - returned to the parent as data
            log(f"block at {start} failed: {exc!r}")
            results = [exc] * len(block)
        if len(results) != len(block):
            mismatch = ValueError(
                f"block_func returned {len(results)} results for {len(block)} records"
            )
            log(repr(mismatch))
            results = [mismatch] * len(block)
        outcomes.extend(results)
        reports.put(ShardProgress(shard_id, len(outcomes), len(shard)))
    return outcomes


def run_process_rich_sharded[T, R](
    records: Sequence[T],
    block_func: Callable[[Sequence[T], Callable[[str], None]], Sequence[R]],
    max_workers: int = 4,
    block_size: int = 10_000,
) -> list[R | BaseException]:
    """Split ``records`` into one shard per worker, process each shard in blocks.

    [Best for] "1M records on N CPUs": every worker owns one contiguous shard,
               walks it block by block (``block_func(block, log)`` sees a
               whole block, so it can vectorise with numpy/pandas or loop),
               and the parent shows one bar per shard plus the overall count.
    [Note] ``log(text)`` is how a worker prints: the line goes over the
           queue and the parent shows it above the bars with ``progress.log``
           (a worker writing to the terminal itself corrupts the display).
           One future per worker means one pickle of each shard; for data
           that is expensive to pickle, pass shard BOUNDS instead and let
           ``block_func`` load its own slice. Messages travel over a
           ``Manager().Queue()`` (a plain ``multiprocessing.Queue`` cannot be
           submitted to an executor); one per block, not per record, keeps
           the IPC cost negligible. ``_process_shard`` keeps a failing BLOCK
           as data; a shard-level failure (an unpicklable result, a dead
           worker) arrives as the future's exception and is written across
           that shard's records, so the other shards still come back.
           Pair with ``_process_shard``.
    """
    import math
    import multiprocessing
    import threading
    from concurrent.futures import ProcessPoolExecutor

    from rich.progress import (
        BarColumn,
        MofNCompleteColumn,
        Progress,
        TextColumn,
        TimeRemainingColumn,
    )

    shard_size = max(1, math.ceil(len(records) / max_workers))
    shards = [
        records[start : start + shard_size]
        for start in range(0, len(records), shard_size)
    ]
    with (
        Progress(
            TextColumn("[bold blue]{task.description}"),
            BarColumn(),
            MofNCompleteColumn(),
            TimeRemainingColumn(),
        ) as progress,
        multiprocessing.Manager() as manager,
        ProcessPoolExecutor(max_workers=max_workers) as executor,
    ):
        reports: Queue[ShardProgress | WorkerLog | None] = manager.Queue()
        overall = progress.add_task("Records", total=len(records))
        bars = [
            progress.add_task(f"Shard {shard_id}", total=len(shard))
            for shard_id, shard in enumerate(shards)
        ]

        def pump() -> None:
            done_by_shard = [0] * len(shards)
            while (report := reports.get()) is not None:
                if isinstance(report, WorkerLog):
                    progress.log(report.text)
                    continue
                progress.update(
                    bars[report.shard_id], completed=report.done, total=report.total
                )
                progress.advance(overall, report.done - done_by_shard[report.shard_id])
                done_by_shard[report.shard_id] = report.done

        pump_thread = threading.Thread(target=pump, daemon=True)
        pump_thread.start()
        try:
            futures = [
                executor.submit(
                    _process_shard, shard_id, shard, block_func, block_size, reports
                )
                for shard_id, shard in enumerate(shards)
            ]
            outcomes: list[R | BaseException] = []
            for shard, future in zip(shards, futures, strict=True):
                error = future.exception()
                results: list[R | BaseException] = (  # ty: ignore[invalid-assignment] - _process_shard's R is not bound through submit (ty 0.0.55)
                    [error] * len(shard) if error is not None else future.result()
                )
                outcomes.extend(results)
        finally:
            reports.put(None)
            pump_thread.join()
    return outcomes


def _threaded_block[T, R](
    block: Sequence[T],
    log: Callable[[str], None],
    func: Callable[[T], R],
    max_threads: int,
) -> list[R | BaseException]:
    """Run ``func`` over one block on a thread pool inside the worker.

    Runs in the worker process: the process owns a shard (CPU split), the
    threads fan out the block's items (IO split). Failures are kept per item
    and reported through ``log``.
    """
    from concurrent.futures import ThreadPoolExecutor, as_completed

    outcomes: dict[int, R | BaseException] = {}
    with ThreadPoolExecutor(max_workers=max_threads) as threads:
        index_of = {
            threads.submit(func, item): index for index, item in enumerate(block)
        }
        for future in as_completed(index_of):
            error = future.exception()
            if error is not None:
                log(f"item {block[index_of[future]]!r} failed: {error!r}")
            outcomes[index_of[future]] = error if error is not None else future.result()
    return [outcomes[index] for index in range(len(block))]


def run_process_thread_rich_nested[T, R](
    records: Sequence[T],
    func: Callable[[T], R],
    max_workers: int = 4,
    max_threads: int = 8,
    block_size: int = 1_000,
) -> list[R | BaseException]:
    """Shard ``records`` across processes, fan each block out on threads.

    [Best for] Records that need CPU work AND IO per item (parse + fetch,
               transform + upload): processes for the CPU split, a thread
               pool inside every worker for the IO fan-out.
    [Note] Built on ``run_process_rich_sharded``: the block function is a
           ``partial`` of ``_threaded_block`` (a partial of a top-level
           function pickles; a closure does not). Each shard bar advances per
           block, so ``block_size`` sets the display granularity and
           ``max_threads`` the IO concurrency PER PROCESS (total in flight is
           ``max_workers * max_threads``). Per-item failures are logged above
           the bars through the shard's ``log`` callback.
    """
    from functools import partial

    block_func = partial(_threaded_block, func=func, max_threads=max_threads)
    return run_process_rich_sharded(
        records, block_func, max_workers=max_workers, block_size=block_size
    )


# =============================================================================
# 3. Progress reported from inside the workers
# =============================================================================


def _report_to_queue[T, R](
    func: Callable[[T, Callable[[int, int], None], Callable[[str], None]], R],
    item: T,
    reports: Queue[WorkerProgress | WorkerLog | None],
) -> R:
    """Call ``func(item, report, log)`` in a worker, forwarding both to the parent.

    Runs in the worker process. ``report(done, total)`` puts a
    ``WorkerProgress`` keyed by this worker's pid on ``reports``; ``log(text)``
    puts a ``WorkerLog`` prefixed with the pid and item on the same queue.
    """
    import os

    pid = os.getpid()
    label = repr(item)

    def report(done: int, total: int) -> None:
        reports.put(WorkerProgress(pid, label, done, total))

    def log(text: str) -> None:
        reports.put(WorkerLog(f"pid {pid} {label}: {text}"))

    return func(item, report, log)


def run_process_rich_per_worker[T, R](
    items: Sequence[T],
    func: Callable[[T, Callable[[int, int], None], Callable[[str], None]], R],
    max_workers: int = 4,
) -> list[R | BaseException]:
    """Run ``func(item, report, log)`` with an overall bar and a bar per worker.

    [Best for] Long-running items (a video, a big file, a model) where each
               worker should show WHICH item it is on and HOW FAR into it.
    [Note] ``func`` calls ``report(done, total)`` as it makes progress and
           ``log(text)`` for anything it would otherwise print; the parent
           keeps a bar per worker pid, retitled for each new item, and prints
           log lines above the bars. Messages travel over a
           ``Manager().Queue()`` and a pump thread applies them to the display
           (rich's ``Progress`` is thread-safe). The ``finally`` drops the
           queued items on Ctrl-C, then stops the pump thread - in that order,
           so the workers that are still finishing keep a live queue to report
           on. Pair with ``_report_to_queue``.
    """
    import multiprocessing
    import threading
    from concurrent.futures import ProcessPoolExecutor, as_completed

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
        multiprocessing.Manager() as manager,
        ProcessPoolExecutor(max_workers=max_workers) as executor,
    ):
        reports: Queue[WorkerProgress | WorkerLog | None] = manager.Queue()
        overall = progress.add_task("Overall", total=len(items))
        bars: dict[int, TaskID] = {}

        def pump() -> None:
            while (report := reports.get()) is not None:
                if isinstance(report, WorkerLog):
                    progress.log(report.text)
                    continue
                bar = bars.get(report.pid)
                if bar is None:
                    bar = bars[report.pid] = progress.add_task(
                        f"pid {report.pid}", total=report.total
                    )
                progress.update(
                    bar,
                    description=f"pid {report.pid}: {report.label}",
                    completed=report.done,
                    total=report.total,
                )

        pump_thread = threading.Thread(target=pump, daemon=True)
        pump_thread.start()
        try:
            index_of = {
                executor.submit(_report_to_queue, func, item, reports): index
                for index, item in enumerate(items)
            }
            for future in as_completed(index_of):
                error = future.exception()
                outcomes[index_of[future]] = (  # ty: ignore[invalid-assignment] - _report_to_queue's R is not bound through submit (ty 0.0.55)
                    error if error is not None else future.result()
                )
                progress.advance(overall)
        finally:
            executor.shutdown(wait=True, cancel_futures=True)
            reports.put(None)
            pump_thread.join()
    return [outcomes[index] for index in range(len(items))]


# =============================================================================
# 4. Fail fast and stdlib Pool
# =============================================================================


def run_process_rich_fail_fast[T, R](
    items: Sequence[T], func: Callable[[T], R], max_workers: int = 4
) -> list[R]:
    """Run ``func`` on a process pool and stop at the first failure.

    [Best for] All-or-nothing jobs: a single bad item makes the run useless,
               so do not burn CPU on the rest.
    [Note] ``future.result()`` re-raises the worker's exception in the
           parent; the ``finally`` cancels every queued item (the running
           ones finish, a process cannot be killed mid-item) and waits for
           them, so the call returns with the pool stopped rather than with
           the rest of the batch still burning CPU in the background. Ctrl-C
           takes the same path. ``transient=True`` removes the bar afterwards
           so the traceback is what remains on screen.
    """
    from concurrent.futures import ProcessPoolExecutor, as_completed

    from rich.progress import BarColumn, MofNCompleteColumn, Progress, TextColumn

    results: dict[int, R] = {}
    with (
        Progress(
            TextColumn("[bold blue]{task.description}"),
            BarColumn(),
            MofNCompleteColumn(),
            transient=True,
        ) as progress,
        ProcessPoolExecutor(max_workers=max_workers) as executor,
    ):
        task = progress.add_task("Processes (fail fast)", total=len(items))
        index_of = {
            executor.submit(func, item): index for index, item in enumerate(items)
        }
        try:
            for future in as_completed(index_of):
                results[index_of[future]] = future.result()
                progress.advance(task)
        finally:
            # No-op after a clean run (nothing is queued any more); after an
            # exception or Ctrl-C it drops every item that has not started.
            # wait=True is load-bearing: with wait=False the executor's own
            # __exit__ calls shutdown(wait=True) next, resetting the cancel
            # flag before the pool reads it, so nothing is cancelled at all.
            executor.shutdown(wait=True, cancel_futures=True)
    return [results[index] for index in range(len(items))]


def run_pool_rich_imap[T, R](
    items: Sequence[T], func: Callable[[T], R], max_workers: int = 4, chunksize: int = 1
) -> list[R]:
    """Run ``func`` with stdlib ``multiprocessing.Pool.imap_unordered`` + rich.

    [Best for] Code that already uses ``Pool``; results stream as they finish.
    [Note] ``imap`` (ordered) and ``imap_unordered`` consume the input
           incrementally in a feeder thread, but do not bound the queue: use
           ``run_process_rich_bounded`` for strict memory limits. The first
           exception propagates.
    """
    import multiprocessing

    from rich.progress import track

    with multiprocessing.Pool(processes=max_workers) as pool:
        return list(
            track(
                pool.imap_unordered(func, items, chunksize=chunksize),
                total=len(items),
                description="Pool (imap_unordered)",
            )
        )


# =============================================================================
# Quick Sanity Check (runs under the spawn start method on purpose)
# =============================================================================


def _demo_task(item: int) -> int:
    """Dummy CPU work: sleep briefly and double the item; item 7 always fails."""
    import time

    time.sleep(0.02)
    if item == 7:
        raise ValueError("item 7 is broken on purpose")
    return item * 2


def _demo_block(block: Sequence[int], log: Callable[[str], None]) -> list[int]:
    """Dummy block work: double every record; a block holding record 7 fails."""
    import time

    time.sleep(0.01)
    if block[0] % 5_000 == 0:
        log(f"block starting at record {block[0]}")
    if 7 in block:
        raise ValueError("the block holding record 7 is broken on purpose")
    return [record * 2 for record in block]


def _demo_step_task(
    item: int, report: Callable[[int, int], None], log: Callable[[str], None]
) -> int:
    """Dummy long item: report five steps, then double the item; 7 fails."""
    import time

    for step in range(1, 6):
        time.sleep(0.02)
        report(step, 5)
    if item % 10 == 0:
        log("halfway marker reached")
    if item == 7:
        raise ValueError("item 7 is broken on purpose")
    return item * 2


def _cancel_probe(item: int, seen: Queue[int]) -> int:
    """Report that this item really ran; item 0 fails at once, the rest linger."""
    import time

    seen.put(item)
    if item == 0:
        raise ValueError("item 0 is broken on purpose")
    time.sleep(0.15)
    return item * 2


def _unpicklable_task(item: int) -> int:
    """Double the item; item 7 returns a value the worker cannot pickle back."""

    class Doubled(int):
        """Locally defined, so pickling an instance of it fails by design."""

    return Doubled(item * 2) if item == 7 else item * 2


def _unpicklable_block(block: Sequence[int], log: Callable[[str], None]) -> list[int]:
    """Double every record; the first shard's results cannot be pickled back."""

    class Doubled(int):
        """Locally defined, so pickling an instance of it fails by design."""

    if block[0] < 20:
        log(f"block at {block[0]} will fail to pickle its results")
        return [Doubled(record * 2) for record in block]
    return [record * 2 for record in block]


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


def _check_raises(name: str, run: Callable[[], object]) -> None:
    """Assert ``run()`` propagates the worker's ValueError ("raise (first)")."""
    try:
        run()
    except ValueError as exc:
        print(f"ok: {name} raised {exc!r}")
    else:
        raise SystemExit(f"{name}: expected the worker's ValueError")


if __name__ == "__main__":
    import multiprocessing
    import time
    from functools import partial

    multiprocessing.set_start_method("spawn")

    sample = list(range(20))
    clean = [item for item in sample if item != 7]
    doubled_clean = [item * 2 for item in clean]

    for name, results in (
        ("process tqdm easy", run_process_tqdm_easy(clean, _demo_task)),
        ("process rich ordered", run_process_rich_ordered(clean, _demo_task)),
        ("process rich fail fast", run_process_rich_fail_fast(clean, _demo_task)),
        ("pool rich imap", sorted(run_pool_rich_imap(clean, _demo_task))),
    ):
        if results != doubled_clean:
            raise SystemExit(f"{name}: unexpected results {results!r}")
        print(f"ok: {name} ({len(results)} results in input order)")

    # The "raise (first)" runners must hand the worker's exception to the caller.
    failing_head = sample[:8]  # item 7 is the last one, so the head is done first
    _check_raises(
        "process tqdm easy", lambda: run_process_tqdm_easy(failing_head, _demo_task)
    )
    _check_raises(
        "process rich ordered",
        lambda: run_process_rich_ordered(failing_head, _demo_task),
    )
    _check_raises(
        "pool rich imap", lambda: run_pool_rich_imap(failing_head, _demo_task)
    )

    _check_outcomes(
        "process tqdm manual",
        run_process_tqdm_manual(sample, _demo_task),
        expected=len(sample),
        failing=lambda index: index == 7,
    )
    _check_outcomes(
        "process rich",
        run_process_rich(sample, _demo_task),
        expected=len(sample),
        failing=lambda index: index == 7,
    )
    _check_outcomes(
        "process rich bounded",
        run_process_rich_bounded(iter(sample), _demo_task, total=len(sample)),
        expected=len(sample),
        failing=lambda index: index == 7,
    )
    _check_outcomes(
        "process rich chunked",
        run_process_rich_chunked(sample, _demo_task, chunk_size=6),
        expected=len(sample),
        failing=lambda index: index == 7,
    )
    _check_outcomes(
        "process rich per worker",
        run_process_rich_per_worker(sample, _demo_step_task, max_workers=3),
        expected=len(sample),
        failing=lambda index: index == 7,
    )

    # A failure the worker cannot keep as data (its result will not pickle)
    # must still come back as outcomes: it lands on the whole chunk / shard.
    _check_outcomes(
        "process rich chunked (chunk-level failure)",
        run_process_rich_chunked(sample, _unpicklable_task, chunk_size=6),
        expected=len(sample),
        failing=lambda index: 6 <= index < 12,
    )
    _check_outcomes(
        "process rich sharded (shard-level failure)",
        run_process_rich_sharded(
            list(range(40)), _unpicklable_block, max_workers=2, block_size=10
        ),
        expected=40,
        failing=lambda index: index < 20,
    )

    records = list(range(20_000))
    _check_outcomes(
        "process rich sharded",
        run_process_rich_sharded(records, _demo_block, max_workers=4, block_size=500),
        expected=len(records),
        failing=lambda index: index < 500,  # the first block of shard 0 holds record 7
    )
    _check_outcomes(
        "process thread rich nested",
        run_process_thread_rich_nested(
            records[:2_000], _demo_task, max_workers=4, max_threads=8, block_size=100
        ),
        expected=2_000,
        failing=lambda index: index == 7,
    )

    # Fail fast must raise AND stop the pool: the call has to come back
    # quickly and leave the queued items unrun, not return while the workers
    # chew through the rest of the batch in the background.
    with multiprocessing.Manager() as manager:
        seen: Queue[int] = manager.Queue()
        started = time.perf_counter()
        try:
            run_process_rich_fail_fast(
                list(range(24)), partial(_cancel_probe, seen=seen), max_workers=4
            )
        except ValueError as exc:
            elapsed = time.perf_counter() - started
            print(f"ok: process rich fail fast raised {exc!r} after {elapsed:.1f}s")
        else:
            raise SystemExit("process rich fail fast: expected a ValueError")
        if elapsed > 10:
            raise SystemExit(f"process rich fail fast: returned only after {elapsed}s")
        # 24 items x 0.15s over 4 workers is ~0.9s of work: an uncancelled pool
        # has finished every one of them by the time this sleep is over.
        time.sleep(1.5)
        ran = seen.qsize()
    # At most the 4 running items plus the handful already handed to the call
    # queue may run; without the cancel every one of the 24 does.
    if ran > 16:
        raise SystemExit(f"process rich fail fast: {ran}/24 ran, nothing was cancelled")
    print(f"ok: process rich fail fast cancelled the queue ({ran} of 24 items ran)")
    print("All sanity checks passed.")
