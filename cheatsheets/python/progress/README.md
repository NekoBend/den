# Progress Bars x Parallelism - Copy-Paste Cheatsheet

One folder, one execution model per module. Every function is self-contained:
copy it, keep its imports, call it with your own function.

```
progress/
  sequential.py    plain loops, nested bars, logging without breaking the bar
  files.py         byte-based progress (copying files, streaming downloads)
  threads.py       ThreadPoolExecutor - IO-bound (network, disk, APIs)
  processes.py     ProcessPoolExecutor / multiprocessing.Pool - CPU-bound, plus
                   shards, blocks, per-worker bars and a thread pool per process
  mpire_pool.py    mpire - CPU-bound, max throughput, built-in tqdm/rich bars
  async_io.py      asyncio - massive concurrent IO (1000+ requests)
```

## Decision table

| Function                       | Module        | Best for                                  | GIL-free | Order | Failures        |
|--------------------------------|---------------|-------------------------------------------|----------|-------|-----------------|
| run_sequential_tqdm            | sequential    | debugging, simple scripts                 | n/a      | yes   | raise           |
| run_sequential_rich            | sequential    | pretty CLI apps (one-liner)               | n/a      | yes   | raise           |
| run_sequential_rich_detailed   | sequential    | count, elapsed, ETA columns               | n/a      | yes   | raise           |
| run_nested_tqdm                | sequential    | outer/inner bars (epochs x batches)       | n/a      | yes   | raise           |
| run_nested_rich                | sequential    | outer/inner bars, one live display        | n/a      | yes   | raise           |
| run_sequential_tqdm_with_log   | sequential    | printing while a tqdm bar is live         | n/a      | yes   | raise           |
| run_sequential_rich_with_log   | sequential    | printing while a rich bar is live         | n/a      | yes   | raise           |
| copy_file_tqdm                 | files         | bytes copied, human-readable units        | n/a      | n/a   | raise           |
| copy_file_rich                 | files         | bytes copied, speed + ETA columns         | n/a      | n/a   | raise           |
| consume_chunks_tqdm            | files         | streaming download (unknown total ok)     | n/a      | n/a   | raise           |
| consume_chunks_rich            | files         | streaming download, transfer columns      | n/a      | n/a   | raise           |
| run_thread_tqdm_easy           | threads       | IO-bound one-liner                        | no       | yes   | raise (first)   |
| run_thread_tqdm_manual         | threads       | IO-bound, per-item failures kept          | no       | yes   | as outcomes     |
| run_thread_rich                | threads       | IO-bound, pretty UI, failures kept        | no       | yes   | as outcomes     |
| run_thread_rich_per_task       | threads       | one bar per running item (downloads)      | no       | yes   | as outcomes     |
| run_process_tqdm_easy          | processes     | CPU-bound one-liner                       | yes      | yes   | raise (first)   |
| run_process_tqdm_manual        | processes     | CPU-bound, per-item failures kept         | yes      | yes   | as outcomes     |
| run_process_rich               | processes     | CPU-bound, pretty UI, failures kept       | yes      | yes   | as outcomes     |
| run_process_rich_ordered       | processes     | stream results in input order             | yes      | yes   | raise (first)   |
| run_process_rich_bounded       | processes     | huge / lazy iterables, bounded memory     | yes      | yes   | as outcomes     |
| run_process_rich_chunked       | processes     | millions of tiny items (less IPC)         | yes      | yes   | as outcomes     |
| run_process_rich_per_worker    | processes     | one bar per worker + inner progress       | yes      | yes   | as outcomes     |
| run_process_rich_fail_fast     | processes     | stop everything on the first failure      | yes      | yes   | raise + cancel  |
| run_pool_rich_imap             | processes     | stdlib Pool, lazy, finish order           | yes      | no    | raise (first)   |
| run_mpire                      | mpire_pool    | CPU-bound, max throughput (tqdm bar)      | yes      | yes   | raise (first)   |
| run_mpire_rich                 | mpire_pool    | CPU-bound, max throughput (rich bar)      | yes      | yes   | raise (first)   |
| run_mpire_lazy                 | mpire_pool    | mpire over a lazy iterable                | yes      | no    | raise (first)   |
| run_async_tqdm                 | async_io      | 1000+ concurrent requests, tqdm           | no       | yes   | as outcomes     |
| run_async_rich                 | async_io      | 1000+ concurrent requests, rich           | no       | yes   | as outcomes     |
| run_async_rich_as_completed    | async_io      | stream results as they finish             | no       | no    | as outcomes     |

- "Order: yes" = results are returned in input order.
- "Failures: as outcomes" = the function returns `list[R | BaseException]` in
  input order; a failed item holds its exception instead of a result, nothing
  is dropped and nothing is raised. Split with
  `[r for r in outcomes if not isinstance(r, BaseException)]`.
- "Failures: raise (first)" = the first exception propagates and stops the run.

## Dependencies

```
pip install tqdm rich mpire
```

Each function imports what it needs inside its body, so a copied function
carries its own imports; the module tops only import stdlib typing helpers.

## Pitfalls the sheets avoid

- **Printing while a bar is live** corrupts the display. tqdm: `tqdm.write()`.
  rich: `progress.log()` / `progress.console.print()` (rich also redirects a
  plain `print()` while `Progress` is running, tqdm does not).
- **Rich `Progress()` shows only the columns you give it.** `track()` and the
  default `Progress()` include elapsed/ETA; a custom column list does not
  unless you add `TimeElapsedColumn` / `TimeRemainingColumn` /
  `MofNCompleteColumn`.
- **Process pools pickle the function and its arguments.** The function must be
  a top-level `def` (no lambda, no closure, no function defined inside
  `if __name__ == "__main__":`). Under the `spawn` start method (macOS,
  Windows, and the Python 3.14 default on Linux) the child re-imports your
  module, so a function redefined inside the main guard does not exist there.
  Every sanity check in `processes.py` runs under `spawn` on purpose.
- **`as_completed` yields in finish order.** The sheets map each future back to
  its input index so the returned list is still in input order.
- **A `multiprocessing.Queue` cannot be passed to `executor.submit`.** Use a
  `multiprocessing.Manager().Queue()` proxy for worker-to-parent progress
  messages (`run_process_rich_per_worker`).
- **Submitting a million futures up front** holds a million pickled arguments
  in memory. Use `run_process_rich_bounded` (a fixed in-flight window) or
  `run_process_rich_chunked` (batches) instead.
- **Rich lives in the parent only.** A worker process cannot touch the
  parent's `Progress`: its lock is a `threading.RLock` and a `Console` does
  not pickle, so "using the same console" is not possible across processes
  (under `fork` the worker gets a copy that even replays the live display's
  control codes). The worker sends progress messages and a pump thread in
  the parent applies them (`run_process_rich_sharded`,
  `run_process_rich_per_worker`). Threads inside a process (`_threaded_block`)
  report through the same queue, so PPE x TPE nesting costs nothing extra.
- **Never print from a worker.** A `print` or `console.print` in a worker
  writes into the live area and leaves stale copies of the bars behind. The
  sharded and per-worker runners hand the worker a `log(text)` callback; the
  text travels over the progress queue and the parent prints it above the
  bars with `progress.log`. If your worker code logs through `logging`, the
  equivalent is a `QueueHandler` in the worker and a `QueueListener` with
  `RichHandler(console=progress.console)` in the parent.
- **A running process cannot be cancelled.** `shutdown(cancel_futures=True)`
  drops queued items only; the items already running finish first. Every
  runner calls it from a `finally`, so Ctrl-C ends the run instead of letting
  the pool drain, and it has to be `shutdown(wait=True, cancel_futures=True)`:
  with `wait=False` the executor's own `__exit__` calls `shutdown(wait=True)`
  immediately after, resetting the cancel flag before the pool acts on it, and
  nothing is cancelled at all.
