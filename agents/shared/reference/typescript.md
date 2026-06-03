# TypeScript language reference

TypeScript-specific conventions for the `coding` skill.
Layered on top of `architecture.md` (12 generic rules).
When both apply, this file refines or specializes the generic rule.
Never contradict.

Apply with version awareness:
section 13 governs which constructs are admissible
based on the project's TypeScript version and target runtime.
Always read that section before proposing modern syntax.

## 1. Style guide: Google TypeScript Style Guide

**Rule:** Follow the Google TypeScript Style Guide as the baseline
(`google.github.io/styleguide/tsguide.html`).
It defines naming, file organization, imports, error handling,
and the `interface` vs `type` choice.
**Why:** The Google guide is comprehensive, maintained,
and aligns with the Google JavaScript Style Guide where they overlap.
This combination is the standard this skill applies;
teams with their own style guide override via project config (see section 3).

## 2. Doc comments: TSDoc, imperative summary

**Rule:** Every exported function, class, method, type, and module
gets a TSDoc comment.
Summary line is imperative
(`Parse the version...`, not `Parses the version...`) and ≤ 1 sentence.
Use `@param`, `@returns`, `@throws`, `@remarks`, `@example` sections
only when the signature alone is not self-evident.
Reference other entities with `{@link Name}`.
**Why:** TSDoc (`tsdoc.org`) is Microsoft's standardization of doc comments for TypeScript
and is consumed by TypeDoc, API Extractor, and IDE tooling.
JSDoc tags overlap and remain accepted;
TSDoc is the canonical TypeScript-aware grammar.
**Example:**

```typescript
/**
 * Persistence layer for customer orders.
 *
 * @remarks
 * Maintains an in-memory store; pass an existing map to seed.
 */
export class CustomerOrderRepository {
  /**
   * Return the customer order with `orderId`.
   *
   * @throws {@link CustomerOrderNotFoundError} If no row matches.
   */
  fetch(orderId: number): CustomerOrder {
    // ...
  }
}
```

## 3. Tooling: Biome (or ESLint + Prettier) + tsc

**Rule:** Default formatter and linter is `biome check --apply`
(single Rust binary).
Default type checker is `tsc --noEmit`;
the TypeScript compiler is the canonical type checker
and has no fast alternative analogous to Python's ty.
If `package.json` declares `eslint` and `prettier`,
defer to that toolchain on the existing codebase,
project config wins.
For greenfield projects, choose Biome
unless the project depends on framework-specific plugins
(`eslint-plugin-react-hooks`, `eslint-plugin-next`, `eslint-plugin-import`)
or type-aware lint rules that Biome has not yet shipped.
**Why:** Biome v2.3+ (`biomejs.dev`) covers ~80% of common ESLint rules at 25-56x ESLint's speed,
with production adoptions at Coinbase, Discord, Slack, Vercel, and Astro.
One binary replaces ESLint + Prettier + import-sort
with consistent formatting and 491 lint rules.
**Run order:** `biome check --apply` then `tsc --noEmit`.

## 4. Naming

**Rule:**

- Functions, methods, variables, parameters, properties: `camelCase`.
- Classes, interfaces, type aliases, enums, type parameters: `PascalCase`.
  Do NOT prefix interfaces with `I`.
- Module-level constants (immutable primitives or `as const` literals): `UPPER_SNAKE`.
- Private class fields: ES2022 `#privateField` (true privacy enforced by the runtime).
  The `private` keyword is type-checker only.
- Do NOT use leading or trailing underscores for private members,
  and do NOT use `opt_` prefix for optional parameters.

**Why:** The Google TS Style Guide rejects Hungarian-style decoration
(`IFoo`, `_private`, `opt_arg`):
TypeScript already encodes the information in the type system,
so naming conventions should not duplicate it.
ES2022 `#private` is enforced at runtime and survives minification,
unlike the `private` keyword.
**Example:**

```typescript
const MAX_RETRIES = 5;

interface CustomerOrder { /* ... */ }

class CustomerOrderRepository {
  #store: Map<number, CustomerOrder>;
}

function fetchCustomerOrder(orderId: number): CustomerOrder { /* ... */ }
```

## 5. Type annotations: `interface`, `type`, `readonly`

**Rule:**

- Use `interface` for object shapes that may be extended or implemented by a class.
- Use `type` for unions, intersections, mapped types, or computed types
  where `interface` cannot express the shape.
- Annotate the return type of every exported function and method.
  Local inference is fine; exported boundaries are not.
- Use `readonly` arrays (`ReadonlyArray<T>` or `readonly T[]`)
  and `Readonly<T>` for parameters that must not be mutated.

**Why:** `interface` is open (declaration merging works)
and is the Google-recommended default for object shapes;
`type` is closed and expresses set-theoretic operations the interface form cannot.
The `readonly` qualifier makes immutability intent explicit at the type level,
mirroring `architecture.md` section 3.
**See `architecture.md` section 6** for the generic rule
about preferring `unknown` over `any` for escape hatches.
**Example:**

```typescript
interface CustomerOrder {
  readonly id: number;
  readonly customerId: number;
  readonly totalCents: number;
  readonly skuIds: ReadonlyArray<string>;
}

type OrderStatus = "pending" | "shipped" | "delivered";
```

## 6. Modern syntax minimums

**Rule:** Use the highest-version form admissible by the project's TypeScript version
and ECMAScript `target` (see section 13).
Common version-gated upgrades:

| Version | Modern form | Legacy form to avoid |
|---|---|---|
| ES2020 | optional chaining `a?.b?.c` | nested `a && a.b && a.b.c` |
| ES2020 | nullish coalescing `a ?? b` | `a !== null && a !== undefined ? a : b` |
| ES2022 | `#privateField` | `private` keyword (type-only) |
| ES2022 | `Array.prototype.at(-1)` | `arr[arr.length - 1]` |
| TS 4.1 | template literal types | string-based key derivation |
| TS 4.9 | `satisfies T` | `as T` cast for literal-typed values |
| TS 5.0 | const type parameters `<const T>` | reassertion patterns to preserve literal types |

**Why:** Each new form removes ceremony or unsafe casts.
`satisfies` preserves narrow literal inference where `as` widens it,
catching errors the cast would have silenced.
**Defer to section 13** before applying.
Both the TypeScript version in `package.json`
and the ECMAScript `target` in `tsconfig.json` constrain what is admissible.

## 7. Discriminated union exhaustiveness

**Rule:** Model finite alternatives with a discriminated union
(a literal `kind` or `type` field).
Check exhaustiveness with a `never`-typed assignment in the `switch` default;
the compiler will flag any missing case at compile time.
**Why:** Plain string-keyed switches let unhandled cases slip through silently.
The `never` check makes adding a new union member a compile-time error
in every `switch` that previously covered all cases.
This is the TypeScript counterpart to Python's domain-exception discipline:
it surfaces incomplete handling before the code ships.
**Example:**

```typescript
type OrderEvent =
  | { kind: "placed"; orderId: number }
  | { kind: "shipped"; orderId: number; trackingId: string }
  | { kind: "delivered"; orderId: number; deliveredAt: Date };

function describe(event: OrderEvent): string {
  switch (event.kind) {
    case "placed":
      return `Order ${event.orderId} placed.`;
    case "shipped":
      return `Order ${event.orderId} shipped via ${event.trackingId}.`;
    case "delivered":
      return `Order ${event.orderId} delivered at ${event.deliveredAt.toISOString()}.`;
    default: {
      const unreachable: never = event;
      throw new Error(`unhandled OrderEvent: ${JSON.stringify(unreachable)}`);
    }
  }
}
```

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

## 13. Version awareness

**Rule:** Before proposing any version-gated form (sections 5, 6, 8, 10),
read the project's tsconfig settings and TypeScript version:

- `tsconfig.json` `compilerOptions.target`: the ECMAScript output the compiler emits.
- `tsconfig.json` `compilerOptions.lib`: the runtime types in scope
  (`ES2022`, `DOM`, `WebWorker`; see section 14).
- `tsconfig.json` `compilerOptions.moduleResolution`: `"bundler"` for Vite / Next.js / webpack / esbuild,
  `"nodenext"` for Node.js without a bundler.
- `tsconfig.json` `compilerOptions.strict`: must be `true`.
- `package.json` `devDependencies.typescript`: the TypeScript compiler version itself.

If `target` is `"ES2020"`,
do not propose ES2022 features (`#privateField`, `Array.prototype.at`, `Error cause`).
If `devDependencies.typescript` is older than 4.9,
do not propose `satisfies`.
**Why:** TypeScript transpiles to the `target`,
but features that require runtime support (`Error.cause`, private fields, weak refs)
cannot be emulated for older targets.
Mismatched syntax breaks for the project's declared runtime.
**`strict: true` is mandatory:** every published 2026 guide, including Google's,
treats non-strict TypeScript as legacy.
Strict mode enables `noImplicitAny`, `strictNullChecks`, `strictFunctionTypes`,
and the other safety nets the language is designed around.
**When declarations are absent:** ask the user before proposing modern syntax;
do not silently assume the latest version.

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
