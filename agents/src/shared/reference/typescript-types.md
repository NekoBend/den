# TypeScript reference: types and versions

Sections 5, 6, 7, and 13 of the TypeScript reference:
annotations, modern syntax, discriminated union exhaustiveness, and version awareness.
shared/reference/typescript.md lists where every section lives.

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
