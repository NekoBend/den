# Rust reference: async and unsafe

Sections 8 and 14 of the Rust reference:
async with tokio, and `unsafe` discipline.
shared/reference/rust.md lists where every section lives.

## 8. Async: tokio, Send/Sync, cancellation

**Rule:**

- Use `tokio` as the default async runtime
  unless the project has chosen another (`async-std`, `smol`).
  Do not mix runtimes.
- Every `async fn` that may be spawned on a multi-threaded executor must return a `Send` future.
  Avoid holding non-`Send` types (e.g., `Rc`, `RefCell`) across `.await` points.
- Use `tokio::select!` for cancellation-aware waiting on multiple futures.
  Respect `CancellationToken` or `tokio::signal` for graceful shutdown.
- Do not call blocking I/O (`std::fs`, `std::thread::sleep`) inside `async fn`;
  use `tokio::fs`, `tokio::time::sleep`, or `tokio::task::spawn_blocking`
  for unavoidable blocking work.

**Why:** Blocking a tokio worker thread stalls every task on that thread.
Non-`Send` futures cannot be moved between threads,
causing compile errors when spawned on a multi-threaded runtime.
**Example:**

```rust
async fn fetch_all(client: &reqwest::Client, urls: &[String]) -> Vec<reqwest::Result<String>> {
    let futures: Vec<_> = urls.iter().map(|url| client.get(url).send()).collect();
    let responses = futures::future::join_all(futures).await;
    let mut results = Vec::with_capacity(responses.len());
    for res in responses {
        match res {
            Ok(r) => results.push(r.text().await),
            Err(e) => results.push(Err(e)),
        }
    }
    results
}
```

## 14. unsafe discipline

**Rule:** Minimize `unsafe` blocks.
When `unsafe` is required:

- Scope the block as tightly as possible;
  do not wrap an entire function body in `unsafe`.
- Document the safety invariant in a `// SAFETY:` comment immediately above the block.
- Wrap `unsafe` code behind a safe public API
  so callers never need to write `unsafe` themselves.
- Run `cargo miri test` to detect undefined behavior in tests.
- `unsafe extern` blocks are mandatory in edition 2024;
  bare `extern` without `unsafe` is a compile error.

**Why:** `unsafe` disables borrow-checker guarantees within its scope.
Every `unsafe` block is a contract between the author and the compiler:
"I have verified these invariants hold."
A missing invariant is a soundness hole.
The `// SAFETY:` comment convention is enforced by `clippy::undocumented_unsafe_blocks`.
**Example:**

```rust
// SAFETY: `ptr` is non-null and aligned; the caller guarantees
// the buffer has at least `len` initialized bytes.
unsafe {
    std::slice::from_raw_parts(ptr, len)
}
```
