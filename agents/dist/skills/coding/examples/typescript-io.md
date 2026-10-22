# TypeScript worked examples: I/O

Examples 3 and 4 of the TypeScript worked examples:
fetching customer orders concurrently over HTTP,
and a command-line entry point that loads a JSON config.

## 3. Async fetching

This block demonstrates shared/reference/typescript-runtime.md section 8 (async hygiene: Promise.all, no blocking I/O)
and typescript-patterns.md section 11 (idiomatic patterns: destructuring, array methods).

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
serial `await` in a loop would lose the parallelism the runtime provides (typescript-runtime.md section 8).

`OrderResponseSchema` validates the external API response at the boundary (typescript-runtime.md section 12),
preventing wrong-shape data from propagating into typed `CustomerOrder` instances.

The `satisfies CustomerOrder` operator (TS 4.9+, typescript-types.md section 6)
type-checks the object literal against `CustomerOrder` while preserving the precise inferred type.
Unlike `as CustomerOrder`, it catches missing or mistyped properties at compile time.

## 4. CLI entry with config loading

This block demonstrates shared/reference/typescript-types.md section 13 (version awareness: tsconfig settings)
and typescript-runtime.md section 14 (DOM vs Node types).

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
and should NOT include `"DOM"` in `tsconfig.json` `lib` (typescript-runtime.md section 14).

`parseArgs` (Node 18.3+) is the built-in argument parser;
it replaces external packages like `commander` or `yargs` for simple CLIs.

`ServiceConfigSchema` validates the JSON file at the boundary (typescript-runtime.md section 12).
The schema uses `z.url()`, `.int()`, `.positive()`, and `z.enum()`
for semantic constraints beyond what the type system alone can express.
