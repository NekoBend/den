# Java language reference

Java-specific conventions for the `coding` skill.
Layered on top of `architecture.md` (12 generic rules).
When both apply, this file refines or specializes the generic rule.
Never contradict.

Apply with version awareness:
section 13 governs which constructs are admissible based on the project's JDK version.
Always read that section before proposing modern syntax.

## 1. Style guide: Google Java Style Guide

**Rule:** Follow the Google Java Style Guide
(`google.github.io/styleguide/javaguide.html`) as the baseline.
**Why:** The Google guide is the most widely adopted Java style reference
outside enterprise-specific standards.
It covers formatting, naming, Javadoc, imports, exception handling,
and concurrency conventions.
Teams with their own guide override via project config (see section 3).

## 2. Doc comments: Javadoc

**Rule:** Every public class, interface, method, and field
gets a Javadoc comment (`/** ... */`).
The first sentence is a summary fragment ending with a period.
Use `@param`, `@return`, `@throws`, `@see`, `@since` tags as applicable.
**Why:** `javadoc` generates HTML documentation;
IDEs display Javadoc in autocomplete tooltips.
The summary sentence is extracted as the synopsis in package indexes.
**Example:**

```java
/**
 * Persistence layer for customer orders.
 *
 * <p>Stores orders in memory; not suitable for production.
 */
public class CustomerOrderRepository {

    /**
     * Returns the customer order with {@code orderId}.
     *
     * @param orderId unique identifier of the order
     * @return the matching order
     * @throws CustomerOrderNotFoundException if no row matches
     */
    public CustomerOrder fetch(long orderId) {
        // ...
    }
}
```

## 3. Tooling: google-java-format + checkstyle + Error Prone

**Rule:** Default formatter is `google-java-format`
(`github.com/google/google-java-format`).
Default style checker is `checkstyle` (`checkstyle.org`) with the Google checks configuration.
For compile-time bug detection, add Error Prone (`errorprone.info`) as a javac plugin;
it catches correctness issues (null dereference, misused APIs, concurrency bugs)
that style checkers do not cover.
The compiler's `-Xlint:all` flag catches common warnings (unchecked casts, deprecation, raw types).
**Why:** `google-java-format` enforces the Google Java Style Guide formatting with zero configuration.
`checkstyle` covers naming, import order, and Javadoc.
Error Prone detects the largest number of bug patterns among Java static analyzers
and integrates as a compiler plugin with zero separate invocation step.
**Run order:** `google-java-format --replace` then `checkstyle` then `javac -Xlint:all`
(with Error Prone plugin enabled).

## 4. Naming

**Rule:**

- Classes, interfaces, enums, records, annotations: `PascalCase`.
- Methods, fields, parameters, local variables: `camelCase`.
- Constants (`static final` primitives and immutable objects): `UPPER_SNAKE_CASE`.
- Packages: all lowercase, no underscores (`com.example.order`).
- Type parameters: single uppercase letter (`T`, `E`, `K`, `V`)
  or short PascalCase (`RequestT`).

**Why:** The Google Java Style Guide and decades of Java convention codify these patterns.
Deviating makes code visually inconsistent with the entire Java ecosystem.
**Example:**

```java
static final int MAX_RETRIES = 5;

record CustomerOrder(long id, long customerId, int totalCents, List<String> skuIds) {}

interface CustomerOrderStore {
    CustomerOrder fetch(long orderId);
}
```

## 5. Type system: interfaces, generics, sealed classes, records

**Rule:**

- Prefer interfaces over abstract classes for defining contracts.
  Use `sealed` interfaces (Java 17+) when the set of implementations is finite and known.
- Use records (Java 16+) for immutable data carriers
  instead of manual POJO classes with getters, equals, hashCode, and toString.
- Use generics with bounded wildcards (`? extends T`, `? super T`)
  at API boundaries per PECS (Producer Extends, Consumer Super).
- Avoid raw types; the compiler treats them as unchecked and generates warnings.

**Why:** Records eliminate boilerplate for value objects.
Sealed classes enable exhaustive pattern matching (section 7).
Generics with proper bounds preserve type safety without requiring casts.
**See architecture.md section 6** for the generic rule
about preferring explicit types over escape hatches.
**Example:**

```java
sealed interface OrderEvent permits OrderPlaced, OrderShipped, OrderDelivered {}

record OrderPlaced(long orderId) implements OrderEvent {}
record OrderShipped(long orderId, String trackingId) implements OrderEvent {}
record OrderDelivered(long orderId, Instant deliveredAt) implements OrderEvent {}
```

## 6. Modern syntax minimums

**Rule:** Use the highest-version form admissible by the project's JDK version (see section 13).
Common version-gated upgrades:

| JDK | Modern form | Legacy form to avoid |
|---|---|---|
| 10+ | `var` for local variables with obvious types | explicit type on every local |
| 15+ | text blocks (`"""..."""`) | concatenated multi-line strings |
| 16+ | records | manual POJO with getters/equals/hashCode |
| 16+ | `instanceof` pattern matching | cast after instanceof check |
| 17+ | sealed classes/interfaces | unconstrained interface hierarchies |
| 21+ | pattern matching for switch | chained if-else instanceof |
| 21+ | virtual threads (`Thread.ofVirtual()`) | platform thread pools for I/O-bound work |

**Why:** Each new form removes boilerplate or replaces unsafe patterns.
Records in particular eliminate hundreds of lines of equals/hashCode/toString
that are error-prone when fields change.
**Defer to section 13** before applying.

## 7. Checked vs unchecked exceptions

**Rule:** Use unchecked exceptions (`RuntimeException` subclasses)
for domain errors and programming errors.
Reserve checked exceptions for truly recoverable conditions that the caller MUST handle
(e.g., `IOException` from a retryable network call).
Do not declare checked exceptions on interfaces intended for diverse implementations.

**Why:** Checked exceptions that callers cannot meaningfully handle
produce empty catch blocks or `throws` chains that propagate to the top without adding value.
Domain errors (`CustomerOrderNotFoundException`) are better modeled as unchecked exceptions
that the handler layer catches at the boundary,
similar to Go's explicit error returns and Rust's `Result`.
**Cross-ref:** architecture.md section 5 (catch narrow, propagate broad).

## 8. Concurrency: virtual threads, CompletableFuture

**Rule:**

- Use virtual threads (Java 21+, `Executors.newVirtualThreadPerTaskExecutor()`)
  for I/O-bound concurrent workloads.
  Virtual threads are lightweight and do not require pooling.
- Use `CompletableFuture` for composing independent async operations
  when the project targets JDK < 21 or when explicit composition (`thenCombine`, `allOf`) is needed.
- On Java 21-23, avoid `synchronized` across blocking I/O in virtual threads
  (the virtual thread pins to the carrier thread).
  Use `ReentrantLock` instead.
  Java 24+ (JEP 491) resolves this pinning;
  `synchronized` is safe with virtual threads again.
- Use `try-with-resources` on `ExecutorService` (Java 19+) for automatic shutdown.

**Why:** Virtual threads (JEP 444) eliminate the need for reactive frameworks (Project Reactor, RxJava)
in most I/O-bound scenarios.
One virtual thread per request is simpler than callback chains
and scales to millions of concurrent tasks.
**Example:**

```java
try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
    List<Future<byte[]>> futures = urls.stream()
        .map(url -> executor.submit(() -> httpClient.send(
            HttpRequest.newBuilder(URI.create(url)).build(),
            HttpResponse.BodyHandlers.ofByteArray()
        ).body()))
        .toList();
    for (var future : futures) {
        byte[] body = future.get();
        // process body
    }
}
```

## 9. Package structure

**Rule:** Follow the Maven/Gradle standard directory layout:

```
project/
├── src/
│   ├── main/java/
│   │   └── com/example/order/
│   │       ├── CustomerOrder.java
│   │       ├── CustomerOrderRepository.java
│   │       ├── CustomerOrderNotFoundException.java
│   │       └── CreateCustomerOrderRequest.java
│   └── test/java/
│       └── com/example/order/
│           └── CustomerOrderRepositoryTest.java
├── pom.xml (or build.gradle.kts)
└── ...
```

- One public class per file; filename matches the class name.
- Package-by-feature (`com.example.order`) over package-by-layer (`com.example.repository`).
- `src/test/java` mirrors `src/main/java` with the same package structure.
  Test classes use the `Test` suffix.

**Why:** The standard layout is assumed by Maven, Gradle, and every Java IDE.
Package-by-feature groups related types and reduces cross-package coupling.
**When over:** A package with more than ~10-15 classes is a candidate for sub-packages.

## 10. Domain errors

**Rule:** Define domain-specific unchecked exception classes extending `RuntimeException`.
Include the domain entity ID and a human-readable message.
Chain the underlying cause via the `Throwable cause` constructor parameter.

**Why:** Unchecked exceptions do not pollute method signatures with `throws` declarations.
Including the entity ID makes the error actionable in logs.
Cause chaining preserves the original failure for debugging.
**Cross-ref:** architecture.md section 5 (catch narrow, propagate broad).
Section 7 covers the checked/unchecked decision;
this section covers the type design.
**Example:**

```java
public class CustomerOrderNotFoundException extends RuntimeException {

    private final long orderId;

    public CustomerOrderNotFoundException(long orderId) {
        super("customer order " + orderId + " not found");
        this.orderId = orderId;
    }

    public CustomerOrderNotFoundException(long orderId, Throwable cause) {
        super("customer order " + orderId + " not found", cause);
        this.orderId = orderId;
    }

    public long getOrderId() {
        return orderId;
    }
}
```

## 11. Idiomatic patterns

**Rule:** Prefer Java's native idioms over manual equivalents:

- **try-with-resources** for any `AutoCloseable` (streams, connections, executors).
  Never close resources in a `finally` block manually.
- **`Optional`** as a return type for values that may be absent.
  Do NOT use `Optional` as a field, parameter, or collection element.
- **Stream API** (`.stream().filter().map().collect()`)
  over manual loops when the operation is transformational.
- **`var`** (Java 10+) for local variables when the type is obvious from the right-hand side.
- **Records** (Java 16+) for data carriers instead of hand-rolled POJOs.
- **Pattern matching for switch** (Java 21+) for multi-branch `instanceof` logic.

**Why:** See architecture.md section 12 (Idiomatic over portable).
try-with-resources guarantees cleanup even when exceptions are thrown;
manual close in `finally` is error-prone and verbose.
**Example:**

```java
Optional<CustomerOrder> found = repository.findById(orderId);
String summary = found
    .map(order -> "Order %d for customer %d".formatted(order.id(), order.customerId()))
    .orElse("Order not found");
```

## 12. Validation at boundaries

**Rule:** Concentrate input validation at the controller or API entry point.
Use Jakarta Bean Validation (`jakarta.validation`) annotations
with Hibernate Validator as the runtime.
Internal services trust their typed parameters.

**Why:** See architecture.md section 9 (Validate at boundaries, trust internals).
Java's type system covers shape at compile time;
Bean Validation adds semantic constraints (`@NotNull`, `@Min`, `@NotEmpty`, `@Email`) via annotations.
Jakarta Validation 3.1+ (targeting Java 21) includes clarified support for record validation.
Validating once at the boundary avoids duplicated checks in service layers.
**Example:**

```java
public record CreateCustomerOrderRequest(
    @NotNull @Positive Long customerId,
    @NotEmpty List<@NotBlank String> skuIds
) {}
```

## 13. Version awareness

**Rule:** Before proposing any version-gated form (sections 5, 6, 8),
read the project's declared JDK version:

- `pom.xml` `<maven.compiler.source>` / `<maven.compiler.target>` or `<maven.compiler.release>`.
- `build.gradle.kts` `java.sourceCompatibility` / `java.targetCompatibility` or `jvmToolchain(N)`.
- CI configuration specifying the JDK distribution and version.

If the target is JDK 17,
do not propose virtual threads, pattern matching for switch, or `try-with-resources` on `ExecutorService`.
If the target is JDK 11,
do not propose records, sealed classes, or text blocks.
**Why:** The `javac --release N` flag restricts available APIs to the specified JDK version.
Proposing features above the target breaks the build for every developer on the declared version.
**When declarations are absent:** ask the user for the target JDK before proposing modern features.

## 14. Null safety and Optional discipline

**Rule:**

- Annotate parameters and return types with `@Nullable` and `@NonNull`
  (from `org.jspecify`, the vendor-neutral standard adopted by Spring Framework 7).
  Treat unannotated types as non-null by default.
- Return `Optional<T>` when absence is a normal, expected outcome (not an error).
  Do NOT use `Optional` as a field, method parameter, or collection element.
- Never return `null` from a method that does not return `Optional`.
  If absence is an error, throw a domain exception (section 10).
- Use `Optional.map` / `Optional.orElseThrow` / `Optional.orElse` chains
  instead of `if (x != null)` nesting.

**Why:** `NullPointerException` is Java's most common runtime failure.
`@Nullable` / `@NonNull` annotations let static analysis tools
(Error Prone, NullAway, IntelliJ inspections) flag null-unsafe code at compile time.
JSpecify 1.0 (released 2024) is the current recommended annotation package;
ecosystem adoption is growing (Spring Framework 7 adopted it in 2025) but not yet universal.
`Optional` as a return type signals to the caller that absence is expected;
using it as a field or parameter adds boxing overhead without safety benefit.
**Example:**

```java
public Optional<CustomerOrder> findById(long orderId) {
    return Optional.ofNullable(store.get(orderId));
}

// Caller:
CustomerOrder order = repository.findById(orderId)
    .orElseThrow(() -> new CustomerOrderNotFoundException(orderId));
```
