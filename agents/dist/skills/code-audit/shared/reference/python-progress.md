# Python reference: progress

Section 19 of the Python reference: progress reporting.
shared/reference/python.md lists where every section lives.

## 19. Progress reporting: count, elapsed, remaining

**Rule:** Work with a known item count shows a progress bar
that displays the count, the elapsed time and the estimated remaining time.
When output is not a terminal, the bar is disabled
and a log line (`logger.info("%d/%d done", done, total)`) takes its place,
written every 10% of the items or every 30 seconds, whichever comes first.

**Why:** a bar with only a percentage leaves the user's two questions
(how far, how long) unanswered;
a bar written to a log file fills it with carriage returns;
a `print` inside the loop tears the bar apart.

- tqdm: `tqdm(items, desc="convert", unit="file", disable=not sys.stderr.isatty())`.
  The default format already shows count, elapsed and remaining.
  While a bar is active, every message goes through `tqdm.write(msg, file=sys.stderr)`;
  without `file=`, `tqdm.write` prints to stdout.
  The log line of the Rule is written the same way as in the rich example below.
- rich: name the columns;
  the default `Progress()` shows description, bar, percentage and time remaining,
  with no count and no elapsed time.
  rich draws on stdout unless told otherwise,
  so the bar goes to the one `Console(stderr=True)`
  that the entry point builds (python-entry-point.md section 21)
  and is disabled when that console is not a terminal.
  `redirect_stdout=False` keeps data that the loop prints on stdout;
  without it, rich moves that data to the bar's stream.

```python
import logging
import time
from collections.abc import Callable, Sequence
from pathlib import Path

from rich.console import Console
from rich.progress import (
    BarColumn,
    MofNCompleteColumn,
    Progress,
    TextColumn,
    TimeElapsedColumn,
    TimeRemainingColumn,
)

logger = logging.getLogger(__name__)

COLUMNS = (
    TextColumn("[progress.description]{task.description}"),
    BarColumn(),
    MofNCompleteColumn(),
    TimeElapsedColumn(),
    TimeRemainingColumn(),
)


def convert_all(
    items: Sequence[Path], work: Callable[[Path], None], console: Console
) -> None:
    """Run `work` on every item: a bar on a terminal, log lines elsewhere."""
    total = len(items)
    on_terminal = console.is_terminal
    every = max(1, total // 10)  # a log line every 10% of the items
    last_log = time.monotonic()
    with Progress(
        *COLUMNS, console=console, disable=not on_terminal, redirect_stdout=False
    ) as progress:
        task = progress.add_task("convert", total=total)
        for done, item in enumerate(items, start=1):
            work(item)
            progress.advance(task)
            now = time.monotonic()
            due = done % every == 0 or done == total or now - last_log >= 30
            if not on_terminal and due:
                logger.info("%d/%d done", done, total)
                last_log = now
```

  Messages go through `progress.log(...)` or `progress.console.print(...)`.
- The total counts items, unless the work is byte-bound (a copy, a download);
  then the total is bytes, with `unit="B", unit_scale=True` in tqdm.
- Unknown total: a counter with `total=None` and the elapsed time, never a guessed total.
- Concurrency: advance the bar from the thread that collects results
  (the `as_completed` loop), for thread and process pools alike,
  not from inside the workers.
  Progress from inside one item of a process-pool worker
  travels over a `multiprocessing.Manager().Queue()`,
  never a plain `multiprocessing.Queue` (that cannot be passed to `submit`).
