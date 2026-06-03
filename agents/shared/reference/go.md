# Go language reference

Go-specific conventions for the `coding` skill.
Layered on top of `architecture.md` (12 generic rules).
When both apply, this file refines or specializes the generic rule.
Never contradict.

Apply with version awareness:
section 13 governs which constructs are admissible based on the project's Go version.
Always read that section before proposing modern syntax.

## 1. Style guide: Effective Go + Code Review Comments

**Rule:** Follow Effective Go (`go.dev/doc/effective_go`)
and the Go Code Review Comments wiki (`go.dev/wiki/CodeReviewComments`) as the baseline.
Google also publishes a Go Style Guide at `google.github.io/styleguide/go`
that adds project-level conventions.
**Why:** Go has the strongest community consensus on style of any modern language.
`gofmt` enforces formatting;
the style guides cover what `gofmt` cannot:
naming, package layout, error handling idiom, and commentary conventions.

## 2. Doc comments: godoc format

**Rule:** Every exported function, type, method, constant, and variable
gets a doc comment.
The first sentence is a complete sentence starting with the identifier name
(`// Fetch returns the customer order with the given ID.`).
Use `//` line comments,
not `/* */` block comments.
**Why:** `go doc` and `pkg.go.dev` extract the first sentence as the synopsis.
The identifier-first convention (`go.dev/doc/comment`)
lets tools display names consistently in package indexes.
**Example:**

```go
// CustomerOrderRepository provides persistence for customer orders.
type CustomerOrderRepository struct {
 store map[int]*CustomerOrder
}

// Fetch returns the customer order with orderId.
// It returns CustomerOrderNotFoundError if no row matches.
func (r *CustomerOrderRepository) Fetch(orderId int) (*CustomerOrder, error) {
 // ...
}
```

## 3. Tooling: gofmt + golangci-lint v2 + go vet

**Rule:** Default formatter is `gofmt` (ships with the Go toolchain; non-negotiable).
Default linter aggregator is `golangci-lint v2` (`golangci-lint.run`),
configurable per project via `.golangci.yml`.
Default static analyzer is `go vet`.
**Why:** `gofmt` eliminates all formatting debates.
golangci-lint v2 aggregates 100+ linters (staticcheck, errcheck, gosec, govet, ...)
behind a single binary and config file.
The v2 `golangci-lint fmt` command unifies formatting with the linter workflow.
**Run order:** `gofmt -w .` then `golangci-lint run`.

## 4. Naming

**Rule:**

- Exported names: `MixedCaps` (PascalCase).
  Unexported names: `mixedCaps` (camelCase).
  Go has no `UPPER_SNAKE` convention for constants;
  use `maxRetries` (unexported) or `MaxRetries` (exported).
- Package names: short, lowercase, single word (`order`, `http`, `user`).
  No underscores, no camelCase.
- Receiver names: one or two letters, consistent within the type
  (`r` for `*Repository`, `o` for `*Order`).
  Not `self` or `this`.
- Interface names: single-method interfaces use the `-er` suffix
  (`Reader`, `Writer`, `Closer`).
  Multi-method interfaces use descriptive nouns (`CustomerOrderStore`).
- Acronyms in names are all-caps (`HTTPClient`, `userID`, `xmlParser`).

**Why:** Go Code Review Comments codifies these patterns.
Short receiver names are idiomatic because method bodies are short
(per architecture.md section 8).
The `-er` suffix communicates "this interface abstracts a single capability."
**Example:**

```go
const maxRetries = 5

type CustomerOrder struct { /* ... */ }

type CustomerOrderStore interface {
 Fetch(orderId int) (*CustomerOrder, error)
}
```

## 5. Type system: interfaces, embedding, generics

**Rule:**

- Define interfaces at the consumer, not at the implementer.
  A package that needs a "thing that fetches orders" declares its own small interface locally;
  the implementation satisfies it implicitly.
- Embed structs and interfaces to compose behavior.
  Embedding is Go's composition primitive; it replaces inheritance.
- Use generics (Go 1.18+) when the logic is type-parametric
  and the alternative is duplicated code or `any` casts.
  Do not add type parameters to make code "more flexible" when a concrete type works.

**Why:** Consumer-side interfaces keep packages decoupled:
the implementer does not import the consumer,
and the consumer does not depend on unrelated methods.
Generics replace the pre-1.18 pattern of `any` casts that pushed type errors to runtime.
**See architecture.md section 6** for the generic rule
about preferring explicit types over escape hatches.
**Example:**

```go
// Declared by the consumer, not the implementation.
type OrderFetcher interface {
 Fetch(orderId int) (*CustomerOrder, error)
}

// Generic helper avoids duplicating Map for every slice type.
func Map[T, U any](s []T, f func(T) U) []U {
 result := make([]U, len(s))
 for i, v := range s {
  result[i] = f(v)
 }
 return result
}
```

## 6. Modern syntax minimums

**Rule:** Use the highest-version form admissible by the project's `go` directive in `go.mod`
(see section 13).
Common version-gated upgrades:

| Version | Modern form | Legacy form to avoid |
|---|---|---|
| 1.18+ | generics (`func Map[T any](...)`) | `interface{}` / `any` casts |
| 1.21+ | `log/slog` structured logging | `log.Printf` unstructured |
| 1.21+ | `slices`, `maps` stdlib packages | hand-rolled sort and search |
| 1.22+ | range-over-integer (`for i := range 10`) | `for i := 0; i < 10; i++` |
| 1.23+ | range-over-func iterators (`iter.Seq`) | callback or channel iteration |

**Why:** Each new form removes boilerplate or replaces unsafe casts.
`slog` in particular replaces unstructured `log.Printf`
with key-value pairs that work with structured log backends (JSON, OTLP).
**Defer to section 13** before applying.

## 7. Error handling discipline

**Rule:** Check every returned `error` immediately.
Do not discard errors with `_`.
Wrap errors at each call-site boundary with `fmt.Errorf("context: %w", err)`
to build a chain that callers can inspect with `errors.Is` and `errors.As`.
Return early on error;
keep the success path unindented.

**Why:** Go's explicit error returns replace exceptions.
Ignoring a returned error is the Go equivalent of an empty `catch` block.
The `%w` verb (Go 1.13+) preserves the original error for programmatic inspection
while adding human-readable context.
**Example:**

```go
func (r *CustomerOrderRepository) Fetch(orderId int) (*CustomerOrder, error) {
 row, err := r.db.QueryRow(ctx, "SELECT ... WHERE id = $1", orderId)
 if err != nil {
  return nil, fmt.Errorf("fetch customer order %d: %w", orderId, err)
 }
 order, err := scanCustomerOrder(row)
 if err != nil {
  return nil, fmt.Errorf("scan customer order %d: %w", orderId, err)
 }
 return order, nil
}
```

## 8. Concurrency: goroutines, channels, context

**Rule:**

- Start a goroutine only when you have a clear owner that waits for it to finish
  (`sync.WaitGroup`, `errgroup.Group`, or a channel read).
  Orphan goroutines leak memory and connections.
- Pass `context.Context` as the first parameter of every function that may block or perform I/O.
  Respect cancellation by selecting on `ctx.Done()` or passing the context to downstream calls.
- Prefer `errgroup.Group` (`golang.org/x/sync/errgroup`)
  for concurrent I/O with error collection and cancellation propagation.
- Use channels for communication between goroutines, mutexes for shared state.
  Do not mix; pick one model per coordination point.

**Why:** Goroutines are cheap to start but not free to leak.
A leaked goroutine holds its stack, any connections it opened,
and any objects its closure captures.
`context.Context` is the standard cancellation and deadline mechanism across the Go ecosystem.
**Example:**

```go
func fetchAll(ctx context.Context, client *http.Client, urls []string) ([][]byte, error) {
 g, ctx := errgroup.WithContext(ctx)
 results := make([][]byte, len(urls))
 for i, url := range urls {
  g.Go(func() error {
   body, err := doGet(ctx, client, url)
   if err != nil {
    return err
   }
   results[i] = body
   return nil
  })
 }
 if err := g.Wait(); err != nil {
  return nil, err
 }
 return results, nil
}
```

On Go versions before 1.22,
loop variables `i` and `url` captured by the goroutine closure would race.
If the project's `go` directive is below 1.22,
rebind with `i, url := i, url` at the top of the loop body
(see section 13 for version checking).
Go 1.22+ creates a new variable per iteration and this rebinding is unnecessary.

## 9. Package structure

**Rule:** Organize by domain, not by layer.
Standard layout:

```
project/
├── cmd/
│   └── orders/
│       └── main.go
├── internal/
│   ├── order/
│   │   ├── model.go
│   │   ├── repository.go
│   │   └── service.go
│   └── platform/
│       └── postgres/
│           └── client.go
├── go.mod
└── go.sum
```

- `cmd/<name>/main.go`: thin entry point.
  Parse flags, build dependencies, call a `run` function that returns `error`.
- `internal/`: packages that external modules cannot import (enforced by the Go toolchain).
  Subdivide by domain (`order/`, `user/`) or infrastructure (`platform/postgres/`).
- Each package owns one concern.
  A package exceeding ~500 lines or mixing I/O with pure logic is a candidate for splitting.

**Why:** `internal/` is compiler-enforced access control.
Domain-first package naming (`order`, not `models`)
avoids the "package util" anti-pattern where unrelated functions accumulate.
**When over:** If a package has grown a sub-package that most callers never use,
split it out.

## 10. Domain errors

**Rule:** Define sentinel errors with `var ErrXxx = errors.New(...)`
or custom error types implementing the `error` interface.
Callers check with `errors.Is(err, ErrXxx)` (sentinel)
or `errors.As(err, &target)` (typed).
Wrap at each call site with `%w`.

**Why:** Sentinel errors (`ErrNotFound`, `ErrConflict`) let callers react without string parsing.
Custom types carry structured fields (e.g., `CustomerOrderNotFoundError.OrderID`).
`errors.Is` and `errors.As` traverse the wrapped chain,
so intermediate layers can add context without breaking the caller's match.
**Cross-ref:** architecture.md section 5 (catch narrow, propagate broad).
Section 7 covers the wrapping mechanic;
this section covers the type design.
**Example:**

```go
type CustomerOrderNotFoundError struct {
 OrderID int
}

func (e *CustomerOrderNotFoundError) Error() string {
 return fmt.Sprintf("customer order %d not found", e.OrderID)
}

// Caller site:
var target *CustomerOrderNotFoundError
if errors.As(err, &target) {
 http.Error(w, target.Error(), http.StatusNotFound)
}
```

## 11. Idiomatic patterns

**Rule:** Prefer Go's native idioms over manual equivalents:

- **`defer`** for cleanup (close files, unlock mutexes, flush buffers).
  Stack order is LIFO.
- **Zero values are useful defaults.**
  `var m sync.Mutex` is ready to use; `var buf bytes.Buffer` is an empty buffer.
  Do not write constructors that only set zero values.
- **Comma-ok idiom** (`val, ok := m[key]`)
  for maps and type assertions instead of checking after the fact.
- **Multiple return values** for result + error.
  Do not use output parameters (pointer arguments for "returning" values)
  except in performance-critical paths.
- **Table-driven tests** with `t.Run` subtests for coverage of multiple inputs.
- **Accept interfaces, return structs** at public API boundaries.

**Why:** See architecture.md section 12 (Idiomatic over portable).
Go's idioms are designed around the language's simplicity constraint;
porting patterns from other languages (Java-style builders, Python-style decorators)
adds friction without benefit.
**Example:**

```go
val, ok := cache[key]
if !ok {
 val = computeExpensiveDefault(key)
 cache[key] = val
}
```

## 12. Validation at boundaries

**Rule:** Concentrate input validation at the handler or API entry point.
Use struct tags with `go-playground/validator`
(`github.com/go-playground/validator/v10`) for declarative field constraints.
Internal functions trust their typed parameters.

**Why:** See architecture.md section 9 (Validate at boundaries, trust internals).
Go's type system covers shape at compile time;
`validator` adds semantic constraints (positive integers, non-empty strings, email format)
that types cannot express.
Validating once at the boundary avoids duplicated checks in internal layers.
**Example:**

```go
type CreateCustomerOrderRequest struct {
 CustomerID int      `json:"customer_id" validate:"required,gt=0"`
 SkuIDs     []string `json:"sku_ids"     validate:"required,min=1,dive,required"`
}

func (h *Handler) CreateOrder(w http.ResponseWriter, r *http.Request) {
 var req CreateCustomerOrderRequest
 if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
  http.Error(w, "invalid JSON", http.StatusBadRequest)
  return
 }
 if err := h.validate.Struct(req); err != nil {
  http.Error(w, err.Error(), http.StatusUnprocessableEntity)
  return
 }
 // req is validated; pass to internal service.
}
```

## 13. Version awareness

**Rule:** Before proposing any version-gated form (sections 5, 6, 7, 8),
read the project's declared Go version:

- `go.mod` `go` directive: the minimum Go version the module requires.
- `go.mod` `toolchain` directive (Go 1.21+): pinned toolchain version.

If the `go` directive says `1.20`,
do not propose `slices`, `maps`, `slog`, range-over-integer, or range-over-func.
If it says `1.17`, do not propose generics at all.
**Why:** The `go` directive controls which language features the compiler accepts.
Unlike TypeScript's `target` (which transpiles),
Go binaries require the declared version's runtime.
Proposing features above the declared floor breaks the build for anyone running that version.
**When the directive is absent:** the module defaults to Go 1.16 semantics.
Ask the user to set it explicitly before proposing modern features.

## 14. init() and package-level state

**Rule:** Avoid `func init()`.
If you must use it, limit it to registering a driver or codec;
never perform I/O, acquire resources,
or depend on ordering between `init` functions in different packages.
Avoid mutable package-level variables;
use function parameters or struct fields for configuration.

**Why:** `init()` runs implicitly at import time.
It cannot return errors, cannot be skipped in tests,
and its execution order across packages is determined by the import graph,
which is brittle.
Mutable package-level state creates hidden coupling
that defeats dependency injection and makes tests non-deterministic.
**Prefer explicit construction:**

```go
// Explicit dependency injection; no init(), no package state.
func NewApp(db *sql.DB) *App {
 return &App{db: db}
}
```
