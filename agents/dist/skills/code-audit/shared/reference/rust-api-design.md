# Rust reference: API design

Sections 2, 5, 10, 11, and 12 of the Rust reference:
doc comments, the type system, domain errors, idiomatic patterns, and validation at boundaries.
shared/reference/rust.md lists where every section lives.

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
rust.md section 7 covers the propagation mechanic;
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
