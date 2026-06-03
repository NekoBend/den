# Java worked examples

Worked examples demonstrating the rules in `shared/reference/java.md`.
The shared domain is a small order-management system;
each block is a fragment of that system illustrating two or three rules.
Cross-references in the prose point to the corresponding `shared/reference/java.md` section.

Code in these blocks contains only natural comments
(the kind a real developer writes for non-obvious WHY).
Instructional / meta comments belong in this prose, never in the code.

## 1. Domain types and errors

This block demonstrates shared/reference/java.md section 2 (Javadoc),
section 5 (records, sealed interfaces), and section 10 (domain errors).

```java
package com.example.order;

import java.time.Instant;
import java.util.List;

/**
 * An order placed by a customer.
 *
 * @param id unique identifier assigned at creation
 * @param customerId owner of the order
 * @param totalCents total charge in the currency's minor unit
 * @param skuIds stock-keeping-unit identifiers
 */
public record CustomerOrder(long id, long customerId, int totalCents, List<String> skuIds) {}

/** A lifecycle event for a customer order. */
public sealed interface OrderEvent
    permits OrderEvent.Placed, OrderEvent.Shipped, OrderEvent.Delivered {

    record Placed(long orderId) implements OrderEvent {}
    record Shipped(long orderId, String trackingId) implements OrderEvent {}
    record Delivered(long orderId, Instant deliveredAt) implements OrderEvent {}
}

/** Thrown when a customer order ID does not resolve to a row. */
public class CustomerOrderNotFoundException extends RuntimeException {

    private final long orderId;

    public CustomerOrderNotFoundException(long orderId) {
        super("customer order " + orderId + " not found");
        this.orderId = orderId;
    }

    public long getOrderId() {
        return orderId;
    }
}
```

`CustomerOrder` is a record (Java 16+, reference section 5):
the compiler generates the constructor, accessors, `equals`, `hashCode`, and `toString` from the header.
The Javadoc documents each component via `@param` (reference section 2).

`OrderEvent` is a sealed interface (Java 17+)
whose `permits` clause lists exactly the three implementations.
This enables exhaustive `switch` (Example 2) without a default branch.
`CustomerOrderNotFoundException` is an unchecked exception carrying the `orderId`
(reference section 7 and 10).

## 2. Exhaustive switch and persistence

This block demonstrates shared/reference/java.md section 6 (pattern matching for switch),
section 11 (Optional return), and section 10 (throwing domain errors).

```java
package com.example.order;

import java.util.HashMap;
import java.util.Map;
import java.util.Optional;

/** In-memory persistence for customer orders. */
public class CustomerOrderRepository {

    private final Map<Long, CustomerOrder> store = new HashMap<>();

    /**
     * Returns the customer order with {@code orderId}, if present.
     *
     * @param orderId unique identifier of the order
     * @return the order, or empty if none matches
     */
    public Optional<CustomerOrder> findById(long orderId) {
        return Optional.ofNullable(store.get(orderId));
    }

    /**
     * Returns the customer order with {@code orderId}.
     *
     * @throws CustomerOrderNotFoundException if no row matches
     */
    public CustomerOrder fetch(long orderId) {
        return findById(orderId)
            .orElseThrow(() -> new CustomerOrderNotFoundException(orderId));
    }
}

/** Renders a human-readable description of an order event. */
class OrderEventDescriber {

    String describe(OrderEvent event) {
        return switch (event) {
            case OrderEvent.Placed p -> "Order %d placed.".formatted(p.orderId());
            case OrderEvent.Shipped s ->
                "Order %d shipped via %s.".formatted(s.orderId(), s.trackingId());
            case OrderEvent.Delivered d ->
                "Order %d delivered at %s.".formatted(d.orderId(), d.deliveredAt());
        };
    }
}
```

`findById` returns `Optional<CustomerOrder>` because absence is a normal outcome;
`fetch` converts the empty case into a domain exception with `.orElseThrow(...)`
(reference section 11 and 10).

The `switch` expression over `OrderEvent` has no `default` branch (reference section 6).
Because `OrderEvent` is sealed (Example 1), the compiler verifies all three cases are covered;
adding a fourth variant would turn this `switch` into a compile error until handled.

## 3. Concurrent fetching with virtual threads

This block demonstrates shared/reference/java.md section 8 (virtual threads, try-with-resources on ExecutorService)
and section 11 (Stream API).

```java
package com.example.order;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

/** Fetches customer orders from an external HTTP service. */
public class OrderHttpAdapter {

    private final HttpClient httpClient;
    private final String baseUrl;

    public OrderHttpAdapter(HttpClient httpClient, String baseUrl) {
        this.httpClient = httpClient;
        this.baseUrl = baseUrl;
    }

    /**
     * Fetches the raw JSON for each order concurrently.
     *
     * @throws Exception if any request fails
     */
    public List<String> fetchAll(List<Long> orderIds) throws Exception {
        try (ExecutorService executor = Executors.newVirtualThreadPerTaskExecutor()) {
            List<Future<String>> futures = orderIds.stream()
                .map(id -> executor.submit(() -> fetchOne(id)))
                .toList();

            List<String> bodies = new java.util.ArrayList<>(futures.size());
            for (Future<String> future : futures) {
                bodies.add(future.get());
            }
            return bodies;
        }
    }

    private String fetchOne(long id) throws Exception {
        HttpRequest request = HttpRequest.newBuilder(
            URI.create("%s/orders/%d".formatted(baseUrl, id))).build();
        HttpResponse<String> response =
            httpClient.send(request, HttpResponse.BodyHandlers.ofString());
        if (response.statusCode() == 404) {
            throw new CustomerOrderNotFoundException(id);
        }
        return response.body();
    }
}
```

`Executors.newVirtualThreadPerTaskExecutor()` creates one lightweight virtual thread per task
(Java 21+, reference section 8);
no pooling is needed because virtual threads are cheap.
The try-with-resources block closes the executor automatically,
which waits for all submitted tasks to finish.

`orderIds.stream().map(...).toList()` builds the future list with the Stream API
(reference section 11).
The dependency `httpClient` is injected through the constructor (shared/reference/architecture.md section 2).

## 4. Validation at the boundary

This block demonstrates shared/reference/java.md section 12 (Jakarta Bean Validation)
and section 5 (records as request DTOs).

```java
package com.example.order;

import jakarta.validation.Valid;
import jakarta.validation.Validator;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;
import java.util.List;
import java.util.Set;
import jakarta.validation.ConstraintViolation;

/** Validated payload for creating a customer order. */
public record CreateCustomerOrderRequest(
    @NotNull @Positive Long customerId,
    @NotEmpty List<@NotEmpty String> skuIds
) {}

/** Application service for creating orders. */
public class CreateOrderService {

    private final Validator validator;
    private final CustomerOrderRepository repository;

    public CreateOrderService(Validator validator, CustomerOrderRepository repository) {
        this.validator = validator;
        this.repository = repository;
    }

    /**
     * Validates the request at the boundary, then delegates to the
     * repository.
     *
     * @throws IllegalArgumentException if the request is invalid
     */
    public CustomerOrder create(@Valid CreateCustomerOrderRequest request) {
        Set<ConstraintViolation<CreateCustomerOrderRequest>> violations =
            validator.validate(request);
        if (!violations.isEmpty()) {
            throw new IllegalArgumentException("invalid request: " + violations);
        }
        // request is validated; internal code trusts the fields.
        return repository.fetch(request.customerId());
    }
}
```

`CreateCustomerOrderRequest` is a record carrying Jakarta Bean Validation annotations
(reference section 12).
The `@NotEmpty` on the list element type (`List<@NotEmpty String>`) validates each element,
not just the list.
Jakarta Validation 3.1+ supports validating records directly.

`create` runs validation once at the boundary;
the comment marks where trust begins.
The `Validator` is injected, so tests supply their own.

## 5. Project structure

This block demonstrates shared/reference/java.md section 9 (package layout)
and section 4 (naming).

```
project/
├── src/
│   ├── main/java/
│   │   └── com/example/order/
│   │       ├── CustomerOrder.java
│   │       ├── OrderEvent.java
│   │       ├── CustomerOrderRepository.java
│   │       ├── CustomerOrderNotFoundException.java
│   │       ├── OrderHttpAdapter.java
│   │       ├── CreateCustomerOrderRequest.java
│   │       └── CreateOrderService.java
│   └── test/java/
│       └── com/example/order/
│           └── CustomerOrderRepositoryTest.java
├── pom.xml
└── ...
```

Package-by-feature, not package-by-layer (reference section 9):
all order-related types live in `com.example.order`
rather than being split across `com.example.model`, `com.example.repository`, and `com.example.service`.

- One public class per file;
  the filename matches the class name (reference section 9).
- `src/test/java` mirrors `src/main/java` with the same package structure;
  test classes use the `Test` suffix.
- All class names are `PascalCase`;
  the package name is all-lowercase (reference section 4).

## Pitfalls

Common mistakes that the rules in `shared/reference/java.md` are designed to prevent.
Each is a real bug class that ships when the rule is forgotten.

- **Returning `null` instead of `Optional` or throwing.**
  A method declared `CustomerOrder fetch(...)`
  that returns `null` invites a `NullPointerException` at the call site.
  Return `Optional` for expected absence or throw a domain exception (reference section 14 and 10).
- **Manually closing resources in `finally`.**
  Forgetting the close, or closing in the wrong order, leaks file handles and connections.
  Use try-with-resources for every `AutoCloseable` (reference section 11).
- **Mutable static state.**
  A `static` mutable field shared across threads is a data race.
  Prefer instance fields injected through constructors (shared/reference/architecture.md section 2).
- **Catching `Exception` broadly in mid-level code.**
  A broad catch hides bugs that should propagate.
  Catch the narrowest type, and only catch broadly at top-level entry points
  (reference section 7, shared/reference/architecture.md section 5).
- **`Optional` as a field or parameter.**
  `Optional` is designed as a return type.
  As a field it adds boxing overhead and breaks serialization;
  as a parameter it forces callers to wrap arguments (reference section 11 and 14).
- **`switch` over a sealed type with a `default` branch.**
  Adding a `default` defeats exhaustiveness checking:
  a new variant compiles silently instead of forcing every `switch` to handle it (reference section 6).
- **Blocking inside `synchronized` on a virtual thread (Java 21-23).**
  The virtual thread pins to its carrier, defeating the scalability benefit.
  Use `ReentrantLock`, or upgrade to Java 24+ where JEP 491 resolves the pinning (reference section 8).
