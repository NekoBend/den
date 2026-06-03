# Example: reference mode

A worked API reference written from the code, documenting actual behavior
(including what the function does NOT do). This is the shape the reference mode
of SKILL.md should produce. Adapt the shape, do not copy the wording.

## Input from the user

> Document this function:
>
> ```python
> def parse_retry_after(header, *, default=1.0, cap=60.0):
>     if not header:
>         return default
>     header = header.strip()
>     if header.isdigit():
>         seconds = float(header)
>     else:
>         try:
>             when = parsedate_to_datetime(header)
>         except (TypeError, ValueError):
>             return default
>         seconds = (when - datetime.now(timezone.utc)).total_seconds()
>     return max(0.0, min(seconds, cap))
> ```

## Worked output

## parse_retry_after
Parse an HTTP Retry-After header into a delay in seconds.

**Parameters:** header (str or None) - the Retry-After value, either a count of
seconds or an HTTP date; None or empty yields default. default (float,
keyword-only) - returned when header is missing or unparseable (1.0). cap
(float, keyword-only) - upper bound on the returned delay (60.0).
**Returns:** float - the delay in seconds, clamped to the range 0.0 to cap.
**Raises:** none - parse failures fall back to default instead of raising.

**Example:**
```python
parse_retry_after("5")     # 5.0
parse_retry_after("bad")   # 1.0  (unparseable, falls back to default)
parse_retry_after(None)    # 1.0
```

**Could not determine:** none.

## Why this is correct

- The entry was written after reading the body, not from the name (Step R1).
  The name alone would not reveal the clamping or the error handling.
- It documents what the code actually does: it clamps the result to
  [0.0, cap] (the max/min line), and it does NOT raise on a bad header,
  returning default instead (the try/except). Stating "Raises: none" is a
  fact read from the code, not an assumption (Faithfulness rule, Step R2).
- The example is runnable and shows the fallback path, the behavior most
  likely to surprise a caller (Step R3).
- If, say, parsedate_to_datetime were imported from an unclear module, that
  would go under "Could not determine" rather than being guessed (Step R4).
