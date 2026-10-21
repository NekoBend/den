# Python reference: entry point

Sections 18 and 21 of the Python reference:
interrupt handling and logging setup.
shared/reference/python.md lists where every section lives.

## 18. Interrupt handling: Ctrl-C ends the run cleanly

**Rule:** A program that runs for more than a few seconds
catches `KeyboardInterrupt` exactly once, at the entry point,
finishes its cleanup, prints one line, and exits with status 130.
No other function catches it.

**Why:** an interrupted run that dumps a traceback,
leaves a half-written file,
or keeps worker processes alive
is worse than one that never handled the signal.
Catching the interrupt deep inside a loop hides it from the caller
and turns a stop request into a partial run that looks complete.

- Entry point shape:

```python
import sys


def run() -> int:
    # the program's work
    return 0


def main() -> int:
    try:
        return run()
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
```

- Cleanup lives in `finally` blocks and `with` statements,
  which run whether the function returns or the interrupt passes through.
- Executors: call `executor.shutdown(wait=True, cancel_futures=True)` in a `finally`.
  Items not yet handed to a worker are dropped.
  Items already handed to a worker still run:
  the running ones, plus the few a `ProcessPoolExecutor` has already queued to its workers.
  The `with` block exits after they finish.
  `wait=False` is wrong here for a `ProcessPoolExecutor`:
  its `with` exit then neither waits nor cancels
  (the exit's own `shutdown` resets the cancel flag).
- Workers of a `ProcessPoolExecutor` receive the same signal.
  A worker that must finish its current item
  installs `signal.signal(signal.SIGINT, signal.SIG_IGN)`
  in the pool's `initializer` (a module-level function, so it pickles);
  the parent's `finally` shutdown above then waits for that item.
  `ProcessPoolExecutor` has no call that terminates its workers before 3.14,
  and the 3.14 `terminate_workers()` and `kill_workers()` kill the running item.
- Files: write to a temporary path in the same directory
  and `os.replace` it into place at the end,
  so an interrupt leaves the old file or the new one, never a truncated one.
- `signal.signal` works only on the main thread; worker threads cannot install handlers.
- asyncio: `asyncio.run` already turns the signal into cancellation of the main task.
  Catch `asyncio.CancelledError` only to clean up, and re-raise it;
  put the cleanup in `finally` inside the coroutine.
- Exit status 130 is the convention for "terminated by Ctrl-C"; shells and callers test for it.

## 21. Logging setup

**Rule:** `logging.basicConfig(...)` is called once, in the entry point.
Every module uses `logger = logging.getLogger(__name__)`
and never configures handlers or levels itself.
Library code logs; it does not `print`.

**Why:** a module that configures logging at import time
fights the application's configuration and duplicates handlers;
a module that prints cannot be silenced or redirected by its caller.

- Entry point:

```python
import logging
import sys

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    stream=sys.stderr,
)
```

- Levels: `DEBUG` for values that matter only while diagnosing,
  `INFO` for milestones a user expects to see,
  `WARNING` for recoverable surprises,
  `ERROR` through `logger.exception(...)` where an exception is handled.
- Lazy formatting: `logger.info("processed %d files", n)`, not an f-string,
  so the message is built only when the level is enabled.
- Progress bars and logging share stderr,
  and while a bar is active every log record goes through the bar's own writer;
  otherwise every log line breaks the bar.
- tqdm: keep the entry point above,
  add `from tqdm.contrib.logging import logging_redirect_tqdm`,
  and wrap the loop in `with logging_redirect_tqdm():`.
  It sends each record through `tqdm.write` and keeps the handler's stderr stream.
- rich: the entry point configures logging this way instead,
  building the one console that `RichHandler` and every `Progress` (section 19) share:

```python
import logging

from rich.console import Console
from rich.logging import RichHandler

console = Console(stderr=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(message)s",
    handlers=[RichHandler(console=console)],
)
```

  `RichHandler` prints the time and the level itself, so the format is only `%(message)s`.
  There is no `stream=`:
  `basicConfig` raises `ValueError` when it gets both `stream=` and `handlers=`,
  and the console already writes to stderr.
- With den's cheatsheets installed (`den install cheatsheets`),
  structured JSON output, file rotation and per-request context are in
  `${XDG_DATA_HOME:-$HOME/.local/share}/den/cheatsheets/python/logging-config.py`.
