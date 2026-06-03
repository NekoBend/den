# Rust language reference

Rust-specific conventions for the `coding` skill.
Layered on top of `architecture.md` (12 generic rules).
When both apply, this file refines or specializes the generic rule.
Never contradict.

Apply with edition awareness:
section 13 governs which constructs are admissible based on the project's Rust edition and MSRV.
Always read that section before proposing modern syntax.

## 1. Style guide: Rust API Guidelines

**Rule:** Follow the Rust API Guidelines (`rust-lang.github.io/api-guidelines`)
and the Rust Style Guide embedded in `rustfmt` defaults as the baseline.
**Why:** The API Guidelines codify naming, documentation, type design, and interoperability conventions
the Rust ecosystem relies on.
`rustfmt` enforces formatting;
the guidelines cover what formatting cannot.

## 2. Doc comments: rustdoc

**Rule:** Every public function, type, method, constant, and module
gets a `///` doc comment.
Module-level docs use `//!`.
The first line is a single sentence describing what the item does,
starting with a verb in third person (`/// Returns the customer order...`).
Use `# Examples`, `# Errors`, `# Panics` sections where applicable.
**Why:** `cargo doc` and `docs.rs` render these comments as HTML.
The `# Examples` section is compiled and run as a doctest by `cargo test`,
giving free test coverage for every documented example.
**Example:**

```rust
/// Persistence layer for customer orders.
///
/// Stores orders in a `HashMap`; not suitable for production.
pub struct CustomerOrderRepository {
    store: HashMap<i64, CustomerOrder>,
}

impl CustomerOrderRepository {
    /// Returns the customer order with `order_id`.
    ///
    /// # Errors
    /// Returns [`CustomerOrderNotFoundError`] if no row matches.
    pub fn fetch(&self, order_id: i64) -> Result<&CustomerOrder, CustomerOrderNotFoundError> {
        self.store
            .get(&order_id)
            .ok_or(CustomerOrderNotFoundError { order_id })
    }
}
```

## 3. Tooling: rustfmt + clippy + cargo check

**Rule:** Default formatter is `rustfmt` (`cargo fmt`).
Default linter is `clippy` (`cargo clippy`).
Default type/borrow checker is `cargo check`.
All three ship with the Rust toolchain via `rustup`.
**Why:** `rustfmt` is non-negotiable (like Go's `gofmt`).
`clippy` catches hundreds of lint patterns from correctness to style to performance.
`cargo check` runs the full borrow checker without producing a binary,
giving fast feedback.
**Run order:** `cargo fmt` then `cargo clippy` then `cargo check`.

## 4. Naming

**Rule:**

- Functions, methods, variables, modules, crate names: `snake_case`.
- Types (structs, enums, traits), type parameters: `PascalCase`.
- Constants and statics: `SCREAMING_SNAKE_CASE`.
- Lifetime parameters: short lowercase (`'a`, `'ctx`).
  Avoid single-letter names beyond the conventional `'a`, `'b`
  unless the lifetime has a domain meaning.
- Crate names use hyphens in `Cargo.toml` (`my-crate`)
  but underscores in code (`my_crate`).
  Cargo handles the conversion.

**Why:** The Rust API Guidelines and `clippy::style` enforce these patterns.
Deviating triggers compiler warnings in many projects.
**Example:**

```rust
const MAX_RETRIES: u32 = 5;

struct CustomerOrder { /* ... */ }

trait CustomerOrderStore {
    fn fetch(&self, order_id: i64) -> Result<CustomerOrder, Error>;
}
```

## 5. Type system: traits, generics, lifetimes

**Rule:**

- Define traits at the consumer when the trait is small and local.
  Use standard library traits (`Display`, `From`, `Into`, `Default`, `Clone`, `Debug`)
  via `#[derive]` wherever possible.
- Use generics when the function operates over multiple types that share a trait bound.
  Prefer `impl Trait` in argument position for simple cases;
  use named generics (`<T: Bound>`) when the same type parameter appears multiple times.
- Annotate lifetimes only when the compiler requires them.
  Do not add explicit lifetimes when elision rules already cover the case.

**Why:** Traits are Rust's polymorphism primitive;
deriving standard traits makes types interoperable with the ecosystem.
Lifetime elision keeps signatures readable;
annotating when unnecessary is noise.
**See architecture.md section 6** for the generic rule
about preferring explicit types over escape hatches.

## 6. Modern syntax minimums

**Rule:** Use the highest-edition form admissible by the project's `edition` in `Cargo.toml`
(see section 13).
Common edition-gated upgrades:

| Edition | Modern form | Legacy form to avoid |
|---|---|---|
| 2018 | `use crate::foo` (path clarity) | `extern crate` + ambiguous paths |
| 2018 | `async`/`await` syntax | manual `Future` impl |
| 2021 | closure captures are field-level | whole-struct captures |
| 2021 | `IntoIterator` for arrays | manual `.iter()` on fixed arrays |
| 2024 | async closures `async \|\| {}` | manual async blocks in closures |
| 2024 | `unsafe extern` blocks | bare `extern` without safety marker |

**Why:** Each edition removes ceremony or corrects a design mistake.
Edition migration is backward-compatible within a crate graph;
the compiler builds different editions side by side.
**Defer to section 13** before applying.

## 7. Error handling: Result, Option, ?

**Rule:** Return `Result<T, E>` for fallible operations
and `Option<T>` for optional values.
Use the `?` operator to propagate errors;
do not call `.unwrap()` or `.expect()` in library code
(reserve them for tests and provably-safe assertions).
For applications, use `anyhow::Result` at the top level;
for libraries, define typed errors with `thiserror`.

**Why:** `Result` and `Option` encode fallibility in the type system;
the compiler forces callers to handle the failure path.
`.unwrap()` panics on `Err`/`None`, crashing the program;
the `?` operator returns the error to the caller, letting them decide.
**Example:**

```rust
use anyhow::Context;

fn load_config(path: &Path) -> anyhow::Result<Config> {
    let content = fs::read_to_string(path)
        .context("failed to read config file")?;
    let config: Config = toml::from_str(&content)
        .context("failed to parse config TOML")?;
    Ok(config)
}
```

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

## 9. Module structure

**Rule:** Use one file per module (Rust 2018+ path style).
Standard layout:

```
my_crate/
├── src/
│   ├── lib.rs
│   ├── order/
│   │   ├── mod.rs
│   │   ├── model.rs
│   │   ├── repository.rs
│   │   └── error.rs
│   └── adapters/
│       └── http.rs
├── tests/
│   └── integration.rs
├── Cargo.toml
└── Cargo.lock
```

- `lib.rs` declares the crate's public API via `pub mod`.
- Each module directory has a `mod.rs` that re-exports public items.
- `tests/` contains integration tests that import the crate as an external consumer.
- For workspaces with multiple crates, use a `Cargo.toml` `[workspace]` at the root.

**Why:** One-file-per-module keeps each file focused.
`mod.rs` re-exports control the public surface;
items not re-exported are crate-private.
**When over:** A module file exceeding ~500 lines
is a candidate for splitting into a directory with `mod.rs` + sub-files.

## 10. Domain errors

**Rule:** Define typed domain errors with `thiserror::Error`.
Each variant wraps or maps an underlying cause.
Implement `From<T>` (via `#[from]`)
to enable `?` propagation from the source error.

**Why:** `thiserror` generates `Display`, `Error`, and `From` impls from a derive macro;
callers match on variants and traverse the source chain via `.source()`.
This is the library-side counterpart to `anyhow` (application-side);
the two compose cleanly.
**Cross-ref:** architecture.md section 5 (catch narrow, propagate broad).
Section 7 covers the propagation mechanic;
this section covers the type design.
**Example:**

```rust
use thiserror::Error;

#[derive(Debug, Error)]
pub enum OrderError {
    #[error("customer order {order_id} not found")]
    NotFound { order_id: i64 },

    #[error("insufficient stock for SKU {sku}")]
    InsufficientStock { sku: String },

    #[error(transparent)]
    Database(#[from] sqlx::Error),
}
```

## 11. Idiomatic patterns

**Rule:** Prefer Rust's native idioms over manual equivalents:

- **Pattern matching** (`match`, `if let`, `let else`)
  for exhaustive handling of enums and `Option`/`Result`.
- **Iterator chains** (`.map()`, `.filter()`, `.collect()`)
  over manual `for` loops when the operation is transformational.
- **`From`/`Into` impls** for type conversions instead of ad-hoc conversion functions.
- **`Option` combinators** (`.map()`, `.and_then()`, `.unwrap_or()`, `.unwrap_or_default()`)
  instead of `match` on trivial cases.
- **`let else`** (Rust 1.65+) for early-return on pattern mismatch:
  `let Some(x) = val else { return Err(...); };`
- **Newtype pattern** (`struct UserId(i64)`)
  for domain-typed wrappers that prevent accidental misuse of raw primitives.

**Why:** See architecture.md section 12 (Idiomatic over portable).
Rust's iterator chains are zero-cost abstractions;
they compile to the same machine code as manual loops.
**Example:**

```rust
let shipped_ids: Vec<i64> = orders
    .iter()
    .filter(|o| o.status == OrderStatus::Shipped)
    .map(|o| o.id)
    .collect();
```

## 12. Validation at boundaries

**Rule:** Concentrate validation at deserialization boundaries.
Use `serde` for deserialization
and the `validator` crate (`github.com/Keats/validator`) for semantic constraints.
Internal functions trust their typed parameters.

**Why:** See architecture.md section 9 (Validate at boundaries, trust internals).
Rust's type system covers shape at compile time;
`serde` converts raw input into typed structs.
The `validator` crate adds runtime semantic checks (positive numbers, non-empty strings, email format)
via derive macros.
Validating once at the boundary avoids duplicated checks in internal layers.
**Example:**

```rust
use serde::Deserialize;
use validator::Validate;

#[derive(Debug, Deserialize, Validate)]
pub struct CreateCustomerOrderRequest {
    #[validate(range(min = 1))]
    pub customer_id: i64,

    #[validate(length(min = 1))]
    pub sku_ids: Vec<String>,
}
```

## 13. Edition and MSRV awareness

**Rule:** Before proposing any edition-gated form (sections 5, 6, 8),
read the project's `Cargo.toml`:

- `edition`: the Rust edition (`"2018"`, `"2021"`, `"2024"`).
- `rust-version` (MSRV): the minimum supported Rust compiler version.

If `edition = "2021"`,
do not propose 2024 features (async closures, `unsafe extern` blocks).
If `rust-version = "1.65"`,
do not propose `let else` (1.65 is the minimum; check exact feature stabilization).
**Why:** Rust editions are opt-in per crate;
mixed-edition crate graphs compile together.
But proposing a feature above the declared MSRV breaks CI for users on the minimum version.
**When declarations are absent:** `edition` defaults to `"2015"` and no MSRV is assumed.
Ask the user before proposing modern features.

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
