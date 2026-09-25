"""Sequential Progress Bars - Copy-Paste Cheatsheet.

Plain loops with tqdm / rich, nested bars, and printing while a bar is live.

| Function                     | Best for                              | Returns |
|------------------------------|---------------------------------------|---------|
| run_sequential_tqdm          | Debugging, simple scripts             | list[R] |
| run_sequential_rich          | Pretty CLI apps (one-liner)           | list[R] |
| run_sequential_rich_detailed | Count, elapsed and ETA columns        | list[R] |
| run_nested_tqdm              | Outer/inner bars (epochs x batches)   | list[R] |
| run_nested_rich              | Outer/inner bars in one live display  | list[R] |
| run_sequential_tqdm_with_log | Printing while a tqdm bar is live     | list[R] |
| run_sequential_rich_with_log | Printing while a rich bar is live     | list[R] |

Usage:
    1. Copy the function you need (its imports travel with it).
    2. Call it with your own ``func(item) -> result``.

Dependencies:
    pip install tqdm rich

Note:
    Every function here raises on the first failure: a sequential loop has
    nothing else in flight, so let the exception propagate and fix the input.
"""

from collections.abc import Callable, Sequence

# =============================================================================
# 1. One bar over a list
# =============================================================================


def run_sequential_tqdm[T, R](items: Sequence[T], func: Callable[[T], R]) -> list[R]:
    """Run ``func`` over ``items`` with a tqdm bar.

    [Best for] Simple scripts and debugging; the zero-overhead baseline.
    [Note] ``dynamic_ncols`` follows terminal resizes; ``unit`` names the items.
    """
    from tqdm import tqdm

    return [
        func(item)
        for item in tqdm(items, desc="Sequential", unit="item", dynamic_ncols=True)
    ]


def run_sequential_rich[T, R](items: Sequence[T], func: Callable[[T], R]) -> list[R]:
    """Run ``func`` over ``items`` with rich's one-liner ``track``.

    [Best for] CLI apps where aesthetics matter.
    [Note] ``track`` ships description, bar, percentage and time remaining -
           the same four as ``Progress.get_default_columns()``, with no
           elapsed column and no "n/total" (the ETA turns into the elapsed
           time once the task is finished). Pass ``total=`` when ``items``
           has no ``len()``.
    """
    from rich.progress import track

    return [func(item) for item in track(items, description="[green]Sequential")]


def run_sequential_rich_detailed[T, R](
    items: Sequence[T], func: Callable[[T], R]
) -> list[R]:
    """Run ``func`` over ``items`` with an explicit rich column set.

    [Best for] Long runs where "n/total", elapsed and remaining time matter.
    [Note] A custom ``Progress(...)`` shows ONLY the columns you list; the
           elapsed/ETA columns are not added for you.
    """
    from rich.progress import (
        BarColumn,
        MofNCompleteColumn,
        Progress,
        SpinnerColumn,
        TaskProgressColumn,
        TextColumn,
        TimeElapsedColumn,
        TimeRemainingColumn,
    )

    results: list[R] = []
    with Progress(
        SpinnerColumn(),
        TextColumn("[bold blue]{task.description}"),
        BarColumn(),
        MofNCompleteColumn(),
        TaskProgressColumn(),
        TimeElapsedColumn(),
        TimeRemainingColumn(),
    ) as progress:
        task = progress.add_task("Sequential (detailed)", total=len(items))
        for item in items:
            results.append(func(item))
            progress.advance(task)
    return results


# =============================================================================
# 2. Nested bars (outer groups x inner items)
# =============================================================================


def run_nested_tqdm[T, R](
    groups: Sequence[Sequence[T]], func: Callable[[T], R]
) -> list[R]:
    """Run ``func`` over groups of items with an outer and an inner tqdm bar.

    [Best for] Epochs x batches, files x lines, users x requests.
    [Note] ``position`` pins each bar to its own line; ``leave=False`` clears
           the inner bar when its group finishes so the screen does not fill up.
    """
    from tqdm import tqdm

    results: list[R] = []
    for index, group in enumerate(tqdm(groups, desc="Groups", position=0)):
        inner = tqdm(group, desc=f"Group {index}", position=1, leave=False)
        results.extend(func(item) for item in inner)
    return results


def run_nested_rich[T, R](
    groups: Sequence[Sequence[T]], func: Callable[[T], R]
) -> list[R]:
    """Run ``func`` over groups of items with two tasks in one rich display.

    [Best for] The same shape as ``run_nested_tqdm`` with a single live area.
    [Note] One ``Progress`` owns both tasks; ``reset`` restarts the inner task
           (and its speed/ETA estimate) for every group.
    """
    from rich.progress import (
        BarColumn,
        MofNCompleteColumn,
        Progress,
        TextColumn,
        TimeRemainingColumn,
    )

    results: list[R] = []
    with Progress(
        TextColumn("[bold blue]{task.description}"),
        BarColumn(),
        MofNCompleteColumn(),
        TimeRemainingColumn(),
    ) as progress:
        outer = progress.add_task("Groups", total=len(groups))
        inner = progress.add_task("Group", total=0)
        for index, group in enumerate(groups):
            progress.reset(inner, total=len(group), description=f"Group {index}")
            for item in group:
                results.append(func(item))
                progress.advance(inner)
            progress.advance(outer)
    return results


# =============================================================================
# 3. Printing while a bar is live
# =============================================================================


def run_sequential_tqdm_with_log[T, R](
    items: Sequence[T], func: Callable[[T], R]
) -> list[R]:
    """Run ``func`` with a tqdm bar and log lines that do not break the bar.

    [Best for] Scripts that print per-item messages.
    [Note] ``tqdm.write`` prints above the bar; a plain ``print`` would leave
           a broken bar on every line. ``set_postfix`` shows live key=value
           fields at the end of the bar.
    """
    from tqdm import tqdm

    results: list[R] = []
    with tqdm(total=len(items), desc="Sequential (log)") as bar:
        for item in items:
            result = func(item)
            results.append(result)
            bar.set_postfix(last=repr(item))
            bar.update()
            tqdm.write(f"done: {item!r} -> {result!r}")
    return results


def run_sequential_rich_with_log[T, R](
    items: Sequence[T], func: Callable[[T], R]
) -> list[R]:
    """Run ``func`` with a rich bar and log lines that do not break the bar.

    [Best for] Scripts that print per-item messages.
    [Note] ``progress.log`` adds a timestamp; ``progress.console.print`` does
           not. Rich also redirects a plain ``print`` while the bar is live,
           but only if ``redirect_stdout`` stays at its default of ``True``.
    """
    from rich.progress import BarColumn, Progress, TextColumn, TimeElapsedColumn

    results: list[R] = []
    with Progress(
        TextColumn("[bold blue]{task.description}"),
        BarColumn(),
        TimeElapsedColumn(),
    ) as progress:
        task = progress.add_task("Sequential (log)", total=len(items))
        for item in items:
            result = func(item)
            results.append(result)
            progress.advance(task)
            progress.log(f"done: {item!r} -> {result!r}")
    return results


# =============================================================================
# Quick Sanity Check
# =============================================================================


def _demo_task(item: int) -> int:
    """Dummy work: sleep briefly and double the item."""
    import time

    time.sleep(0.02)
    return item * 2


def _boom_task(item: int) -> int:
    """Dummy work that fails on item 3: a sequential loop must let it out."""
    if item == 3:
        raise ValueError("item 3 is broken on purpose")
    return item * 2


def _check_raises(name: str, run: Callable[[], object]) -> None:
    """Assert ``run()`` propagates the first failure (this module's contract)."""
    try:
        run()
    except ValueError as exc:
        print(f"ok: {name} raised {exc!r}")
    else:
        raise SystemExit(f"{name}: expected the failure to propagate")


if __name__ == "__main__":
    sample = list(range(20))
    expected = [item * 2 for item in sample]
    groups = [sample[0:7], sample[7:14], sample[14:20]]
    head = sample[:5]

    checks: list[tuple[str, list[int], list[int]]] = [
        ("sequential tqdm", run_sequential_tqdm(sample, _demo_task), expected),
        ("sequential rich", run_sequential_rich(sample, _demo_task), expected),
        (
            "sequential rich detailed",
            run_sequential_rich_detailed(sample, _demo_task),
            expected,
        ),
        ("nested tqdm", run_nested_tqdm(groups, _demo_task), expected),
        ("nested rich", run_nested_rich(groups, _demo_task), expected),
        (
            "tqdm with log",
            run_sequential_tqdm_with_log(head, _demo_task),
            expected[: len(head)],
        ),
        (
            "rich with log",
            run_sequential_rich_with_log(head, _demo_task),
            expected[: len(head)],
        ),
    ]
    for name, results, want in checks:
        if len(results) != len(want):
            raise SystemExit(f"{name}: {len(results)} results, expected {len(want)}")
        if results != want:
            raise SystemExit(f"{name}: unexpected results {results!r}")
        print(f"ok: {name} ({len(results)} results in input order)")

    _check_raises("sequential tqdm", lambda: run_sequential_tqdm(sample, _boom_task))
    _check_raises("sequential rich", lambda: run_sequential_rich(sample, _boom_task))
    _check_raises(
        "sequential rich detailed",
        lambda: run_sequential_rich_detailed(sample, _boom_task),
    )
    _check_raises("nested tqdm", lambda: run_nested_tqdm(groups, _boom_task))
    _check_raises("nested rich", lambda: run_nested_rich(groups, _boom_task))
    _check_raises(
        "tqdm with log", lambda: run_sequential_tqdm_with_log(head, _boom_task)
    )
    _check_raises(
        "rich with log", lambda: run_sequential_rich_with_log(head, _boom_task)
    )
    print("All sanity checks passed.")
