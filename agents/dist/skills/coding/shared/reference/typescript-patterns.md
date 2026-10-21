# TypeScript reference: patterns

Sections 9, 10, and 11 of the TypeScript reference:
module structure, domain errors, and idiomatic patterns.
shared/reference/typescript.md lists where every section lives.

## 9. Module structure

**Rule:** Split a module when it crosses any of these thresholds:

- ≥ 3 top-level classes or interfaces, or
- ≥ 200 lines of executable code, or
- mixes I/O (network, disk, DB) and pure logic in the same file.

Typical split: `models.ts` (interfaces, types), `core.ts` (business logic),
`utils.ts` (pure helpers), `adapters.ts` (I/O).
Mark public entities with `export`;
everything else stays module-local.
Use `import type { Foo } from "./models"` for type-only imports.
**Why:** Smaller, intention-named files diff more cleanly,
are easier to hold in working memory,
and discourage hidden cross-coupling.
`import type` keeps type symbols out of the runtime bundle
and lets the bundler tree-shake aggressively;
a plain `import` of a type can prevent dead-code elimination in some bundlers.
**Barrel files (`index.ts` re-exports):** acceptable at the package entry,
risky inside the package because they can produce circular imports
and inflate per-import bundle size.
Prefer importing from the concrete module path inside the package.
**When over:** Identify the densest dependency edge
(e.g., "everything imports `db.client`") and extract that subsystem first.

## 10. Domain errors

**Rule:** Define a domain-specific error class by extending `Error`.
Set `this.name` explicitly
so the class is identifiable in stack traces and structured logs.
Pass `cause` (ES2022) via the second constructor argument
to preserve the underlying error when re-raising at a boundary.

**Why:** Subclassing `Error` lets callers narrow with `instanceof CustomerOrderNotFoundError`,
replacing brittle string matching on `.message`.
The `name` property is what `console.error` and most loggers display first,
so setting it makes the class self-identifying.
`cause` chaining preserves the original failure for debugging
without losing the domain-level context.
**Cross-ref:** architecture.md section 5 (catch narrow, propagate broad)
covers the generic rule.
This section adds the TypeScript-specific shape.
**Example:**

```typescript
class CustomerOrderNotFoundError extends Error {
  constructor(orderId: number, options?: ErrorOptions) {
    super(`customer order ${orderId} not found`, options);
    this.name = "CustomerOrderNotFoundError";
  }
}

async function fetchCustomerOrder(orderId: number): Promise<CustomerOrder> {
  try {
    return await repository.fetch(orderId);
  } catch (err) {
    if (err instanceof KeyNotFoundError) {
      throw new CustomerOrderNotFoundError(orderId, { cause: err });
    }
    throw err;
  }
}
```

## 11. Idiomatic patterns

**Rule:** Prefer language-native idioms over manual equivalents
when the idiom is well-known to TypeScript readers:

- **Optional chaining (`a?.b?.c`)** and **nullish coalescing (`a ?? b`)**
  for safe navigation through nullable references.
- **Destructuring** for arrays (`const [first, ...rest] = arr`)
  and objects (`const { id, customerId } = order`)
  instead of repeated index or key access.
- **Spread (`...`)** for shallow copies and variable-arity functions:
  `const next = { ...prev, status: "shipped" }`.
- **Array methods** (`map`, `filter`, `reduce`, `flatMap`, `find`, `some`, `every`)
  over imperative `for` loops when the operation is transformational.
- **`for...of`** for iteration
  when you need `await` inside the body or early `break`/`return`.
- **Template literals** for interpolation;
  reserve string concatenation for the simplest two-string joins.

**Why:** See architecture.md section 12 (Idiomatic over portable).
TypeScript's idioms compress common operations
and let the type system narrow more aggressively;
destructuring in particular preserves narrowed property types better than repeated indexing.
**Example:**

```typescript
const placedOrderIds = orders
  .filter((order) => order.status === "placed")
  .map((order) => order.id);

const { id, customerId, ...rest } = order;
const summary = `Order ${id} for customer ${customerId}`;
```
