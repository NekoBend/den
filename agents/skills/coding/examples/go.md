# Go worked examples

Worked examples demonstrating the rules in `shared/reference/go.md`.
The shared domain is a small order-management system;
each block is a fragment of that system illustrating two or three rules.
Cross-references in the prose point to the corresponding `shared/reference/go.md` section.

Code in these blocks contains only natural comments
(the kind a real developer writes for non-obvious WHY).
Instructional / meta comments belong in this prose, never in the code.

## 1. Domain types and errors

This block demonstrates shared/reference/go.md section 2 (godoc),
section 4 (naming), and section 10 (domain errors).

```go
// Package order defines customer order types and persistence.
package order

import (
	"errors"
	"fmt"
)

// ErrInsufficientStock is returned when a requested quantity exceeds
// available stock.
var ErrInsufficientStock = errors.New("insufficient stock")

// CustomerOrder is an order placed by a customer.
type CustomerOrder struct {
	ID         int64
	CustomerID int64
	TotalCents int64
	SkuIDs     []string
}

// CustomerOrderNotFoundError indicates that a customer order ID did
// not resolve to a stored order.
type CustomerOrderNotFoundError struct {
	OrderID int64
}

// Error implements the error interface.
func (e *CustomerOrderNotFoundError) Error() string {
	return fmt.Sprintf("customer order %d not found", e.OrderID)
}
```

The package comment starts with "Package order" per godoc convention (reference section 2);
each exported type and method has a comment beginning with its identifier name.

`ErrInsufficientStock` is a sentinel error for the simple case
where callers only need to know "this happened" (matched with `errors.Is`).
`CustomerOrderNotFoundError` is a custom type carrying the `OrderID` field
for cases where callers need structured data (matched with `errors.As`).
Both patterns are covered in reference section 10.

Acronyms are all-caps (`ID`, `CustomerID`, `SkuIDs`) per reference section 4.

## 2. Persistence with validation and error handling

This block demonstrates shared/reference/go.md section 7 (error handling discipline),
section 12 (validation with struct tags), and section 11 (comma-ok idiom).

```go
package order

import (
	"fmt"

	"github.com/go-playground/validator/v10"
)

// CreateCustomerOrderRequest is the validated payload for creating an
// order. Struct tags drive go-playground/validator.
type CreateCustomerOrderRequest struct {
	CustomerID int64    `json:"customer_id" validate:"required,gt=0"`
	SkuIDs     []string `json:"sku_ids"     validate:"required,min=1,dive,required"`
}

// CustomerOrderRepository provides in-memory persistence for orders.
type CustomerOrderRepository struct {
	validate *validator.Validate
	store    map[int64]*CustomerOrder
	nextID   int64
}

// NewCustomerOrderRepository returns an empty repository.
func NewCustomerOrderRepository(validate *validator.Validate) *CustomerOrderRepository {
	return &CustomerOrderRepository{
		validate: validate,
		store:    make(map[int64]*CustomerOrder),
	}
}

// Create validates the request and stores a new order.
func (r *CustomerOrderRepository) Create(req CreateCustomerOrderRequest) (*CustomerOrder, error) {
	if err := r.validate.Struct(req); err != nil {
		return nil, fmt.Errorf("validate create request: %w", err)
	}
	r.nextID++
	order := &CustomerOrder{
		ID:         r.nextID,
		CustomerID: req.CustomerID,
		SkuIDs:     req.SkuIDs,
	}
	r.store[order.ID] = order
	return order, nil
}

// Fetch returns the order with orderID, or CustomerOrderNotFoundError.
func (r *CustomerOrderRepository) Fetch(orderID int64) (*CustomerOrder, error) {
	order, ok := r.store[orderID]
	if !ok {
		return nil, &CustomerOrderNotFoundError{OrderID: orderID}
	}
	return order, nil
}
```

`Create` validates at the boundary with `r.validate.Struct(req)`
and wraps the failure with `%w` (reference section 7 and 12).
The validator is injected through the constructor (shared/reference/architecture.md section 2),
so tests can supply their own instance.

`Fetch` uses the comma-ok idiom (`order, ok := r.store[orderID]`)
to distinguish "missing key" from "zero value" in one expression (reference section 11),
then returns the domain error type.

## 3. Concurrent fetching

This block demonstrates shared/reference/go.md section 8 (goroutines, errgroup, context)
and section 11 (`defer` for cleanup).

```go
package adapters

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"

	"golang.org/x/sync/errgroup"

	"example.com/orders/internal/order"
)

// FetchOrders fetches multiple customer orders concurrently.
func FetchOrders(
	ctx context.Context,
	client *http.Client,
	baseURL string,
	orderIDs []int64,
) ([]*order.CustomerOrder, error) {
	g, ctx := errgroup.WithContext(ctx)
	results := make([]*order.CustomerOrder, len(orderIDs))
	for i, id := range orderIDs {
		g.Go(func() error {
			o, err := fetchOne(ctx, client, baseURL, id)
			if err != nil {
				return fmt.Errorf("fetch order %d: %w", id, err)
			}
			results[i] = o
			return nil
		})
	}
	if err := g.Wait(); err != nil {
		return nil, err
	}
	return results, nil
}

func fetchOne(
	ctx context.Context,
	client *http.Client,
	baseURL string,
	id int64,
) (*order.CustomerOrder, error) {
	url := fmt.Sprintf("%s/orders/%d", baseURL, id)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return nil, &order.CustomerOrderNotFoundError{OrderID: id}
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected status %d", resp.StatusCode)
	}

	var o order.CustomerOrder
	if err := json.NewDecoder(resp.Body).Decode(&o); err != nil {
		return nil, fmt.Errorf("decode order %d: %w", id, err)
	}
	return &o, nil
}
```

`errgroup.WithContext` cancels the shared context as soon as any goroutine returns an error,
so in-flight requests stop early (reference section 8).
Each goroutine writes to its own `results[i]` index,
so there is no data race despite the shared slice.

`http.NewRequestWithContext` threads the context through the HTTP call
so cancellation propagates to the network layer.
`defer resp.Body.Close()` guarantees the response body is closed on every return path
(reference section 11).
This example assumes Go 1.22+, where the loop variables `i` and `id` are per-iteration;
on older Go, rebind them inside the loop (reference section 8).

## 4. CLI entry with config loading

This block demonstrates shared/reference/go.md section 6 (`log/slog`),
section 9 (thin `main` calling `run`), and section 7 (error wrapping).

```go
// Command orders is the CLI entry point for the order service.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"os"
)

// ServiceConfig is the service configuration loaded from a JSON file.
type ServiceConfig struct {
	Endpoint       string `json:"endpoint"`
	TimeoutSeconds int    `json:"timeout_seconds"`
	LogLevel       string `json:"log_level"`
}

func loadConfig(path string) (*ServiceConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config %s: %w", path, err)
	}
	var cfg ServiceConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse config %s: %w", path, err)
	}
	return &cfg, nil
}

func run() error {
	configPath := flag.String("config", "config.json", "path to config JSON")
	flag.Parse()

	cfg, err := loadConfig(*configPath)
	if err != nil {
		return err
	}
	slog.Info("connected", "endpoint", cfg.Endpoint)
	return nil
}

func main() {
	if err := run(); err != nil {
		slog.Error("fatal", "err", err)
		os.Exit(1)
	}
}
```

`main` is a thin wrapper that calls `run` and translates its error into an exit code
(reference section 9).
Keeping the logic in `run` (which returns `error`) makes it testable
and keeps `os.Exit` out of the testable path,
since `os.Exit` skips deferred functions.

`log/slog` (Go 1.21+, reference section 6) emits structured key-value logs
(`"endpoint", cfg.Endpoint`) that JSON log backends can parse,
instead of unstructured `log.Printf` strings.

## 5. Package structure

This block demonstrates shared/reference/go.md section 9 (package structure)
and section 4 (naming).

```
orders/
├── cmd/
│   └── orders/
│       └── main.go
├── internal/
│   ├── order/
│   │   ├── model.go
│   │   ├── repository.go
│   │   └── error.go
│   └── adapters/
│       └── http.go
├── go.mod
└── go.sum
```

Organized by domain, not by layer (reference section 9):

- `cmd/orders/main.go` is the thin entry point from Example 4.
- `internal/order/` holds the domain:
  Example 1's types and errors (`model.go`, `error.go`)
  and Example 2's repository (`repository.go`).
  The `internal/` prefix prevents external modules from importing these packages.
- `internal/adapters/http.go` holds Example 3's `FetchOrders`,
  isolating side-effectful network I/O from the pure domain.

All package names are short, lowercase, single words (`order`, `adapters`);
no package is named `util` or `models` (reference section 4 and 9).

## Pitfalls

Common mistakes that the rules in `shared/reference/go.md` are designed to prevent.
Each is a real bug class that ships when the rule is forgotten.

- **Ignoring a returned error.**
  Discarding `err` with `_` or not checking it at all is the Go equivalent of an empty catch block.
  Every `error` return must be checked immediately (reference section 7).
- **Writing to a nil map.**
  Assigning to a map declared but never initialized with `make` panics at runtime.
  Initialize maps with `make` before writing, as the repository constructor does in Example 2.
- **Loop variable capture before Go 1.22.**
  On Go 1.21 and earlier, a goroutine closure capturing the loop variable sees the final value,
  not the per-iteration value.
  Rebind `i, id := i, id` inside the loop, or set the `go` directive to 1.22+ (reference section 8).
- **Forgetting `defer resp.Body.Close()`.**
  An unclosed HTTP response body leaks the connection, eventually exhausting the connection pool.
  Close it with `defer` immediately after checking the error (reference section 11).
- **Using `panic` for ordinary errors.**
  `panic` is for unrecoverable programming errors, not for "order not found".
  Return an `error` value instead (reference section 7 and 10).
- **Comparing errors with `==` instead of `errors.Is`.**
  Wrapped errors (`%w`) do not match the sentinel with `==`.
  Use `errors.Is(err, ErrInsufficientStock)` to match through the wrap chain (reference section 10).
- **Side-effectful `init()`.**
  Performing I/O or acquiring resources in `init()`
  makes the package's import order load-bearing and its tests non-deterministic.
  Use explicit constructors instead (reference section 14).
