"""Parallel Processing & Progress Bar — Copy-Paste Cheatsheet.

Complete matrix: Execution Model × Progress Bar Library.

Quick-Reference Decision Table
==============================

| Pattern                  | Best For                        | Library             | GIL-Free | Order |
|--------------------------|---------------------------------|---------------------|----------|-------|
| run_sequential_tqdm      | Debugging, simple scripts       | tqdm                | N/A      | Yes   |
| run_sequential_rich      | Pretty CLI apps                 | rich                | N/A      | Yes   |
| run_thread_tqdm_easy     | IO-bound (one-liner)            | tqdm.concurrent     | No       | Yes   |
| run_thread_tqdm_manual   | IO-bound (error handling)       | concurrent.futures  | No       | No    |
| run_thread_rich          | IO-bound (pretty UI)            | rich + futures      | No       | No    |
| run_process_tqdm_easy    | CPU-bound (one-liner)           | tqdm.concurrent     | Yes      | Yes   |
| run_process_tqdm_manual  | CPU-bound (error handling)      | concurrent.futures  | Yes      | No    |
| run_process_rich         | CPU-bound (pretty UI)           | rich + futures      | Yes      | No    |
| run_mpire                | CPU-bound (max perf)            | mpire               | Yes      | Yes   |
| run_async_tqdm           | Massive concurrent IO (1000+)   | asyncio + tqdm      | No       | Yes   |
| run_async_rich           | Massive concurrent IO (pretty)  | asyncio + rich      | No       | Yes   |

Usage:
    1. Copy the function you need into your project.
    2. Replace ``your_function(item)`` with your actual logic.
    3. Adjust ``max_workers`` to match your workload.

Dependencies:
    pip install tqdm rich mpire

Note:
    - "Order: Yes" = results preserve input order.
    - "Order: No"  = as_completed yields in finish order.
    - For ProcessPoolExecutor / mpire, the worker function must be picklable
      (top-level ``def``, no lambdas, no closures).
"""


def your_function(item: object) -> object:
    """Placeholder — replace with your actual processing logic."""
    raise NotImplementedError("Replace your_function with your actual logic")


# =============================================================================
# 0. Sequential — Debugging & Simple Tasks
# =============================================================================


def run_sequential_tqdm(items: list) -> list:
    """Run items sequentially with a tqdm progress bar.

    [Best for] Simple scripts, debugging, strict ordering.
    [Note] Zero overhead — baseline for benchmarking parallel approaches.
    """
    from tqdm import tqdm

    results = []
    for item in tqdm(items, desc="Sequential"):
        result = your_function(item)  # Replace with your logic
        results.append(result)
    return results


def run_sequential_rich(items: list) -> list:
    """Run items sequentially with a Rich progress bar.

    [Best for] CLI apps where aesthetics matter.
    [Note] Rich auto-renders elapsed time, ETA, and spinner.
    """
    from rich.progress import track

    results = []
    for item in track(items, description="[green]Sequential..."):
        result = your_function(item)  # Replace with your logic
        results.append(result)
    return results


# =============================================================================
# 1. ThreadPoolExecutor — IO-Bound (Network, Disk, API calls)
# =============================================================================


def run_thread_tqdm_easy(items: list, max_workers: int = 8) -> list:
    """Parallel IO with thread_map — tqdm one-liner.

    [Best for] Network/disk IO — fire-and-forget parallelism.
    [Note] Preserves input order. Returns list of results directly.
    """
    from tqdm.contrib.concurrent import thread_map

    results = thread_map(
        your_function,  # Replace with your logic
        items,
        max_workers=max_workers,
        desc="Threads (easy)",
    )
    return results


def run_thread_tqdm_manual(items: list, max_workers: int = 8) -> list:
    """Parallel IO with ThreadPoolExecutor + as_completed + tqdm.

    [Best for] IO tasks needing per-task error handling or early stopping.
    [Note] as_completed yields in finish order (NOT input order).
    """
    from concurrent.futures import ThreadPoolExecutor, as_completed

    from tqdm import tqdm

    results: list = []

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_to_item = {executor.submit(your_function, item): item for item in items}

        for future in tqdm(
            as_completed(future_to_item),
            total=len(items),
            desc="Threads (manual)",
        ):
            try:
                results.append(future.result())
            except Exception as exc:
                item = future_to_item[future]
                print(f"Task {item!r} failed: {exc}")

    return results


def run_thread_rich(items: list, max_workers: int = 8) -> list:
    """Parallel IO with ThreadPoolExecutor + as_completed + Rich.

    [Best for] IO-bound tasks where you want a beautiful terminal UI.
    [Note] as_completed yields in finish order (NOT input order).
    """
    from concurrent.futures import ThreadPoolExecutor, as_completed

    from rich.progress import (
        BarColumn,
        Progress,
        SpinnerColumn,
        TaskProgressColumn,
        TextColumn,
    )

    results: list = []

    with Progress(
        SpinnerColumn(),
        TextColumn("[bold blue]{task.description}"),
        BarColumn(),
        TaskProgressColumn(),
    ) as progress:
        task_id = progress.add_task("Threads (rich)", total=len(items))

        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = {executor.submit(your_function, item): item for item in items}
            for future in as_completed(futures):
                try:
                    results.append(future.result())
                except Exception as exc:
                    item = futures[future]
                    print(f"Task {item!r} failed: {exc}")
                progress.advance(task_id)

    return results


# =============================================================================
# 2. ProcessPoolExecutor — CPU-Bound (Calculations, Image processing)
# =============================================================================


def run_process_tqdm_easy(items: list, max_workers: int = 4) -> list:
    """Parallel CPU with process_map — tqdm one-liner.

    [Best for] Heavy CPU work — bypasses the GIL.
    [Note] Worker function must be picklable (top-level def, no lambdas).
    """
    from tqdm.contrib.concurrent import process_map

    results = process_map(
        your_function,  # Replace: must be a top-level function
        items,
        max_workers=max_workers,
        desc="Processes (easy)",
        chunksize=1,
    )
    return results


def run_process_tqdm_manual(items: list, max_workers: int = 4) -> list:
    """Parallel CPU with ProcessPoolExecutor + as_completed + tqdm.

    [Best for] CPU tasks needing per-task error handling or early stopping.
    [Note] as_completed yields in finish order (NOT input order).
           Worker function must be picklable (top-level def).
    """
    from concurrent.futures import ProcessPoolExecutor, as_completed

    from tqdm import tqdm

    results: list = []

    with ProcessPoolExecutor(max_workers=max_workers) as executor:
        future_to_item = {executor.submit(your_function, item): item for item in items}

        for future in tqdm(
            as_completed(future_to_item),
            total=len(items),
            desc="Processes (manual)",
        ):
            try:
                results.append(future.result())
            except Exception as exc:
                item = future_to_item[future]
                print(f"Task {item!r} failed: {exc}")

    return results


def run_process_rich(items: list, max_workers: int = 4) -> list:
    """Parallel CPU with ProcessPoolExecutor + as_completed + Rich.

    [Best for] CPU-bound tasks where you want a beautiful terminal UI.
    [Note] as_completed yields in finish order (NOT input order).
           Worker function must be picklable (top-level def).
    """
    from concurrent.futures import ProcessPoolExecutor, as_completed

    from rich.progress import (
        BarColumn,
        Progress,
        SpinnerColumn,
        TaskProgressColumn,
        TextColumn,
    )

    results: list = []

    with Progress(
        SpinnerColumn(),
        TextColumn("[bold blue]{task.description}"),
        BarColumn(),
        TaskProgressColumn(),
    ) as progress:
        task_id = progress.add_task("Processes (rich)", total=len(items))

        with ProcessPoolExecutor(max_workers=max_workers) as executor:
            futures = {executor.submit(your_function, item): item for item in items}
            for future in as_completed(futures):
                try:
                    results.append(future.result())
                except Exception as exc:
                    item = futures[future]
                    print(f"Task {item!r} failed: {exc}")
                progress.advance(task_id)

    return results


# =============================================================================
# 3. mpire — CPU-Bound, Advanced (Shared memory, fork, built-in progress)
# =============================================================================


def run_mpire(items: list, max_workers: int = 4) -> list:
    """Parallel CPU with mpire — built-in tqdm progress bar.

    [Best for] Heavy CPU tasks needing maximum throughput + progress bar.
    [Note] Faster than stdlib multiprocessing (shared memory, fork).
           Worker function must be picklable (top-level def).
    """
    from mpire import WorkerPool

    with WorkerPool(n_jobs=max_workers) as pool:
        results = pool.map(
            your_function,  # Replace with your logic
            items,
            progress_bar=True,
            progress_bar_options={"desc": "mpire"},
        )
    return results


# =============================================================================
# 4. AsyncIO — Massive Concurrent IO (1000+ requests)
# =============================================================================


async def run_async_tqdm(items: list) -> list:
    """Massive concurrent IO with asyncio + tqdm.

    [Best for] Thousands of API/web requests where thread overhead is too high.
    [Note] Replace async_task with your real async function (aiohttp, httpx, etc.).
           Semaphore controls concurrency — adjust to avoid overwhelming the server.
    """
    import asyncio

    from tqdm.asyncio import tqdm

    async def async_task(item: object) -> object:
        """Replace with your async logic (e.g., aiohttp.get)."""
        await asyncio.sleep(0.1)  # Simulate IO
        return item

    semaphore = asyncio.Semaphore(100)

    async def limited_task(item: object) -> object:
        async with semaphore:
            return await async_task(item)

    results = await tqdm.gather(
        *[limited_task(item) for item in items],
        desc="AsyncIO (tqdm)",
    )
    return list(results)


async def run_async_rich(items: list) -> list:
    """Massive concurrent IO with asyncio + Rich progress bar.

    [Best for] Thousands of async requests with a beautiful terminal UI.
    [Note] Replace async_task with your real async function (aiohttp, httpx, etc.).
           Semaphore controls concurrency — adjust to avoid overwhelming the server.
    """
    import asyncio

    from rich.progress import (
        BarColumn,
        Progress,
        SpinnerColumn,
        TaskProgressColumn,
        TextColumn,
    )

    async def async_task(item: object) -> object:
        """Replace with your async logic (e.g., aiohttp.get)."""
        await asyncio.sleep(0.1)  # Simulate IO
        return item

    semaphore = asyncio.Semaphore(100)

    with Progress(
        SpinnerColumn(),
        TextColumn("[bold blue]{task.description}"),
        BarColumn(),
        TaskProgressColumn(),
    ) as progress:
        task_id = progress.add_task("AsyncIO (rich)", total=len(items))

        async def tracked_task(item: object) -> object:
            async with semaphore:
                result = await async_task(item)
                progress.advance(task_id)
                return result

        results = await asyncio.gather(*[tracked_task(item) for item in items])

    return list(results)


# =============================================================================
# Quick Sanity Check
# =============================================================================

if __name__ == "__main__":
    import asyncio
    import time

    def your_function(item: int) -> int:  # noqa: F811
        """Dummy task — replace with your real logic."""
        time.sleep(0.05)
        return item * 2

    sample = list(range(20))

    # --- Sequential ---
    print("=== Sequential (tqdm) ===")
    r = run_sequential_tqdm(sample)
    print(f"  {len(r)} results: {r[:5]}...")

    # --- Threads ---
    print("\n=== Thread (tqdm easy) ===")
    r = run_thread_tqdm_easy(sample, max_workers=4)
    print(f"  {len(r)} results: {r[:5]}...")

    print("\n=== Thread (tqdm manual) ===")
    r = run_thread_tqdm_manual(sample, max_workers=4)
    print(f"  {len(r)} results: {r[:5]}...")

    # --- AsyncIO ---
    print("\n=== AsyncIO (tqdm) ===")
    r = asyncio.run(run_async_tqdm(sample))
    print(f"  {len(r)} results: {r[:5]}...")

    print("\nAll sanity checks passed.")
