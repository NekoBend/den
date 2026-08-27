# TypeScript worked examples

Worked examples demonstrating the rules in `shared/reference/typescript.md`.
The shared domain is a small order-management system;
each block is a fragment of that system illustrating two or three rules.
Cross-references in the prose point to the corresponding `shared/reference/typescript.md` section.

Code in these blocks contains only natural comments
(the kind a real developer writes for non-obvious WHY).
Instructional / meta comments belong in this prose, never in the code.

## 1. Domain types and errors

This block demonstrates shared/reference/typescript.md section 5 (interface, type, readonly),
section 7 (discriminated union exhaustiveness), and section 10 (domain errors).

```typescript
export interface CustomerOrder {
  readonly id: number;
  readonly customerId: number;
  readonly totalCents: number;
  readonly skuIds: ReadonlyArray<string>;
}

export type OrderStatus = "pending" | "shipped" | "delivered";

export type OrderEvent =
  | { kind: "placed"; orderId: number }
  | { kind: "shipped"; orderId: number; trackingId: string }
  | { kind: "delivered"; orderId: number; deliveredAt: Date };

export class CustomerOrderNotFoundError extends Error {
  constructor(
    public readonly orderId: number,
    options?: ErrorOptions,
  ) {
    super(`customer order ${orderId} not found`, options);
    this.name = "CustomerOrderNotFoundError";
  }
}

export class InsufficientStockError extends Error {
  constructor(
    public readonly sku: string,
    options?: ErrorOptions,
  ) {
    super(`insufficient stock for SKU ${sku}`, options);
    this.name = "InsufficientStockError";
  }
}
```

`CustomerOrder` is an `interface`
because it describes an object shape that may be extended or implemented (reference section 5).
`OrderStatus` is a `type` alias
because it is a union of literals that `interface` cannot express.
All properties are `readonly`,
mirroring `shared/reference/architecture.md` section 3 (immutability).

`CustomerOrderNotFoundError` extends `Error` with an explicit `name` assignment
so stack traces identify the class (reference section 10).
The `options?: ErrorOptions` parameter supports ES2022 `cause` chaining
for preserving the underlying error when re-raising at a boundary.

## 2. Persistence with validation

This block demonstrates shared/reference/typescript.md section 2 (TSDoc),
section 12 (validation at boundaries with Zod), and section 9 (import type).

```typescript
import type { CustomerOrder } from "./models";
import { CustomerOrderNotFoundError } from "./models";
import { z } from "zod";

const CreateCustomerOrderRequestSchema = z.object({
  customerId: z.number().int().positive(),
  skuIds: z.array(z.string()).nonempty(),
});

type CreateCustomerOrderRequest = z.infer<typeof CreateCustomerOrderRequestSchema>;

/**
 * In-memory persistence for customer orders.
 *
 * @remarks
 * Pass an existing map to seed; the constructor copies it defensively.
 */
export class CustomerOrderRepository {
  readonly #store: Map<number, CustomerOrder>;

  constructor(initial?: ReadonlyMap<number, CustomerOrder>) {
    // Defensive copy: the caller's map must not alias the store.
    this.#store = new Map(initial);
  }

  /**
   * Create a customer order from a validated request.
   *
   * @throws {z.ZodError} If `payload` has the wrong shape.
   */
  createFromPayload(payload: unknown): CustomerOrder {
    const request = CreateCustomerOrderRequestSchema.parse(payload);
    const id = Math.max(0, ...this.#store.keys()) + 1;
    const order: CustomerOrder = {
      id,
      customerId: request.customerId,
      totalCents: 0,
      skuIds: request.skuIds,
    };
    this.#store.set(id, order);
    return order;
  }

  /**
   * Return the customer order with `orderId`.
   *
   * @throws {CustomerOrderNotFoundError} If no entry matches.
   */
  fetch(orderId: number): CustomerOrder {
    const order = this.#store.get(orderId);
    if (order === undefined) {
      throw new CustomerOrderNotFoundError(orderId);
    }
    return order;
  }
}
```

`import type { CustomerOrder }` keeps the type symbol out of the runtime bundle
(reference section 9).
The value import `CustomerOrderNotFoundError` remains a regular `import`
because it is used at runtime.

`CreateCustomerOrderRequestSchema` validates raw `unknown` input at the boundary;
downstream code receives a typed `CreateCustomerOrderRequest` and trusts the fields
(reference section 12).
The `Schema` suffix separates the runtime validator from the inferred `type`.

The `#store` field uses ES2022 private class fields (reference section 4, section 6).
The constructor copies `initial` defensively
so the caller cannot mutate the internal map.

## 3. Async fetching

This block demonstrates shared/reference/typescript.md section 8 (async hygiene: Promise.all, no blocking I/O)
and section 11 (idiomatic patterns: destructuring, array methods).

```typescript
import type { CustomerOrder } from "./models";
import { CustomerOrderNotFoundError } from "./models";
import { z } from "zod";

const OrderResponseSchema = z.object({
  id: z.number(),
  customerId: z.number(),
  totalCents: z.number(),
  skuIds: z.array(z.string()),
});

export async function fetchCustomerOrders(
  baseUrl: string,
  orderIds: ReadonlyArray<number>,
): Promise<ReadonlyArray<CustomerOrder>> {
  const responses = await Promise.all(
    orderIds.map((oid) => fetch(`${baseUrl}/orders/${oid}`)),
  );

  return Promise.all(
    responses.map(async (res, i) => {
      if (res.status === 404) {
        throw new CustomerOrderNotFoundError(orderIds[i]);
      }
      if (!res.ok) {
        throw new Error(`HTTP ${res.status} for order ${orderIds[i]}`);
      }
      const payload = OrderResponseSchema.parse(await res.json());
      return {
        id: payload.id,
        customerId: payload.customerId,
        totalCents: payload.totalCents,
        skuIds: payload.skuIds,
      } satisfies CustomerOrder;
    }),
  );
}
```

`Promise.all` issues all fetch requests concurrently;
serial `await` in a loop would lose the parallelism the runtime provides (reference section 8).

`OrderResponseSchema` validates the external API response at the boundary (reference section 12),
preventing wrong-shape data from propagating into typed `CustomerOrder` instances.

The `satisfies CustomerOrder` operator (TS 4.9+, reference section 6)
type-checks the object literal against `CustomerOrder` while preserving the precise inferred type.
Unlike `as CustomerOrder`, it catches missing or mistyped properties at compile time.

## 4. CLI entry with config loading

This block demonstrates shared/reference/typescript.md section 13 (version awareness: tsconfig settings)
and section 14 (DOM vs Node types).

```typescript
import { readFileSync } from "node:fs";
import { parseArgs } from "node:util";
import { z } from "zod";

const ServiceConfigSchema = z.object({
  endpoint: z.url(),
  timeoutSeconds: z.number().int().positive(),
  logLevel: z.enum(["debug", "info", "warning", "error"]),
});

type ServiceConfig = z.infer<typeof ServiceConfigSchema>;

function loadConfig(path: string): ServiceConfig {
  const raw = readFileSync(path, "utf-8");
  return ServiceConfigSchema.parse(JSON.parse(raw));
}

function main(): void {
  const { values } = parseArgs({
    options: {
      config: { type: "string", default: "config.json" },
    },
  });
  const config = loadConfig(values.config ?? "config.json");
  console.log(`connected to ${config.endpoint}`);
}

main();
```

`node:fs` and `node:util` use the `node:` protocol prefix (Node 16+),
which makes it explicit that these are Node.js built-in modules, not npm packages with the same name.
This code requires `@types/node`
and should NOT include `"DOM"` in `tsconfig.json` `lib` (reference section 14).

`parseArgs` (Node 18.3+) is the built-in argument parser;
it replaces external packages like `commander` or `yargs` for simple CLIs.

`ServiceConfigSchema` validates the JSON file at the boundary (reference section 12).
The schema uses `z.url()`, `.int()`, `.positive()`, and `z.enum()`
for semantic constraints beyond what the type system alone can express.

## 5. Project layout

This block demonstrates shared/reference/typescript.md section 4 (naming)
and section 9 (module structure).

```
orders/
├── src/
│   ├── models.ts
│   ├── repository.ts
│   ├── adapters.ts
│   ├── cli.ts
│   └── index.ts
├── tests/
│   ├── repository.test.ts
│   ├── adapters.test.ts
│   └── cli.test.ts
├── tsconfig.json
├── package.json
└── biome.json (or .eslintrc + .prettierrc)
```

Each module holds one concern (reference section 9):

- `models.ts` carries interfaces, type aliases, and error classes; no I/O.
  Holds Example 1's `CustomerOrder`, `OrderEvent`, `CustomerOrderNotFoundError`, `InsufficientStockError`.
- `repository.ts` carries business logic and persistence orchestration.
  Holds Example 2's `CustomerOrderRepository` and `CreateCustomerOrderRequestSchema`.
- `adapters.ts` carries side-effectful I/O (HTTP fetch).
  Holds Example 3's `fetchCustomerOrders`.
- `cli.ts` is the user-facing entry surface: argument parsing, config loading, dispatch.
  Holds Example 4's `ServiceConfig` and `main`.
- `index.ts` re-exports the public API for package consumers.
  Internal modules import from concrete paths (`./models`), not from `./index`
  (reference section 9, barrel file guidance).

`tests/` mirrors the source layout with the `.test.ts` suffix expected by Vitest or Jest.

All filenames are `camelCase` or `kebab-case`;
all type names are `PascalCase`;
no interface has an `I` prefix (reference section 4).

## Pitfalls

Common mistakes that the rules in `shared/reference/typescript.md` are designed to prevent.
Each is a real bug class that ships when the rule is forgotten.

- **Using `any` instead of `unknown` for untyped data.**
  `any` disables all type checking on the value and every value derived from it.
  Use `unknown` and narrow with a type guard or Zod schema
  (reference section 5, shared/reference/architecture.md section 6).
- **Forgetting `import type` for type-only imports.**
  A regular `import` of a type can prevent tree-shaking in some bundlers,
  inflating the runtime bundle (reference section 9).
- **Using `as T` where `satisfies T` is sufficient.**
  `as` silences the compiler by asserting the type;
  `satisfies` validates the type without widening the inferred result.
  The former hides bugs, the latter catches them (reference section 6).
- **Mixing `interface` and `type` inconsistently.**
  Use `interface` for object shapes, `type` for unions and intersections.
  Picking arbitrarily makes the codebase harder to navigate
  and prevents declaration merging where it would be useful (reference section 5).
- **Not propagating `AbortSignal` through fetch calls.**
  Without a signal, cancelled requests continue running in the background
  and their responses are silently discarded,
  wasting bandwidth and potentially causing stale-data bugs (reference section 8).
- **Barrel file (`index.ts`) re-exports inside the package.**
  Internal modules importing from `./index` instead of the concrete path
  create circular dependency risks and inflate per-import bundle size (reference section 9).
- **Non-strict `tsconfig.json`.**
  Running without `strict: true` in 2026 disables `noImplicitAny`, `strictNullChecks`, and `strictFunctionTypes`,
  letting entire categories of bugs through unchecked (reference section 13).
