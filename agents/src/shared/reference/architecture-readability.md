# Architecture defaults: readability

Sections 7, 8, and 10 of the architecture defaults:
documentation, function size, and comments.
shared/reference/architecture.md lists where every section lives.

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
(loop counters `i`/`j`/`k` and language-idiomatic short names, such as `self` in Rust and Python, are exempt).
**Why:** Defect density spikes with size, depth, and branching count.
**When over:** Extract the deepest branch into a named helper function.

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
