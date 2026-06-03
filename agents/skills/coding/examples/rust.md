# Rust worked examples

Worked examples demonstrating the rules in `shared/reference/rust.md`.
The shared domain is a small order-management system;
each block is a fragment of that system illustrating two or three rules.
Cross-references in the prose point to the corresponding `shared/reference/rust.md` section.

Code in these blocks contains only natural comments
(the kind a real developer writes for non-obvious WHY).
Instructional / meta comments belong in this prose, never in the code.

## 1. Domain types and errors

This block demonstrates shared/reference/rust.md section 2 (rustdoc),
section 5 (traits via derive), and section 10 (domain errors with thiserror).

```rust
use thiserror::Error;

/// An order placed by a customer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CustomerOrder {
    pub id: i64,
    pub customer_id: i64,
    pub total_cents: i64,
    pub sku_ids: Vec<String>,
}

/// Errors that can occur in the order domain.
#[derive(Debug, Error)]
pub enum OrderError {
    #[error("customer order {order_id} not found")]
    NotFound { order_id: i64 },

    #[error("insufficient stock for SKU {sku}")]
    InsufficientStock { sku: String },
}
```

`CustomerOrder` derives `Debug`, `Clone`, `PartialEq`, and `Eq`
rather than implementing them by hand (reference section 5).
The `OrderError` enum uses `thiserror::Error`
to generate the `Display` and `std::error::Error` impls from the `#[error(...)]` attributes
(reference section 10).
Each variant carries the structured data a caller needs to react (`order_id`, `sku`).

The `///` doc comments render in `cargo doc` and `docs.rs` (reference section 2).

## 2. Persistence with validation

This block demonstrates shared/reference/rust.md section 7 (Result and `?`),
section 12 (validation with serde + validator), and section 11 (`Option` combinators).

```rust
use std::collections::HashMap;

use serde::Deserialize;
use validator::Validate;

use crate::order::{CustomerOrder, OrderError};

/// Validated payload for creating a customer order.
#[derive(Debug, Deserialize, Validate)]
pub struct CreateCustomerOrderRequest {
    #[validate(range(min = 1))]
    pub customer_id: i64,

    #[validate(length(min = 1))]
    pub sku_ids: Vec<String>,
}

/// In-memory persistence for customer orders.
#[derive(Default)]
pub struct CustomerOrderRepository {
    store: HashMap<i64, CustomerOrder>,
    next_id: i64,
}

impl CustomerOrderRepository {
    /// Validates the request and stores a new order.
    ///
    /// # Errors
    /// Returns [`validator::ValidationErrors`] if the request is invalid.
    pub fn create(
        &mut self,
        request: CreateCustomerOrderRequest,
    ) -> Result<&CustomerOrder, validator::ValidationErrors> {
        request.validate()?;
        self.next_id += 1;
        let order = CustomerOrder {
            id: self.next_id,
            customer_id: request.customer_id,
            total_cents: 0,
            sku_ids: request.sku_ids,
        };
        Ok(self.store.entry(self.next_id).or_insert(order))
    }

    /// Returns the order with `order_id`.
    ///
    /// # Errors
    /// Returns [`OrderError::NotFound`] if no entry matches.
    pub fn fetch(&self, order_id: i64) -> Result<&CustomerOrder, OrderError> {
        self.store
            .get(&order_id)
            .ok_or(OrderError::NotFound { order_id })
    }
}
```

`create` validates at the boundary with `request.validate()?`;
the `?` operator propagates the `ValidationErrors` to the caller (reference section 7 and 12).
Internal code after the check trusts the typed fields.

`fetch` converts the `Option` returned by `HashMap::get` into a `Result` with `.ok_or(...)`
(reference section 11),
turning a missing key into the domain error.
`#[derive(Default)]` provides the empty constructor for free (reference section 5).

## 3. Async fetching

This block demonstrates shared/reference/rust.md section 8 (tokio async, no blocking I/O)
and section 11 (iterator chains).

```rust
use futures::future::join_all;
use reqwest::Client;

use crate::order::{CustomerOrder, OrderError};

/// Fetches multiple customer orders concurrently.
///
/// # Errors
/// Returns an error if any request fails or returns a non-success
/// status.
pub async fn fetch_orders(
    client: &Client,
    base_url: &str,
    order_ids: &[i64],
) -> Result<Vec<CustomerOrder>, anyhow::Error> {
    let futures = order_ids
        .iter()
        .map(|&id| fetch_one(client, base_url, id));
    join_all(futures).await.into_iter().collect()
}

async fn fetch_one(
    client: &Client,
    base_url: &str,
    id: i64,
) -> Result<CustomerOrder, anyhow::Error> {
    let url = format!("{base_url}/orders/{id}");
    let response = client.get(&url).send().await?;
    if response.status() == reqwest::StatusCode::NOT_FOUND {
        return Err(OrderError::NotFound { order_id: id }.into());
    }
    let order = response.error_for_status()?.json::<CustomerOrder>().await?;
    Ok(order)
}
```

`fetch_orders` builds an iterator of futures with `.map()`
and runs them concurrently with `join_all` (reference section 8 and 11).
`.into_iter().collect()` over a `Vec<Result<T, E>>` collapses into a single `Result<Vec<T>, E>`,
short-circuiting on the first error: an idiomatic Rust pattern.

`fetch_one` uses `?` on every `.await` to propagate errors.
The `anyhow::Error` return type aggregates the `reqwest` errors and the domain `OrderError`
(converted via `.into()`),
matching the application-side error strategy from reference section 7.
The `reqwest::Client` is borrowed, not owned,
so the connection pool is shared across calls (shared/reference/architecture.md section 2).

## 4. CLI entry with config loading

This block demonstrates shared/reference/rust.md section 7 (anyhow with context)
and section 11 (newtype-free struct deserialization).

```rust
use std::path::PathBuf;

use anyhow::Context;
use clap::Parser;
use serde::Deserialize;

/// Service configuration loaded from a TOML file.
#[derive(Debug, Deserialize)]
struct ServiceConfig {
    endpoint: String,
    timeout_seconds: u32,
    log_level: String,
}

/// Command-line arguments for the order service.
#[derive(Parser)]
struct Args {
    /// Path to the configuration TOML.
    #[arg(long, default_value = "config.toml")]
    config: PathBuf,
}

fn load_config(path: &PathBuf) -> anyhow::Result<ServiceConfig> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("read config {}", path.display()))?;
    let config: ServiceConfig =
        toml::from_str(&content).context("parse config TOML")?;
    Ok(config)
}

fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    let config = load_config(&args.config)?;
    println!("connected to {}", config.endpoint);
    Ok(())
}
```

`load_config` attaches human-readable context to each fallible step
with `.with_context(...)` and `.context(...)` (reference section 7).
If reading or parsing fails, the error message names which step and which file,
instead of a bare `No such file or directory`.

`main` returns `anyhow::Result<()>`,
so the `?` operator works at the top level and Rust prints the full error chain on exit.
`clap`'s derive macro generates the argument parser from the `Args` struct,
the Rust equivalent of Python's `argparse` and Go's `flag`.

## 5. Project layout

This block demonstrates shared/reference/rust.md section 9 (module structure)
and section 4 (naming).

```
orders/
├── src/
│   ├── main.rs
│   ├── order/
│   │   ├── mod.rs
│   │   ├── model.rs
│   │   ├── repository.rs
│   │   └── error.rs
│   └── adapters/
│       ├── mod.rs
│       └── http.rs
├── tests/
│   └── integration.rs
├── Cargo.toml
└── Cargo.lock
```

Organized by domain (reference section 9):

- `order/model.rs` holds Example 1's `CustomerOrder`;
  `order/error.rs` holds `OrderError`;
  `order/mod.rs` re-exports both as the module's public surface.
- `order/repository.rs` holds Example 2's `CustomerOrderRepository` and `CreateCustomerOrderRequest`.
- `adapters/http.rs` holds Example 3's `fetch_orders`,
  isolating network I/O from the pure domain.
- `main.rs` holds Example 4's CLI entry point.
- `tests/integration.rs` imports the crate as an external consumer.

All module and file names are `snake_case`;
all types are `PascalCase` (reference section 4).

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
