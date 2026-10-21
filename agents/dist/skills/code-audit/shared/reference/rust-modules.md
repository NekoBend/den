# Rust reference: module structure

Section 9 of the Rust reference: module structure.
shared/reference/rust.md lists where every section lives.

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
