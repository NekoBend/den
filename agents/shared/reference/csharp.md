# C# language reference

C#-specific conventions for the `coding` skill.
Layered on top of `architecture.md` (12 generic rules).
When both apply, this file refines or specializes the generic rule.
Never contradict.

Apply with version awareness:
section 13 governs which constructs are admissible
based on the project's target framework and C# language version.
Always read that section before proposing modern syntax.

## 1. Style guide: Microsoft .NET Coding Conventions

**Rule:** Follow the Microsoft .NET Coding Conventions
(`learn.microsoft.com/dotnet/csharp/fundamentals/coding-style/coding-conventions`)
as the baseline.
Enforce via `.editorconfig` at the repository root.
**Why:** The Microsoft conventions are the de facto standard for the C# ecosystem.
`.editorconfig` is consumed by Visual Studio, Rider, VS Code (OmniSharp), and `dotnet format`,
making enforcement automatic across editors.
Teams with their own conventions override in their `.editorconfig`.

## 2. Doc comments: XML documentation (///)

**Rule:** Every public type, method, property, and event gets a `///` XML doc comment.
Use `<summary>`, `<param>`, `<returns>`, `<exception>`, `<remarks>`, `<example>` elements as applicable.
The `<summary>` is a single sentence.
**Why:** The compiler extracts XML docs into a separate file
consumed by IntelliSense, NuGet package documentation, and doc-generation tools (DocFX, Sandcastle).
Omitting `<summary>` triggers compiler warning CS1591
when `<GenerateDocumentationFile>` is enabled.
**Example:**

```csharp
/// <summary>
/// Persistence layer for customer orders.
/// </summary>
/// <remarks>
/// Stores orders in memory; not suitable for production.
/// </remarks>
public class CustomerOrderRepository
{
    /// <summary>
    /// Returns the customer order with <paramref name="orderId"/>.
    /// </summary>
    /// <param name="orderId">Unique identifier of the order.</param>
    /// <returns>The matching order.</returns>
    /// <exception cref="CustomerOrderNotFoundException">
    /// No row matches <paramref name="orderId"/>.
    /// </exception>
    public CustomerOrder Fetch(long orderId)
    {
        // ...
    }
}
```

## 3. Tooling: dotnet format + Roslyn analyzers

**Rule:** Default formatter and style enforcer is `dotnet format` (ships with the .NET SDK).
Default analyzers are the built-in .NET Roslyn analyzers (enabled by default on .NET 5+).
For additional coverage, add Roslynator (`github.com/dotnet/roslynator`)
or Meziantou.Analyzer as NuGet packages.
Configure all rules in `.editorconfig`.
**Why:** `dotnet format` applies `.editorconfig` rules to formatting, naming, and code style in one pass.
Roslyn analyzers run during compilation
and surface warnings as build errors when configured with `<TreatWarningsAsErrors>`.
No separate linter binary is needed.
**Run order:** `dotnet format` then `dotnet build` (analyzers run during build).

## 4. Naming

**Rule:**

- Classes, structs, records, enums, methods, properties, events, namespaces, constants: `PascalCase`.
- Interfaces: `IPascalCase` (prefix with `I`).
  This is a C# convention; do not drop the prefix.
- Local variables, parameters: `camelCase`.
- Private and internal fields: `_camelCase` (leading underscore).
- Type parameters: `TPascalCase` (`TKey`, `TValue`, `TResult`).
- No `UPPER_SNAKE_CASE` for constants;
  C# uses `PascalCase` for `const` and `static readonly` fields.

**Why:** The Microsoft and dotnet/runtime coding guidelines codify these patterns.
The `I` prefix on interfaces and `_` prefix on private fields are longstanding C# conventions
that differ from other languages;
dropping them would conflict with the entire .NET ecosystem.
**Example:**

```csharp
public const int MaxRetries = 5;

public record CustomerOrder(long Id, long CustomerId, int TotalCents, IReadOnlyList<string> SkuIds);

public interface ICustomerOrderStore
{
    CustomerOrder Fetch(long orderId);
}
```

## 5. Type system: interfaces, generics, records, nullable reference types

**Rule:**

- Prefer interfaces for contracts.
  Use default interface methods (C# 8+) sparingly;
  they are for backward-compatible API evolution, not general-purpose implementation.
- Use records (C# 9+) and record structs (C# 10+) for immutable data.
  Records provide value equality, deconstruction, and `with`-expression copy semantics out of the box.
- Use generics with constraints (`where T : IComparable<T>`) to express bounds.
  Avoid unconstrained `object` parameters.
- Enable nullable reference types (NRT) project-wide (see section 7).

**Why:** Records replace manual equals/hashCode/toString with a single declaration.
NRT shifts null-safety checks from runtime to compile time.
Constrained generics prevent type errors
that would otherwise surface as `InvalidCastException` at runtime.
**See architecture.md section 6** for the generic rule
about preferring explicit types over escape hatches.
**Example:**

```csharp
public record CustomerOrder(long Id, long CustomerId, int TotalCents, IReadOnlyList<string> SkuIds);

public sealed record OrderPlaced(long OrderId) : OrderEvent;
public sealed record OrderShipped(long OrderId, string TrackingId) : OrderEvent;
```

## 6. Modern syntax minimums

**Rule:** Use the highest-version form admissible by the project's `LangVersion` and `TargetFramework`
(see section 13).
Common version-gated upgrades:

| C# | Modern form | Legacy form to avoid |
|---|---|---|
| 8 | nullable reference types (`string?`) | unchecked null everywhere |
| 8 | `using` declaration (no braces) | `using` statement with block |
| 8 | switch expressions | multi-line `switch` statement for assignment |
| 9 | records | manual POCO with equals/hashCode |
| 10 | file-scoped namespaces | block-scoped `namespace { }` |
| 10 | global usings | repeated `using` in every file |
| 11 | raw string literals (`"""..."""`) | escaped or verbatim multi-line strings |
| 12 | primary constructors for classes | separate constructor + field assignments |
| 12 | collection expressions (`[1, 2, 3]`) | `new List<int> { 1, 2, 3 }` |

**Why:** Each new form removes boilerplate.
File-scoped namespaces alone remove one level of indentation from every file in the project.
**Defer to section 13** before applying.

## 7. Nullable reference types (NRT) discipline

**Rule:** Enable NRT project-wide by setting `<Nullable>enable</Nullable>` in the `.csproj`.
Treat all compiler nullable warnings as errors
(`<WarningsAsErrors>nullable</WarningsAsErrors>` or `<TreatWarningsAsErrors>true</TreatWarningsAsErrors>`).
Annotate every parameter, return, and property that may legitimately be null with `?`.
Do not suppress warnings with `!` (the null-forgiving operator)
except at proven-safe interop boundaries.

**Why:** NRT is C#'s compile-time null-safety system (C# 8+).
When enabled, the compiler assumes reference types are non-null by default
and warns on potential null dereference.
Suppressing warnings with `!` defeats the purpose;
each suppression is a potential `NullReferenceException` at runtime.
**Example:**

```csharp
public CustomerOrder? FindById(long orderId)
{
    return _store.GetValueOrDefault(orderId);
}

// Caller:
var order = repository.FindById(orderId)
    ?? throw new CustomerOrderNotFoundException(orderId);
```

## 8. Async: async/await, Task, CancellationToken

**Rule:**

- Use `async`/`await` for all I/O-bound operations.
  Return `Task<T>` or `ValueTask<T>`, not `void` (except for event handlers).
- Propagate `CancellationToken` as the last parameter of every async method
  and pass it to all downstream async calls.
- In library code, use `ConfigureAwait(false)` on every `await`
  to avoid capturing the synchronization context.
  Application code (ASP.NET Core controllers, Blazor components) does not need it
  because ASP.NET Core has no `SynchronizationContext`.
- Do not call `.Result` or `.Wait()` on a `Task`;
  these block the calling thread and can cause deadlocks.

**Why:** Blocking on an async `Task` with `.Result` or `.Wait()`
starves the thread pool (in ASP.NET Core)
or deadlocks (in UI frameworks with a `SynchronizationContext`).
`CancellationToken` propagation enables graceful shutdown;
omitting it means requests cannot be cancelled when the server drains.
**Example:**

```csharp
public async Task<IReadOnlyList<byte[]>> FetchAllAsync(
    IReadOnlyList<string> urls,
    CancellationToken cancellationToken = default)
{
    var tasks = urls.Select(url => _httpClient.GetByteArrayAsync(url, cancellationToken));
    return await Task.WhenAll(tasks);
}
```

## 9. Project structure

**Rule:** Follow the .NET solution/project standard layout:

```
MySolution/
├── src/
│   └── MyProject.Orders/
│       ├── MyProject.Orders.csproj
│       ├── CustomerOrder.cs
│       ├── CustomerOrderRepository.cs
│       ├── CustomerOrderNotFoundException.cs
│       └── CreateCustomerOrderRequest.cs
├── tests/
│   └── MyProject.Orders.Tests/
│       ├── MyProject.Orders.Tests.csproj
│       └── CustomerOrderRepositoryTests.cs
├── MySolution.sln
├── Directory.Build.props
└── .editorconfig
```

- One class per file; filename matches the type name.
- Organize by domain namespace (`MyProject.Orders`) not by layer (`MyProject.Repositories`).
- `Directory.Build.props` at the repo root for shared settings
  (`LangVersion`, `Nullable`, `TreatWarningsAsErrors`).
- `tests/` mirrors `src/` with `.Tests` suffix on project names.

**Why:** The solution/project structure is assumed by `dotnet build`, Visual Studio, and Rider.
`Directory.Build.props` ensures every project inherits the same language version and analyzer settings.
**When over:** A project with more than ~20 files or mixed concerns
is a candidate for splitting into focused projects.

## 10. Domain errors

**Rule:** Define domain-specific exception classes extending `Exception` (not `ApplicationException`).
Include the domain entity ID as a property and a human-readable message.
Provide constructors with and without an inner exception for cause chaining.

**Why:** Custom exceptions let callers filter with `catch (CustomerOrderNotFoundException)` at the boundary.
Including the entity ID makes the error actionable in structured logs.
Inner exception chaining preserves the original failure.
**Cross-ref:** architecture.md section 5 (catch narrow, propagate broad).
**Example:**

```csharp
public class CustomerOrderNotFoundException : Exception
{
    public long OrderId { get; }

    public CustomerOrderNotFoundException(long orderId)
        : base($"Customer order {orderId} not found")
    {
        OrderId = orderId;
    }

    public CustomerOrderNotFoundException(long orderId, Exception innerException)
        : base($"Customer order {orderId} not found", innerException)
    {
        OrderId = orderId;
    }
}
```

## 11. Idiomatic patterns

**Rule:** Prefer C#'s native idioms over manual equivalents:

- **LINQ** (`.Where()`, `.Select()`, `.FirstOrDefault()`, `.GroupBy()`)
  over manual loops when the operation is transformational.
- **`using` declaration** (C# 8+, no braces) for `IDisposable` resources.
  The scope is the enclosing block.
- **Pattern matching** (`is`, `switch` expression, property patterns)
  for multi-branch type checks and deconstruction.
- **String interpolation** (`$"Order {id}"`) over `string.Format` or concatenation.
- **Collection expressions** (C# 12+, `[1, 2, 3]`) for initializing arrays, lists, and spans.
- **`??` (null coalescing)** and **`??=` (null coalescing assignment)** for default-value fallback.

**Why:** See architecture.md section 12 (Idiomatic over portable).
LINQ chains are the C# equivalent of Python comprehensions and Rust iterator chains;
they express transformation declaratively and let the runtime optimize evaluation.
**Example:**

```csharp
var shippedIds = orders
    .Where(o => o.Status == OrderStatus.Shipped)
    .Select(o => o.Id)
    .ToList();

var name = customer.DisplayName ?? "Unknown";
```

## 12. Validation at boundaries

**Rule:** Concentrate input validation at the controller or API entry point.
For simple models, use DataAnnotations (`System.ComponentModel.DataAnnotations`).
For complex validation logic, use FluentValidation (`fluentvalidation.net`);
call validators manually or via endpoint filters
(FluentValidation 12+ deprecated auto-validation in ASP.NET Core).
Internal services trust their typed parameters.

**Why:** See architecture.md section 9 (Validate at boundaries, trust internals).
C#'s type system covers shape at compile time;
DataAnnotations and FluentValidation add runtime semantic checks
(`[Required]`, `[Range]`, `.NotEmpty()`, `.GreaterThan(0)`).
Validating once at the boundary avoids duplicated checks in service layers.
**Example (DataAnnotations):**

```csharp
public record CreateCustomerOrderRequest(
    [property: Required, Range(1, long.MaxValue)] long CustomerId,
    [property: Required, MinLength(1)] IReadOnlyList<string> SkuIds
);
```

## 13. Version awareness

**Rule:** Before proposing any version-gated form (sections 5, 6, 7, 8),
read the project's `.csproj`:

- `<TargetFramework>`: the .NET version (`net8.0`, `net9.0`, `net10.0`).
  Determines available runtime APIs.
- `<LangVersion>`: the C# language version.
  Defaults to the highest version supported by the target framework; can be pinned lower.
- `<Nullable>`: `enable` or `disable`.
  NRT (section 7) requires `enable`.

If `TargetFramework` is `net6.0`,
do not propose C# 12 features (primary constructors, collection expressions)
or .NET 8+ APIs (HybridCache, FrozenDictionary).
If `LangVersion` is pinned to `10`,
do not propose raw string literals or required members.
**Why:** The C# language version is tied to the target framework by default.
Proposing features above the target breaks the build.
The mapping is published at
`learn.microsoft.com/dotnet/csharp/language-reference/configure-language-version`.
**When declarations are absent:** ask the user for the target framework before proposing modern features.

## 14. IDisposable and IAsyncDisposable discipline

**Rule:**

- Any type that holds unmanaged resources or owns other `IDisposable` objects
  must implement `IDisposable` (or `IAsyncDisposable` for async cleanup).
- Callers must use `using` declarations or `using` statements;
  never rely on the finalizer to clean up.
- In async code, prefer `IAsyncDisposable` with `await using`
  so that cleanup does not block a thread.
- If implementing both interfaces, provide a protected `Dispose(bool disposing)` pattern
  only when the class is designed for inheritance.
  Sealed classes can implement `Dispose()` directly.

**Why:** The garbage collector does not guarantee when (or if) finalizers run.
Leaked database connections, file handles, and HTTP clients exhaust OS resources under load.
`using` guarantees cleanup at scope exit,
and `await using` does so without blocking the thread pool.
**Example:**

```csharp
await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync(cancellationToken);

// connection is disposed at end of enclosing scope.
```
