# Architecture defaults

Language-agnostic principles applied during every implementation in this skill.
The per-language reference may extend or refine these;
never contradict them.

## 1. Single Responsibility (SRP)

**Rule:** One function does one job.
If its name needs "and" to describe it,
split it into two.
**Why:** Reduces the blast radius of future changes;
each function gets one reason to be modified.
**Example:**

```python
def fetch_user(user_id: int) -> User: ...
def send_welcome_email(user: User) -> None: ...
# Caller composes:
send_welcome_email(fetch_user(uid))
```

## 2. Dependency Injection

**Rule:** Pass stateful, networked, or environment-coupled dependencies in
via constructor or function parameters.
Hardcoded imports are fine for pure utilities and stdlib.
**Why:** Makes the code testable (swap real for fake)
and explicit about what it depends on.
**Example:**

```python
class OrderService:
    def __init__(self, repository: OrderRepository) -> None:
        self.repository = repository  # injected; tests pass a fake repo
```

## 3. Immutability where the language supports it cheaply

**Rule:** Default to immutable types
when the language offers them at zero or near-zero cost.
Mutability is a deliberate choice,
not the default.
**Why:** Removes a class of bugs
where shared state is mutated unexpectedly across call sites.
**Example:**

```python
from dataclasses import dataclass

@dataclass(frozen=True)
class Money:
    amount: int
    currency: str
```

See per-language reference for the equivalent idiom in your target language.

## 4. Pure functions for transformation; I/O at the edges

**Rule:** Separate the logic that transforms data from the logic that performs I/O.
Pure functions get unit tests;
I/O gets integration tests or fakes.
**Why:** Pure code is easy to verify and to refactor;
mixing the two makes both halves hard to test.
**Example:**

```python
def normalize_user(raw: dict) -> User:
    return User(id=int(raw["id"]), name=raw["name"].strip())  # pure

def load_user(repo: UserRepository, user_id: int) -> User:
    return normalize_user(repo.fetch(user_id))  # I/O at the edge
```

## 5. Exception handling: catch narrow, propagate broad

**Rule:** Catch the narrowest exception type you can handle.
Reserve broad catches for top-level entry points
(request handlers, CLI main, message consumers).
Define domain-specific exception types for business errors.
**Why:** Broad catches hide bugs that should propagate;
narrow catches document intent.
**Example:**

```python
class OrderNotFoundError(LookupError):
    """Raised when an order ID does not resolve."""

def get_order(order_id: int) -> Order:
    try:
        return repo.fetch(order_id)
    except KeyError as exc:
        raise OrderNotFoundError(f"order {order_id} not found") from exc
```

## 6. Type safety: explicit types over escape hatches

**Rule:** Model unknowns explicitly with `unknown`, generics, or tagged unions.
Do not reach for `any` / `Any` / `object` / `interface{}`
to silence the type checker.
**Why:** Escape hatches push failures to runtime
where they are more expensive than at the type-check stage.
**Example:**

```typescript
function processPayload(data: unknown): Result {
  if (!isUserPayload(data)) {
    throw new TypeError("expected a UserPayload");
  }
  // `data` is now narrowed to UserPayload
  return { userId: data.id, displayName: data.name };
}
```

## 7. Document every public API

**Rule:** Every public function, class, method, type, and module
gets at least a one-line doc comment.
Add structured sections (`Args` / `Returns` / `Raises`, or the language equivalent)
when behavior is not obvious from the signature.
**Why:** The reader does not always have the implementation visible.
The doc is what callers see.
**Example:**

```python
def parse_version(raw: str) -> SemanticVersion:
    """Parse a `major.minor.patch` version string.

    Raises:
        VersionFormatError: If `raw` is not three dot-separated non-
            negative integers.
    """
```

Do not restate types in the doc when annotations already carry them.
Do not write "returns user" next to `def get_user`.

## 8. Function size and nesting limits

**Rule:** ≤ 50 lines of executable code per function.
≤ 3 levels of nesting.
Cyclomatic complexity ≤ 10.
Identifiers are full words of ≥ 3 characters
(loop counters `i`/`j`/`k` and language-idiomatic short names like Go method receivers are exempt).
**Why:** Defect density spikes with size, depth, and branching count.
**When over:** Extract the deepest branch into a named helper function.

## 9. Validate at boundaries, trust internals

**Rule:** Validate inputs at public API entry points
and at external-data deserialization points.
Do not re-validate between trusted internal helpers.
**Why:** Validation has a cost.
Concentrating it at boundaries lets internal layers assume well-formed data.
**Example:**

```python
def public_endpoint(payload: dict) -> Response:
    request = parse_request(payload)  # validation lives here
    return _handle(request)           # trust the type

def _handle(request: Request) -> Response:
    # No defensive re-check of request fields; they are typed.
    ...
```

## 10. Comments explain *why*, not *what*

**Rule:** A comment that restates the code is noise.
A comment that captures a constraint, a workaround, a business rule, or a non-obvious invariant
is useful.
**Why:** Code shows what;
the reader cannot infer why from the code alone.
**Example:**

```python
# Skip the trailing newline; see RFC 822 §2.1.
i = i + 1
```

## 11. No hardcoded paths, secrets, URLs, or timeouts

**Rule:** Anything that varies between environments
belongs in an environment variable, config file,
or a top-of-module constant with a comment justifying the value.
**Why:** Hardcoded values make the code unrunnable in non-default environments
and hide the meaning of magic numbers.
**Example:**

```python
API_BASE = os.environ["API_BASE"]
# 99th-percentile observed latency is 12 s; 30 s leaves headroom.
REQUEST_TIMEOUT_SECONDS = 30

response = httpx.get(f"{API_BASE}/v1/users", timeout=REQUEST_TIMEOUT_SECONDS)
```

## 12. Idiomatic over portable

**Rule:** Use the target language's native constructs.
Don't port another language's patterns
when the host language has a native idiom.
**Why:** Idiomatic code is easier for the next reader
and avoids subtle bugs from emulation.
**Common idioms by language:** see per-language reference.
A few examples: Python comprehensions instead of manual loops;
Go `defer` for cleanup;
Rust `?` for error propagation;
TypeScript `async`/`await` instead of callbacks.
