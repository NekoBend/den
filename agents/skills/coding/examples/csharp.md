# C# worked examples

Worked examples demonstrating the rules in `shared/reference/csharp.md`.
The shared domain is a small order-management system;
each block is a fragment of that system illustrating two or three rules.
Cross-references in the prose point to the corresponding `shared/reference/csharp.md` section.

Code in these blocks contains only natural comments
(the kind a real developer writes for non-obvious WHY).
Instructional / meta comments belong in this prose, never in the code.

## 1. Domain types and errors

This block demonstrates shared/reference/csharp.md section 2 (XML docs),
section 5 (records, NRT), and section 10 (domain errors).

```csharp
namespace Example.Orders;

/// <summary>
/// An order placed by a customer.
/// </summary>
/// <param name="Id">Unique identifier assigned at creation.</param>
/// <param name="CustomerId">Owner of the order.</param>
/// <param name="TotalCents">Total charge in the currency's minor unit.</param>
/// <param name="SkuIds">Stock-keeping-unit identifiers.</param>
public record CustomerOrder(
    long Id,
    long CustomerId,
    int TotalCents,
    IReadOnlyList<string> SkuIds);

/// <summary>
/// Thrown when a customer order ID does not resolve to a row.
/// </summary>
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

`CustomerOrder` is a positional record (C# 9+, reference section 5):
the compiler generates the constructor, properties, value equality, and `ToString`.
The XML `<param>` elements document each component (reference section 2).

`CustomerOrderNotFoundException` extends `Exception`
with the `OrderId` exposed as a property and two constructors, one for cause chaining
(reference section 10).
With NRT enabled, the non-nullable `string` message parameters cannot be passed `null`
without a compiler warning.

## 2. Persistence with NRT

This block demonstrates shared/reference/csharp.md section 7 (nullable reference types)
and section 11 (null-coalescing, collection expressions).

```csharp
namespace Example.Orders;

/// <summary>
/// In-memory persistence for customer orders.
/// </summary>
public class CustomerOrderRepository
{
    private readonly Dictionary<long, CustomerOrder> _store = [];
    private long _nextId;

    /// <summary>
    /// Returns the customer order with <paramref name="orderId"/>, or
    /// <c>null</c> if none matches.
    /// </summary>
    public CustomerOrder? FindById(long orderId)
    {
        return _store.GetValueOrDefault(orderId);
    }

    /// <summary>
    /// Returns the customer order with <paramref name="orderId"/>.
    /// </summary>
    /// <exception cref="CustomerOrderNotFoundException">
    /// No row matches <paramref name="orderId"/>.
    /// </exception>
    public CustomerOrder Fetch(long orderId)
    {
        return FindById(orderId)
            ?? throw new CustomerOrderNotFoundException(orderId);
    }

    /// <summary>
    /// Stores a new order and returns it.
    /// </summary>
    public CustomerOrder Create(long customerId, IReadOnlyList<string> skuIds)
    {
        var order = new CustomerOrder(++_nextId, customerId, 0, skuIds);
        _store[order.Id] = order;
        return order;
    }
}
```

`FindById` returns `CustomerOrder?` (nullable) because absence is a normal outcome;
the `?` is meaningful only because NRT is enabled (reference section 7).
`Fetch` converts the null case into a domain exception with the null-coalescing throw `?? throw`
(reference section 11).

The field initializer `= []` is a collection expression (C# 12+, reference section 6)
replacing `new Dictionary<long, CustomerOrder>()`.
The `_store` field uses the `_camelCase` private-field convention (reference section 4).

## 3. Async fetching

This block demonstrates shared/reference/csharp.md section 8 (async/await, CancellationToken, Task.WhenAll)
and section 11 (LINQ).

```csharp
using System.Net.Http.Json;

namespace Example.Orders;

/// <summary>
/// Fetches customer orders from an external HTTP service.
/// </summary>
public class OrderHttpAdapter(HttpClient httpClient)
{
    /// <summary>
    /// Fetches multiple customer orders concurrently.
    /// </summary>
    /// <exception cref="CustomerOrderNotFoundException">
    /// Any requested ID is missing.
    /// </exception>
    public async Task<IReadOnlyList<CustomerOrder>> FetchAllAsync(
        IReadOnlyList<long> orderIds,
        CancellationToken cancellationToken = default)
    {
        var tasks = orderIds.Select(id => FetchOneAsync(id, cancellationToken));
        return await Task.WhenAll(tasks);
    }

    private async Task<CustomerOrder> FetchOneAsync(
        long orderId,
        CancellationToken cancellationToken)
    {
        var response = await httpClient.GetAsync(
            $"orders/{orderId}", cancellationToken);
        if (response.StatusCode == System.Net.HttpStatusCode.NotFound)
        {
            throw new CustomerOrderNotFoundException(orderId);
        }
        response.EnsureSuccessStatusCode();
        var order = await response.Content
            .ReadFromJsonAsync<CustomerOrder>(cancellationToken);
        return order ?? throw new InvalidOperationException(
            $"null body for order {orderId}");
    }
}
```

`FetchAllAsync` issues all requests concurrently via `Task.WhenAll` over a LINQ `.Select` projection
(reference section 8 and 11).
Serial `await` in a loop would lose the concurrency.

`CancellationToken` is the last parameter of every async method
and is threaded into `GetAsync` and `ReadFromJsonAsync` (reference section 8),
so a cancelled request stops promptly.
`OrderHttpAdapter` uses a primary constructor (C# 12+) to capture the injected `httpClient`
(reference section 6, shared/reference/architecture.md section 2).

## 4. CLI entry with config loading

This block demonstrates shared/reference/csharp.md section 12 (DataAnnotations validation)
and section 8 (async Main).

```csharp
using System.ComponentModel.DataAnnotations;
using System.Text.Json;

namespace Example.Orders;

/// <summary>Service configuration loaded from a JSON file.</summary>
public sealed class ServiceConfig
{
    [Required]
    [Url]
    public required string Endpoint { get; init; }

    [Range(1, int.MaxValue)]
    public required int TimeoutSeconds { get; init; }

    [Required]
    public required string LogLevel { get; init; }
}

public static class Program
{
    public static async Task<int> Main(string[] args)
    {
        var configPath = args.Length > 0 ? args[0] : "config.json";
        await using var stream = File.OpenRead(configPath);
        var config = await JsonSerializer.DeserializeAsync<ServiceConfig>(stream)
            ?? throw new InvalidOperationException("empty config file");

        Validator.ValidateObject(
            config, new ValidationContext(config), validateAllProperties: true);

        Console.WriteLine($"connected to {config.Endpoint}");
        return 0;
    }
}
```

`ServiceConfig` uses DataAnnotations attributes (`[Required]`, `[Url]`, `[Range]`)
for declarative validation (reference section 12).
The `required` modifier (C# 11+) forces every property to be set at construction,
so a partially-initialized config is a compile error.

`Validator.ValidateObject(..., validateAllProperties: true)` runs the annotations at the boundary;
`Main` returns `Task<int>` so the exit code reaches the shell.
`await using` disposes the file stream asynchronously (reference section 14).

## 5. Project structure

This block demonstrates shared/reference/csharp.md section 9 (project layout)
and section 4 (naming).

```
Example.Orders.sln
├── src/
│   └── Example.Orders/
│       ├── Example.Orders.csproj
│       ├── CustomerOrder.cs
│       ├── CustomerOrderNotFoundException.cs
│       ├── CustomerOrderRepository.cs
│       ├── OrderHttpAdapter.cs
│       ├── ServiceConfig.cs
│       └── Program.cs
├── tests/
│   └── Example.Orders.Tests/
│       ├── Example.Orders.Tests.csproj
│       └── CustomerOrderRepositoryTests.cs
├── Directory.Build.props
└── .editorconfig
```

Organized by domain namespace (reference section 9):

- One public type per file;
  the filename matches the type name.
- `Directory.Build.props` sets `<Nullable>enable</Nullable>`, `<LangVersion>`, and `<TreatWarningsAsErrors>`
  once for every project (reference section 7 and 13).
- `.editorconfig` drives `dotnet format` and the Roslyn analyzers (reference section 3).
- `tests/` mirrors `src/` with the `.Tests` suffix on the project name.

All type names and file names are `PascalCase`;
the interface for the store would be `ICustomerOrderStore` with the `I` prefix (reference section 4).

## Pitfalls

Common mistakes that the rules in `shared/reference/csharp.md` are designed to prevent.
Each is a real bug class that ships when the rule is forgotten.

- **Suppressing NRT warnings with `!`.**
  The null-forgiving operator asserts "this is not null" without proof;
  each use is a potential `NullReferenceException`.
  Fix the nullability instead of silencing it (reference section 7).
- **`async void` outside event handlers.**
  An `async void` method cannot be awaited,
  so exceptions escape to the synchronization context and crash the process.
  Return `Task` (reference section 8).
- **Blocking on async with `.Result` or `.Wait()`.**
  This blocks the calling thread and can deadlock in contexts with a synchronization context,
  or starve the thread pool in ASP.NET Core.
  Always `await` (reference section 8).
- **Forgetting `using` on `IDisposable`.**
  A leaked `HttpClient`, `SqlConnection`, or `FileStream` exhausts OS handles under load.
  Use `using` or `await using` declarations (reference section 14).
- **Not propagating `CancellationToken`.**
  Without it, a cancelled request keeps running server-side and cannot be drained on shutdown.
  Thread the token through every async call (reference section 8).
- **Mutable public fields instead of properties.**
  Exposing a public field breaks encapsulation and binary compatibility.
  Use properties (or `init`-only properties on records) (reference section 5).
- **Catching `Exception` broadly in mid-level code.**
  A broad catch hides bugs that should propagate;
  reserve it for top-level handlers (reference section 10, shared/reference/architecture.md section 5).
