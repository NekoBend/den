# Rust language reference

Rust-specific conventions for the `coding` skill.
Layered on top of `architecture.md` and `architecture-readability.md` (12 generic rules).
When a generic rule also applies, the Rust reference refines or specializes it.
Never contradict.

Apply with edition awareness:
section 13 governs which constructs are admissible based on the project's Rust edition and MSRV.
Always read that section before proposing modern syntax.

## Where each section lives

This file holds sections 1, 3, 4, 6, 7, and 13.

- shared/reference/rust-api-design.md (sections 2, 5, 10, 11, and 12): read it now as well.
- shared/reference/rust-async-unsafe.md (sections 8 and 14): read it when the code is async
  or contains `unsafe` code or an `extern` block.
- shared/reference/rust-modules.md (section 9): read it when the code creates a crate, a workspace,
  a module, or a file under `tests/`,
  or when a source file is longer than about 500 lines,
  or when the code adds a `pub` item to a module.

"section N" in any of these files means the section with that number;
this list names the file that holds it.

## 1. Style guide: Rust API Guidelines

**Rule:** Follow the Rust API Guidelines (`rust-lang.github.io/api-guidelines`)
and the Rust Style Guide embedded in `rustfmt` defaults as the baseline.
**Why:** The API Guidelines codify naming, documentation, type design, and interoperability conventions
the Rust ecosystem relies on.
`rustfmt` enforces formatting;
the guidelines cover what formatting cannot.

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

## 13. Edition and MSRV awareness

**Rule:** Before proposing any edition-gated form
(section 6, rust-api-design.md section 5, rust-async-unsafe.md section 8),
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
