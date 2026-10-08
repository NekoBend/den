# Rust worked examples: pitfalls

The Pitfalls list of the Rust worked examples: common mistakes and the reference sections that prevent them.

## Pitfalls

Common mistakes that the rules in `shared/reference/rust.md` are designed to prevent.
Each is a real bug class that ships when the rule is forgotten.

- **`.unwrap()` / `.expect()` in library code.**
  These panic on `Err`/`None`, crashing the program.
  Propagate with `?` and let the caller decide;
  reserve `.unwrap()` for tests and provably-safe invariants (reference section 7).
- **`.clone()` to silence the borrow checker.**
  Cloning to escape a borrow error often hides a design problem and adds an allocation.
  First try restructuring the borrows or taking a reference (reference section 5).
- **Blocking I/O inside `async fn`.**
  `std::fs::read` or `std::thread::sleep` inside an async function
  blocks the tokio worker thread and stalls every task on it.
  Use `tokio::fs` and `tokio::time::sleep` (reference section 8).
- **Holding a non-`Send` type across `.await`.**
  An `Rc` or `RefCell` held across an await point makes the future non-`Send`,
  causing a compile error when spawned on a multi-threaded runtime.
  Use `Arc` and `Mutex` for shared state in async code (reference section 8).
- **`unsafe` without a `// SAFETY:` comment.**
  Every `unsafe` block is a contract;
  the comment documents the invariant the author verified.
  An undocumented block is unreviewable (reference section 14).
- **Over-broad error enums.**
  A `thiserror` enum with 20 variants that callers always handle identically is over-engineered.
  Add variants only when callers need to distinguish them (reference section 10).
- **Ignoring `#[must_use]` results.**
  Dropping a `Result` without handling it discards a potential error silently.
  The compiler warns;
  do not silence the warning with `let _ =` unless the error is genuinely irrelevant (reference section 7).
