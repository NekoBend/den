# TypeScript worked examples

Worked examples demonstrating the rules in `shared/reference/typescript.md`.
The shared domain is a small order-management system;
each block is a fragment of that system illustrating two or three rules.
Cross-references in the prose point to the corresponding `shared/reference/typescript.md` section.

Code in these blocks contains only natural comments
(the kind a real developer writes for non-obvious WHY).
Instructional / meta comments belong in this prose, never in the code.

## Where each example lives

- examples/typescript-layout-pitfalls.md (Example 5 and the Pitfalls): read it after this file.
- examples/typescript-io.md (Examples 3 and 4): read it when the code is async,
  calls an HTTP service, is a command-line entry point, or loads a config file.

Compare your code against every file you read.

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
