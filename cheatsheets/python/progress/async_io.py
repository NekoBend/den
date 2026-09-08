"""asyncio Progress Bars - Copy-Paste Cheatsheet.

Massive concurrent IO (1000+ requests) on one event loop with tqdm / rich.

| Function                    | Best for                              | Order |
|-----------------------------|---------------------------------------|-------|
| run_async_tqdm              | 1000+ concurrent requests, tqdm       | yes   |
| run_async_rich              | 1000+ concurrent requests, rich       | yes   |
| run_async_rich_as_completed | Stream results as they finish         | no    |

Usage:
    1. Copy the function you need (its imports travel with it).
    2. Call it with your own ``async def func(item) -> result`` (httpx,
       aiohttp, asyncpg, ...) and ``await`` it inside ``asyncio.run``.

Dependencies:
    pip install tqdm rich

Note:
    - Every function returns ``list[R | BaseException]``: a failed item
      holds its exception; nothing is dropped, nothing raised.
    - ``concurrency`` bounds the in-flight coroutines with a semaphore so the
      server (and your file descriptors) survive 100k items.
    - Never block inside ``func``: ``time.sleep`` / ``requests`` freeze the
      loop and the bar with it. Use ``asyncio.sleep`` / ``httpx.AsyncClient``.
"""

import asyncio
from collections.abc import Awaitable, Callable, Sequence

# =============================================================================
# 1. gather with a bar
# =============================================================================


async def run_async_tqdm[T, R](
    items: Sequence[T], func: Callable[[T], Awaitable[R]], concurrency: int = 100
) -> list[R | BaseException]:
    """Await ``func`` for every item with tqdm's ``gather`` and a semaphore.

    [Best for] Thousands of API calls where threads would be too heavy.
    [Note] ``tqdm.asyncio.tqdm.gather`` advances as each coroutine finishes
           and still returns results in input order. It has no
           ``return_exceptions``, so ``guarded`` keeps failures as data.
    """
    from tqdm.asyncio import tqdm

    semaphore = asyncio.Semaphore(concurrency)

    async def guarded(item: T) -> R | BaseException:
        async with semaphore:
            try:
                return await func(item)
            except Exception as exc:  # ruff: ignore[blind-except] - kept as data, caller decides
                return exc

    return await tqdm.gather(*(guarded(item) for item in items), desc="AsyncIO (tqdm)")


async def run_async_rich[T, R](
    items: Sequence[T], func: Callable[[T], Awaitable[R]], concurrency: int = 100
) -> list[R | BaseException]:
    """Await ``func`` for every item with a rich bar and a semaphore.

    [Best for] The same fan-out with count, elapsed and ETA columns.
    [Note] ``asyncio.gather(return_exceptions=True)`` keeps input order and
           failures as data; the bar advances inside ``tracked`` so it moves
           as items finish, not when ``gather`` returns.
    """
    from rich.progress import (
        BarColumn,
        MofNCompleteColumn,
        Progress,
        SpinnerColumn,
        TextColumn,
        TimeElapsedColumn,
        TimeRemainingColumn,
    )

    semaphore = asyncio.Semaphore(concurrency)
    with Progress(
        SpinnerColumn(),
        TextColumn("[bold blue]{task.description}"),
        BarColumn(),
        MofNCompleteColumn(),
        TimeElapsedColumn(),
        TimeRemainingColumn(),
    ) as progress:
        task = progress.add_task("AsyncIO (rich)", total=len(items))

        async def tracked(item: T) -> R:
            async with semaphore:
                try:
                    return await func(item)
                finally:
                    progress.advance(task)

        return await asyncio.gather(
            *(tracked(item) for item in items), return_exceptions=True
        )


# =============================================================================
# 2. Stream results in finish order
# =============================================================================


async def run_async_rich_as_completed[T, R](
    items: Sequence[T], func: Callable[[T], Awaitable[R]], concurrency: int = 100
) -> list[R | BaseException]:
    """Await ``func`` for every item, handling each result as soon as it lands.

    [Best for] Pipelines that write each result out immediately (a file, a
               queue, a database) instead of holding all of them.
    [Note] ``asyncio.as_completed`` yields in finish order, so the returned
           list is in finish order too. The bar's description shows the last
           finished item.
    """
    from rich.progress import BarColumn, MofNCompleteColumn, Progress, TextColumn

    semaphore = asyncio.Semaphore(concurrency)

    async def guarded(item: T) -> tuple[T, R | BaseException]:
        async with semaphore:
            try:
                return item, await func(item)
            except Exception as exc:  # ruff: ignore[blind-except] - kept as data, caller decides
                return item, exc

    outcomes: list[R | BaseException] = []
    with Progress(
        TextColumn("[bold blue]{task.description}"),
        BarColumn(),
        MofNCompleteColumn(),
    ) as progress:
        task = progress.add_task("AsyncIO (as_completed)", total=len(items))
        for next_done in asyncio.as_completed([guarded(item) for item in items]):
            item, outcome = await next_done
            outcomes.append(outcome)
            progress.update(task, advance=1, description=f"last: {item!r}")
    return outcomes


# =============================================================================
# Quick Sanity Check
# =============================================================================


async def _demo_task(item: int) -> int:
    """Dummy IO: sleep briefly and double the item; item 7 always fails."""
    await asyncio.sleep(0.02)
    if item == 7:
        raise ValueError("item 7 is broken on purpose")
    return item * 2


def _check_outcomes(
    name: str, outcomes: list[int | BaseException], *, ordered: bool
) -> None:
    """Assert 20 outcomes, item 7 failed, the rest doubled (sorted if unordered)."""
    values = [outcome for outcome in outcomes if not isinstance(outcome, BaseException)]
    failures = [outcome for outcome in outcomes if isinstance(outcome, BaseException)]
    expected = [item * 2 for item in range(20) if item != 7]
    got = values if ordered else sorted(values)
    if len(failures) != 1 or got != expected:
        raise SystemExit(f"{name}: unexpected outcomes {outcomes!r}")
    if ordered and not isinstance(outcomes[7], BaseException):
        raise SystemExit(f"{name}: item 7 not at index 7: {outcomes!r}")
    print(f"ok: {name} (20 outcomes, item 7 failed as expected)")


async def _main() -> None:
    sample = list(range(20))
    _check_outcomes(
        "async tqdm",
        await run_async_tqdm(sample, _demo_task, concurrency=5),
        ordered=True,
    )
    _check_outcomes(
        "async rich",
        await run_async_rich(sample, _demo_task, concurrency=5),
        ordered=True,
    )
    _check_outcomes(
        "async rich as_completed",
        await run_async_rich_as_completed(sample, _demo_task, concurrency=5),
        ordered=False,
    )
    print("All sanity checks passed.")


if __name__ == "__main__":
    asyncio.run(_main())
