# Performance review

Review lens: is the code efficient enough at the scale it will actually run?
This pass is ONLY about performance.
Judge real, reachable cost at the expected input size.
Do not flag micro-optimizations that do not matter,
and leave correctness, safety, and style to their own passes.

## What to look for

- Algorithmic complexity: a nested loop over a large input
  that turns a linear job into quadratic or worse,
  or a data structure that forces a scan
  where a set or map would give direct lookup.
- Repeated work: a value recomputed every iteration
  that could be computed once outside the loop,
  or a result that could be cached.
- N plus one: a query, a network call, or a disk read inside a loop
  that should be a single batched call.
- Allocation: unnecessary copies of large data,
  big intermediate structures, allocation inside a hot loop.
- Input and output: blocking I/O on a hot path,
  unbuffered reads or writes,
  loading a whole large file or response into memory
  when it could be streamed or paginated.
- Concurrency: a place where parallelism would clearly help and is missed,
  or, the reverse, lock contention from a lock held too long or too broadly.

## Common defects in this dimension

- A linear scan inside a loop, making the whole operation quadratic.
- One database or network call per item instead of one batched call.
- Building a list only to test membership, where a set would be direct.
- Reading an entire file or response into memory
  when streaming would use constant memory.
- Recomputing the same value on every iteration of a loop.

## How to verify

- These scripts do NOT profile or benchmark.
  Do not claim a speed measurement you did not take.
- Estimate the cost at the expected input size from the Step 1 intent.
  Separate "matters at the expected scale" from "theoretical only":
  the first is a real finding, the second is at most a nit.
- When a performance finding is load-bearing,
  recommend the user profile or benchmark to confirm,
  and say the review estimated rather than measured.

## Language specifics

For performance idioms in the target language
(lazy iteration, value versus reference passing,
the right standard collection),
consult the shared reference for the target language
(SKILL.md Step 4 gives the path).
