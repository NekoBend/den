# TypeScript worked examples: layout and pitfalls

Example 5 and the Pitfalls of the TypeScript worked examples:
the project layout, and common mistakes the reference's rules prevent.

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
