# TypeScript language reference

TypeScript-specific conventions for the `coding` skill.
Layered on top of `architecture.md` (12 generic rules).
When both apply, this file refines or specializes the generic rule.
Never contradict.

Apply with version awareness:
section 13 governs which constructs are admissible
based on the project's TypeScript version and target runtime.
Always read that section before proposing modern syntax.

## Where each section lives

This file holds sections 1, 2, 3, and 4.

- shared/reference/typescript-types.md (sections 5, 6, 7, and 13): read it now as well.
- shared/reference/typescript-patterns.md (sections 9, 10, and 11): read it now as well.
- shared/reference/typescript-runtime.md (sections 8, 12, and 14): read it when the code is async,
  makes an HTTP request or another network call, or waits on a timer;
  when it takes in data from outside the program
  (an HTTP request or response body, a JSON or config file, environment variables,
  command-line arguments, a queue message) or handles a value typed `unknown` or `any`;
  when it calls an API that exists only in a browser, only in Node.js, or only in a worker
  (`window`, `document`, `process`, `Buffer`, `fs`);
  or when the task creates or changes `tsconfig.json` or `package.json`.

"section N" in any of these files means the section with that number;
this list names the file that holds it.

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
