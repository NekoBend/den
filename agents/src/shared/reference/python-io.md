# Python reference: waiting on the outside

Sections 8, 17, and 20 of the Python reference:
async hygiene, subprocess hygiene, and timeouts.
shared/reference/python.md lists where every section lives.

## 8. Async hygiene

**Rule:** Inside `async def`,
only call functions that are themselves async or known to be non-blocking.
Replace blocking stdlib / library calls with their async counterparts:

- `asyncio.sleep` instead of `time.sleep`.
- `httpx.AsyncClient` (or `aiohttp`) instead of `requests`.
- `aiofiles` instead of synchronous `open` for non-trivial file I/O.
- `asyncio.to_thread` (3.9+) to delegate genuinely blocking work to a thread pool
  when no async equivalent exists;
  on older Python, use `asyncio.get_running_loop().run_in_executor(None, func, *args)`.

**Why:** A single blocking call freezes the event loop
and stalls every other coroutine waiting on it.
This collapses async throughput to worse than synchronous.
**Example:**

```python
async def fetch_all(urls: list[str]) -> list[bytes]:
    async with httpx.AsyncClient() as client:
        responses = await asyncio.gather(*(client.get(u) for u in urls))
    return [r.content for r in responses]
```

## 17. Subprocess hygiene

**Rule:** `subprocess.run` with argv as a list,
and `sys.executable` (never a literal `"python"`) for Python children.
`os.system` and `os.popen` do not appear in new code.

**Why:** each pin below closes an injection, a hang, or a silent
failure the model knows about but reliably under-applies.

- `shell=True` with interpolated input is command injection.
  When a shell feature is genuinely required,
  `shlex.quote` every substituted value - POSIX only:
  there is no safe quoting for `cmd.exe`,
  so on Windows keep `shell=False`.
- Pass `timeout=` on bounded operations.
  A child that is legitimately long-running or interactive
  (a network install, a watch mode) has no sane fixed timeout;
  leaving it off is then a decision to state, not an oversight.
- Decide error handling explicitly:
  `check=True` (raise) or a branch on `returncode`.
  Silently ignoring the return code is the bug.
- Text versus bytes is a decision, not a default:
  `text=True` normalizes `\r\n` to `\n`, which is right for parsing;
  bytes mode preserves the child's exact output,
  which is what hashing or byte-faithful round-trips need.

## 20. Timeouts on everything that waits

**Rule:** Every call that waits on something outside the process
(a network peer, a child process, a lock, a queue, another thread)
carries an explicit timeout,
and the code states what happens when it expires.
A deliberately unbounded wait (a watch mode, an interactive child; section 17)
carries a comment at the call site instead, so it reads as a decision.

**Why:** a missing timeout turns a remote failure into a hang
that nothing in the program can detect;
the process then looks alive and busy while doing nothing.

- `httpx`: `timeout=` on the `Client` or on each call (the default is 5 s).
- `requests`: `timeout=` on every call; `requests` has no default timeout at all.
  A `Session` has no timeout setting, and it ignores a `timeout` attribute set on it.
- `subprocess.run(..., timeout=...)` (section 17);
  when `TimeoutExpired` is raised the child has already been killed.
- `asyncio.timeout(...)` (3.11+) or `asyncio.wait_for(coro, timeout)` around awaits on I/O.
- `future.result(timeout=...)` raises `concurrent.futures.TimeoutError`
  (the builtin `TimeoutError` from 3.11 on)
  and `queue.get(timeout=...)` raises `queue.Empty` when the time runs out.
- `lock.acquire(timeout=...)` reports expiry only through its return value:
  `if not lock.acquire(timeout=...): raise TimeoutError(...)`,
  then the critical section runs in a `try` with `lock.release()` in its `finally`.
- `thread.join(timeout=...)` is followed by a check of `is_alive()`.
- On expiry: retry a bounded number of times with backoff when the operation is idempotent;
  otherwise fail with a message that names the operation and the limit.
