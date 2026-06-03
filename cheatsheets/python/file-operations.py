"""File I/O Operations — Copy-Paste Cheatsheet.

Practical patterns for reading, writing, splitting, merging, and inspecting files.

Quick-Reference Decision Table
==============================

| Pattern              | Best For                          | Module         | Notes                          |
|----------------------|-----------------------------------|----------------|--------------------------------|
| read_text            | Small text files (< ~100 MB)      | pathlib        | Loads entire file into memory  |
| read_lines           | Line-by-line list processing      | pathlib        | Strips newlines automatically  |
| read_lines_lazy      | Huge files, streaming             | builtins       | Generator, constant memory     |
| write_text           | Create / overwrite a text file    | pathlib        | Creates parents automatically  |
| write_lines          | Dump an iterable of strings       | pathlib        | Adds newlines for you          |
| append_text          | Add content to existing file      | builtins       | Opens in append mode           |
| read_binary          | Images, archives, binary blobs    | pathlib        | Returns raw bytes              |
| write_binary         | Save binary content to disk       | pathlib        | Creates parents automatically  |
| seek_and_read        | Random access within a file       | builtins       | seek/tell for byte offsets     |
| split_by_size        | Chunk a large file by byte size   | builtins       | Binary-safe splitting          |
| split_by_lines       | Chunk a text file by line count   | builtins       | Streaming, constant memory     |
| merge_files          | Concatenate files into one        | pathlib/shutil | Binary-safe merging            |
| read_csv             | Quick CSV to list[dict]           | csv            | DictReader for named access    |
| write_csv            | Dump rows to CSV                  | csv            | DictWriter with header row     |
| read_json            | Load a JSON file                  | json           | Returns dict or list           |
| write_json           | Dump data to JSON                 | json           | Pretty-printed, UTF-8 safe     |
| atomic_write         | Crash-safe file replacement       | tempfile+os    | Write to temp, then rename     |
| file_metadata        | Size, mtime, exists checks        | pathlib        | No extra imports needed        |

Usage:
    1. Copy the function you need into your project.
    2. Adjust parameters (encoding, chunk size, etc.) to fit your workload.
    3. All path arguments accept ``pathlib.Path`` or ``str``.

Dependencies:
    stdlib only — no external packages required.
"""

from __future__ import annotations

from collections.abc import Generator
from pathlib import Path

# =============================================================================
# 1. Read — Text
# =============================================================================


def read_text(path: Path, encoding: str = "utf-8") -> str:
    """Read an entire text file into a single string.

    [Best for] Small-to-medium files that fit comfortably in memory.
    [Note] Raises ``FileNotFoundError`` if the path does not exist.
    """
    return Path(path).read_text(encoding=encoding)


def read_lines(path: Path, encoding: str = "utf-8") -> list[str]:
    """Read a text file and return a list of stripped lines.

    [Best for] Config files, line-oriented data, small logs.
    [Note] Empty lines are preserved; only trailing newlines are stripped.
    """
    return Path(path).read_text(encoding=encoding).splitlines()


def read_lines_lazy(path: Path, encoding: str = "utf-8") -> Generator[str, None, None]:
    """Yield lines one at a time without loading the whole file.

    [Best for] Multi-GB log files, streaming ETL pipelines.
    [Note] Returns a generator — wrap in ``list()`` if you need random access.
    """

    def _iter() -> Generator[str, None, None]:
        with open(path, encoding=encoding) as fh:
            for line in fh:
                yield line.rstrip("\n")

    return _iter()


# =============================================================================
# 2. Write — Text
# =============================================================================


def write_text(path: Path, content: str, encoding: str = "utf-8") -> None:
    """Write a string to a file, creating parent directories if needed.

    [Best for] Saving generated text, configs, reports.
    [Note] Overwrites the file if it already exists.
    """
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content, encoding=encoding)


def write_lines(path: Path, lines: list[str], encoding: str = "utf-8") -> None:
    """Write an iterable of strings as newline-separated lines.

    [Best for] Dumping lists, processed log lines, filtered data.
    [Note] A trailing newline is added after the last line.
    """
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("\n".join(lines) + "\n", encoding=encoding)


def append_text(path: Path, content: str, encoding: str = "utf-8") -> None:
    """Append text to an existing file (or create it).

    [Best for] Incremental log writing, accumulating results.
    [Note] Opens in append mode — no data is overwritten.
    """
    with open(path, "a", encoding=encoding) as fh:
        fh.write(content)


# =============================================================================
# 3. Binary — Read / Write
# =============================================================================


def read_binary(path: Path) -> bytes:
    """Read a file as raw bytes.

    [Best for] Images, archives, serialized blobs.
    [Note] Returns the full content — ensure it fits in memory.
    """
    return Path(path).read_bytes()


def write_binary(path: Path, data: bytes) -> None:
    """Write raw bytes to a file, creating parents if needed.

    [Best for] Saving downloaded content, serialized data.
    [Note] Overwrites the file if it already exists.
    """
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)


# =============================================================================
# 4. Seek — Random Access
# =============================================================================


def seek_and_read(path: Path, offset: int, size: int) -> bytes:
    """Read ``size`` bytes starting at ``offset`` from a binary file.

    [Best for] Reading headers, fixed-width records, sparse access.
    [Note] Uses ``seek``/``tell`` for O(1) positioning without reading preceding bytes.
    """
    with open(path, "rb") as fh:
        fh.seek(offset)
        return fh.read(size)


# =============================================================================
# 5. Split — Large File Chunking
# =============================================================================


def split_by_size(
    path: Path, chunk_bytes: int = 50 * 1024 * 1024, out_dir: Path | None = None
) -> list[Path]:
    """Split a file into fixed-size binary chunks.

    [Best for] Uploading large files in parts, parallel processing.
    [Note] Last chunk may be smaller than ``chunk_bytes``.
    """
    src = Path(path)
    dest = Path(out_dir) if out_dir else src.parent
    dest.mkdir(parents=True, exist_ok=True)
    parts: list[Path] = []

    with open(src, "rb") as fh:
        idx = 0
        while True:
            chunk = fh.read(chunk_bytes)
            if not chunk:
                break
            part_path = dest / f"{src.stem}.part{idx:04d}{src.suffix}"
            part_path.write_bytes(chunk)
            parts.append(part_path)
            idx += 1

    return parts


def split_by_lines(
    path: Path, lines_per_chunk: int = 10_000, out_dir: Path | None = None
) -> list[Path]:
    """Split a text file into chunks of N lines each.

    [Best for] Distributing CSV/log processing across workers.
    [Note] Streams the file — memory usage is constant regardless of file size.
    """
    src = Path(path)
    dest = Path(out_dir) if out_dir else src.parent
    dest.mkdir(parents=True, exist_ok=True)
    parts: list[Path] = []

    with open(src, encoding="utf-8") as fh:
        idx = 0
        batch: list[str] = []
        for line in fh:
            batch.append(line)
            if len(batch) >= lines_per_chunk:
                part_path = dest / f"{src.stem}.part{idx:04d}{src.suffix}"
                part_path.write_text("".join(batch), encoding="utf-8")
                parts.append(part_path)
                batch = []
                idx += 1
        if batch:
            part_path = dest / f"{src.stem}.part{idx:04d}{src.suffix}"
            part_path.write_text("".join(batch), encoding="utf-8")
            parts.append(part_path)

    return parts


# =============================================================================
# 6. Merge — Concatenate Files
# =============================================================================


def merge_files(paths: list[Path], output: Path, chunk_size: int = 1024 * 1024) -> None:
    """Merge multiple files into a single output file (binary-safe).

    [Best for] Reassembling split chunks, concatenating logs.
    [Note] Reads in streaming fashion — handles files larger than available RAM.
    """
    out = Path(output)
    out.parent.mkdir(parents=True, exist_ok=True)

    with open(out, "wb") as out_fh:
        for p in paths:
            with open(p, "rb") as in_fh:
                while True:
                    chunk = in_fh.read(chunk_size)
                    if not chunk:
                        break
                    out_fh.write(chunk)


# =============================================================================
# 7. CSV / JSON — Quick Structured I/O
# =============================================================================


def read_csv(path: Path, encoding: str = "utf-8") -> list[dict[str, str]]:
    """Read a CSV file into a list of dicts (one per row).

    [Best for] Quick data inspection, config tables, small datasets.
    [Note] All values are strings — cast manually if you need ints/floats.
    """
    import csv

    with open(path, newline="", encoding=encoding) as fh:
        return list(csv.DictReader(fh))


def write_csv(
    path: Path, rows: list[dict[str, str]], fieldnames: list[str] | None = None
) -> None:
    """Write a list of dicts to a CSV file with a header row.

    [Best for] Exporting tabular results, generating reports.
    [Note] ``fieldnames`` defaults to the keys of the first row.
    """
    import csv

    if not rows:
        return
    fields = fieldnames or list(rows[0].keys())
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)

    with open(p, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def read_json(path: Path, encoding: str = "utf-8") -> dict | list:
    """Load a JSON file and return the parsed object.

    [Best for] Config files, API response caches, structured data.
    [Note] Returns ``dict`` or ``list`` depending on the JSON root type.
    """
    import json

    return json.loads(Path(path).read_text(encoding=encoding))


def write_json(
    path: Path, data: dict | list, encoding: str = "utf-8", indent: int = 2
) -> None:
    """Write data to a pretty-printed JSON file.

    [Best for] Saving configs, caching API responses, exporting results.
    [Note] Uses ``ensure_ascii=False`` so non-Latin characters are preserved.
    """
    import json

    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(
        json.dumps(data, ensure_ascii=False, indent=indent) + "\n",
        encoding=encoding,
    )


# =============================================================================
# 8. Atomic Write — Crash-Safe Replacement
# =============================================================================


def atomic_write(path: Path, content: str, encoding: str = "utf-8") -> None:
    """Write to a temp file then atomically rename to the target path.

    [Best for] Config files, state files — anything that must not be half-written.
    [Note] On POSIX ``os.replace`` is atomic. On Windows it is as close to atomic
           as the OS allows. The temp file is created in the same directory to
           ensure it resides on the same filesystem.
    """
    import os
    import tempfile

    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)

    fd, tmp_path = tempfile.mkstemp(dir=p.parent, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding=encoding) as fh:
            fh.write(content)
        os.replace(tmp_path, p)
    except BaseException:
        os.unlink(tmp_path)
        raise


# =============================================================================
# 9. File Metadata — Size, Timestamps, Existence
# =============================================================================


def file_metadata(path: Path) -> dict[str, object]:
    """Return common file metadata as a dict.

    [Best for] Pre-flight checks, logging, file-change detection.
    [Note] ``mtime`` is a POSIX timestamp (float). Convert with
           ``datetime.fromtimestamp()`` if you need a human-readable form.
    """
    from datetime import datetime, timezone

    p = Path(path)
    if not p.exists():
        return {"exists": False, "path": str(p)}

    stat = p.stat()
    return {
        "exists": True,
        "path": str(p.resolve()),
        "size_bytes": stat.st_size,
        "mtime": stat.st_mtime,
        "mtime_iso": datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc).isoformat(),
        "is_file": p.is_file(),
        "is_dir": p.is_dir(),
    }
