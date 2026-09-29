"""cheatsheets/python/progress: the rich runners keep their "as outcomes" promise.

The sheets are imported by module name from their own directory, because
process pools pickle ``processes._apply_block`` (and the worker functions
below) by reference and the workers have to import them again. They need rich;
without it these tests are skipped.
"""

import asyncio
import importlib
import multiprocessing
import os
import queue
import sys
import time
import traceback
from collections.abc import Callable, Iterator, Sequence
from pathlib import Path

import pytest

Progress = pytest.importorskip("rich.progress").Progress
Text = pytest.importorskip("rich.text").Text

PROGRESS_DIR = Path(__file__).resolve().parents[2] / "cheatsheets/python/progress"
if str(PROGRESS_DIR) not in sys.path:
    # Module scope, not a fixture: a spawned worker re-imports this test module
    # to unpickle the functions below, and needs the sheets importable too.
    sys.path.insert(0, str(PROGRESS_DIR))
async_io = importlib.import_module("async_io")
files = importlib.import_module("files")
processes = importlib.import_module("processes")
sequential = importlib.import_module("sequential")
threads = importlib.import_module("threads")


@pytest.fixture(autouse=True)
def wide_console(monkeypatch):
    # rich reads COLUMNS on every size query: keep log lines unwrapped.
    monkeypatch.setenv("COLUMNS", "300")


@pytest.fixture(autouse=True)
def spawn_workers() -> Iterator[None]:
    # The sheets' own sanity check runs under spawn, and so do these tests:
    # forking while rich's refresh thread runs (the 3.12/3.13 Linux default)
    # can deadlock the child. Restored afterwards for the rest of the session.
    before = multiprocessing.get_start_method(allow_none=True)
    multiprocessing.set_start_method("spawn", force=True)
    yield
    multiprocessing.set_start_method(before, force=True)


# --- worker functions: top level, so a process pool can pickle them ----------


def _double(item: int) -> int:
    return item * 2


def _die_on_5(item: int) -> int:
    if item == 5:
        os._exit(1)  # an OOM kill or a segfault, as far as the pool can tell
    time.sleep(0.01)
    return item * 2


def _bracket_log_block(block: Sequence[int], log: Callable[[str], None]) -> list[int]:
    log(f"path=[/srv/data/{block[0]}]")
    return [record * 2 for record in block]


def _bracket_step(
    item: str, report: Callable[[int, int], None], log: Callable[[str], None]
) -> str:
    report(1, 1)
    log(f"saw {item}")
    return item.upper()


def _value_error_on_1(item: int) -> int:
    if item == 1:
        raise ValueError("bad item")
    return item


def _key_error_on_2(item: int) -> int:
    if item == 2:
        raise KeyError("[/etc/app.conf]")
    return item * 2


def _step(item: str, advance: Callable[[int], None]) -> str:
    advance(1)
    return item.upper()


# --- helpers ------------------------------------------------------------------


@pytest.fixture
def descriptions(monkeypatch) -> Iterator[list[str]]:
    """Record every task description handed to Progress.add_task / update."""
    seen: list[str] = []
    add_task = Progress.add_task
    update = Progress.update

    def spy_add_task(self, description, *args, **kwargs):
        seen.append(description)
        return add_task(self, description, *args, **kwargs)

    def spy_update(self, task_id, *args, **kwargs):
        if kwargs.get("description") is not None:
            seen.append(kwargs["description"])
        return update(self, task_id, *args, **kwargs)

    monkeypatch.setattr(Progress, "add_task", spy_add_task)
    monkeypatch.setattr(Progress, "update", spy_update)
    return seen


def _plain(markup: str) -> str:
    """What rich's TextColumn shows for a description (raises MarkupError)."""
    return Text.from_markup(markup).plain


# --- run_process_rich_bounded -------------------------------------------------


def test_bounded_batches_tiny_items(monkeypatch):
    # One future per item capped the runner at a few thousand items per
    # second; batch_size sends a block of items per future instead.
    from concurrent.futures import ProcessPoolExecutor

    submits: list[int] = []
    submit = ProcessPoolExecutor.submit

    def counting_submit(self, fn, /, *args, **kwargs):
        submits.append(1)
        return submit(self, fn, *args, **kwargs)

    monkeypatch.setattr(ProcessPoolExecutor, "submit", counting_submit)
    outcomes = processes.run_process_rich_bounded(
        iter(range(1000)), _double, max_workers=2, total=1000, batch_size=100
    )
    assert outcomes == [item * 2 for item in range(1000)]
    assert len(submits) == 10


def test_bounded_keeps_per_item_failures_inside_a_batch():
    outcomes = processes.run_process_rich_bounded(
        iter(range(20)), processes._demo_task, max_workers=2, batch_size=6
    )
    assert len(outcomes) == 20
    assert isinstance(outcomes[7], ValueError)
    assert [o for i, o in enumerate(outcomes) if i != 7] == [
        i * 2 for i in range(20) if i != 7
    ]


@pytest.mark.parametrize("batch_size", [1, 2])
def test_bounded_failures_keep_the_worker_traceback(batch_size):
    # Submitting func itself, the per-item mode's failures carried the
    # worker's traceback as __cause__; through _apply_block the exception came
    # back bare, with no trace of where in the worker it was raised.
    outcomes = processes.run_process_rich_bounded(
        iter(range(3)), _value_error_on_1, max_workers=2, batch_size=batch_size
    )
    assert [outcomes[0], outcomes[2]] == [0, 2]
    assert isinstance(outcomes[1], ValueError)
    shown = "".join(traceback.format_exception(outcomes[1]))
    assert "in _value_error_on_1" in shown
    assert 'raise ValueError("bad item")' in shown


def test_bounded_returns_outcomes_when_a_worker_dies():
    # A dead worker breaks the pool; the next submit raised BrokenProcessPool
    # out of the runner and every outcome collected so far was lost.
    from concurrent.futures.process import BrokenProcessPool

    outcomes = processes.run_process_rich_bounded(
        iter(range(40)), _die_on_5, max_workers=2, total=40
    )
    assert len(outcomes) == 40
    assert isinstance(outcomes[5], BrokenProcessPool)
    for index, outcome in enumerate(outcomes):
        assert isinstance(outcome, BrokenProcessPool) or outcome == index * 2


# --- _report_to_queue -----------------------------------------------------------


def test_report_is_throttled_and_still_delivers_the_end_state():
    # Every report() was a blocking Manager round trip; per-step reporting
    # multiplied the worker's run time.
    reports: queue.Queue = queue.Queue()

    def per_step(item: int, report, log) -> int:
        for step in range(1, 10_001):
            report(step, 10_000)
        return item

    assert processes._report_to_queue(per_step, 3, reports) == 3
    sent = [reports.get_nowait() for _ in range(reports.qsize())]
    assert len(sent) < 100
    assert (sent[-1].done, sent[-1].total) == (10_000, 10_000)


def test_report_flushes_the_last_held_back_update():
    reports: queue.Queue = queue.Queue()

    def partial(item: int, report, log) -> int:
        report(1, 10)
        report(2, 10)
        report(3, 10)
        return item

    processes._report_to_queue(partial, 0, reports)
    sent = [reports.get_nowait() for _ in range(reports.qsize())]
    assert (sent[-1].done, sent[-1].total) == (3, 10)


# --- rich markup: logs and descriptions are data --------------------------------


def test_thread_rich_logs_bracketed_errors_and_returns_outcomes(capsys):
    outcomes = threads.run_thread_rich(list(range(4)), _key_error_on_2, max_workers=2)
    assert [o for i, o in enumerate(outcomes) if i != 2] == [0, 2, 6]
    assert isinstance(outcomes[2], KeyError)
    assert "KeyError('[/etc/app.conf]')" in capsys.readouterr().out


def test_process_rich_logs_bracketed_errors_and_returns_outcomes(capsys):
    outcomes = processes.run_process_rich(["1", "2", "[/b]"], int, max_workers=2)
    assert outcomes[:2] == [1, 2]
    assert isinstance(outcomes[2], ValueError)
    assert "'[/b]'" in capsys.readouterr().out


def test_sequential_rich_with_log_prints_bracketed_items():
    assert sequential.run_sequential_rich_with_log(["ok", "x[/b]y"], str.upper) == [
        "OK",
        "X[/B]Y",
    ]


def test_sharded_pump_prints_bracketed_worker_logs(capsys):
    # The pump thread died on the first "[/..." and every later line was lost.
    outcomes = processes.run_process_rich_sharded(
        list(range(40)), _bracket_log_block, max_workers=2, block_size=10
    )
    assert outcomes == [record * 2 for record in range(40)]
    out = capsys.readouterr().out
    for start in (0, 10, 20, 30):
        assert f"path=[/srv/data/{start}]" in out


def test_per_worker_escapes_labels_and_prints_worker_logs(capsys, descriptions):
    items = ["[/x]", "[bold]y"]
    outcomes = processes.run_process_rich_per_worker(
        items, _bracket_step, max_workers=2
    )
    assert outcomes == ["[/X]", "[BOLD]Y"]
    shown = [_plain(d) for d in descriptions if d.startswith("pid ")]
    for item in items:
        assert any(text.endswith(f": {item!r}") for text in shown)
    out = capsys.readouterr().out
    for item in items:
        assert f"saw {item}" in out


def test_thread_per_task_escapes_item_descriptions(descriptions):
    items = ["[/x]", "[bold]y", "plain"]
    assert threads.run_thread_rich_per_task(items, _step, steps_per_item=1) == [
        "[/X]",
        "[BOLD]Y",
        "PLAIN",
    ]
    shown = [_plain(d) for d in descriptions]
    for item in items:
        assert repr(item) in shown


def test_async_as_completed_escapes_the_last_item_description(descriptions):
    async def upper(item: str) -> str:
        await asyncio.sleep(0)
        return item.upper()

    outcomes = asyncio.run(async_io.run_async_rich_as_completed(["[/x]"], upper))
    assert outcomes == ["[/X]"]
    assert "last: '[/x]'" in [_plain(d) for d in descriptions]


def test_copy_file_rich_escapes_the_file_name(descriptions, tmp_path):
    src = tmp_path / "[draft] clip.bin"
    src.write_bytes(b"x" * 100)
    assert files.copy_file_rich(src, tmp_path / "out.bin") == 100
    assert "[draft] clip.bin" in [_plain(d) for d in descriptions]


# --- run_thread_rich_per_task: one live task per running item -------------------


def test_thread_per_task_holds_only_the_running_items_tasks(monkeypatch):
    # A hidden task per item was created up front and never removed: each
    # kept up to 1000 speed samples until the whole run ended.
    peak = [0]
    add_task = Progress.add_task

    def counting_add_task(self, *args, **kwargs):
        task_id = add_task(self, *args, **kwargs)
        peak[0] = max(peak[0], len(self.tasks))
        return task_id

    monkeypatch.setattr(Progress, "add_task", counting_add_task)
    items = [str(i) for i in range(20)]
    assert threads.run_thread_rich_per_task(items, _step, max_workers=2) == items
    assert peak[0] <= 3  # the overall bar plus one per worker
