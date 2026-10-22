# Rust worked examples: async and CLI

Examples 3 and 4 of the Rust worked examples:
fetching customer orders concurrently over HTTP, and a command-line entry point that loads a TOML config.

## 3. Async fetching

This block demonstrates shared/reference/rust-async-unsafe.md section 8 (tokio async, no blocking I/O)
and rust-api-design.md section 11 (iterator chains).

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
and runs them concurrently with `join_all` (rust-async-unsafe.md section 8 and rust-api-design.md section 11).
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
and rust-api-design.md section 11 (newtype-free struct deserialization).

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
