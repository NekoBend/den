# Rust worked examples

Worked examples demonstrating the rules in `shared/reference/rust.md`.
The shared domain is a small order-management system;
each block is a fragment of that system illustrating two or three rules.
Cross-references in the prose point to the corresponding `shared/reference/rust.md` section.

Code in these blocks contains only natural comments
(the kind a real developer writes for non-obvious WHY).
Instructional / meta comments belong in this prose, never in the code.

## Where each example lives

- examples/rust-async-cli.md (Examples 3 and 4): read it when the code is async or calls an HTTP service,
  or when you write a command-line entry point or load a config file.
- examples/rust-pitfalls.md (the Pitfalls list): read it after this file.

Compare your code against every file you read.

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
