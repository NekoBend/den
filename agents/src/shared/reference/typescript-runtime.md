# TypeScript reference: runtime

Sections 8, 12, and 14 of the TypeScript reference:
async hygiene, validation at boundaries, and DOM vs Node types.
shared/reference/typescript.md lists where every section lives.

## 8. Async hygiene

**Rule:** Inside `async` functions, only `await` Promises;
never block the event loop with synchronous I/O.
Replace blocking calls with their async counterparts:

- `await fs.promises.readFile` instead of `fs.readFileSync`.
- `await fetch(...)` or `await httpClient.get(...)` instead of synchronous HTTP libraries.
- `await timers/promises.setTimeout(ms)` instead of callback-based `setTimeout`
  where async/await fits.
- `Promise.all([...])` to await independent operations concurrently;
  `Promise.allSettled([...])` when partial failure is acceptable.
- Propagate cancellation via `AbortSignal`
  (passed through `fetch`, `setTimeout`, and Node APIs that accept it).

**Why:** A single blocking call on the event-loop thread
stalls every other Promise scheduled on the same loop.
Serial `await` on independent operations also loses the parallelism
the runtime would otherwise provide;
`Promise.all` is the idiomatic recovery.
**Example:**

```typescript
async function fetchAll(
  urls: ReadonlyArray<string>,
): Promise<ReadonlyArray<Response>> {
  return Promise.all(urls.map((url) => fetch(url)));
}
```

## 12. Validation at boundaries

**Rule:** Concentrate input validation at public API entry points
and external-data deserialization points.
Internal helpers trust their typed inputs.
Use:

- **Zod** for the default case (HTTP bodies, JSON files, environment config).
  Industry default with rich tRPC / Hono / Express integrations.
- **Valibot** when bundle size is critical (edge functions, browser).
  Roughly 90% smaller payload than Zod with a similar API.
- **ArkType** when validation throughput is critical
  (message-queue consumers, high-frequency request paths).
  3-4x faster than Zod.
- **User-defined type guards** at narrower boundaries
  where the input is genuinely `unknown` and a full schema is overkill.

Do not re-validate after the boundary;
downstream code reads the parsed object directly.
**Why:** See architecture.md section 9 (Validate at boundaries, trust internals).
TypeScript's type system is erased at runtime,
so the type checker alone cannot catch wrong-shape input.
A schema library fills that gap
and converts raw `unknown` into a typed object in one step.
**Example:**

```typescript
import { z } from "zod";

const CreateCustomerOrderRequestSchema = z.object({
  customerId: z.number().int().positive(),
  skuIds: z.array(z.string()).nonempty(),
});

type CreateCustomerOrderRequest = z.infer<typeof CreateCustomerOrderRequestSchema>;

function createCustomerOrderEndpoint(payload: unknown): Response {
  const request = CreateCustomerOrderRequestSchema.parse(payload); // boundary
  return handleCreate(request);                                     // trust the type
}

function handleCreate(request: CreateCustomerOrderRequest): Response {
  // No re-checking of request fields; they are typed.
  // ...
}
```

## 14. DOM vs Node types

**Rule:** Set `compilerOptions.lib` and install `@types/node`
according to where the code will run.
Mixing without intent surfaces APIs that do not exist at runtime.

- **Browser code:** `lib: ["ES2022", "DOM"]`.
  Do NOT install `@types/node`;
  `process`, `Buffer`, and `fs` should not be in scope.
- **Node.js code:** `lib: ["ES2022"]` and install `@types/node`.
  Do NOT include `"DOM"` in `lib` unless the same code also runs in a browser;
  otherwise `window`, `document`, and DOM-flavored variants of `fetch` pollute the API surface.
- **Isomorphic / universal code (runs in both):** `lib: ["ES2022", "DOM"]` plus `@types/node`.
  Inside the code, avoid environment-specific APIs without runtime detection
  (`typeof window !== "undefined"`).
- **Workers (Web Worker, Service Worker):** `lib: ["ES2022", "WebWorker"]`.
  `DOM` is not available inside workers.

**Why:** TypeScript loads only the types declared in `lib`;
the wrong combination either lets the code call APIs that do not exist at runtime
(calling `fs.readFileSync` in a browser bundle)
or hides APIs that do exist (`fetch` lived only in `DOM` before Node 18).
Splitting by environment surfaces accidental cross-runtime coupling at the type level.
**`fetch` compatibility:** `fetch` is part of the WHATWG specification
exposed via `lib.dom.d.ts`.
Node.js added `fetch` as a global in version 18;
either `"DOM"` in `lib` or `@types/node` v18+ provides the type.
