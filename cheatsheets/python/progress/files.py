"""Byte-Based Progress Bars - Copy-Paste Cheatsheet.

Progress measured in bytes: copying files and consuming a stream of chunks
(an HTTP download, a socket, a subprocess pipe).

| Function             | Best for                                 | Returns |
|----------------------|------------------------------------------|---------|
| copy_file_tqdm       | Bytes copied, human-readable units       | int     |
| copy_file_rich       | Bytes copied, speed + ETA columns        | int     |
| consume_chunks_tqdm  | Streaming download, unknown total ok     | int     |
| consume_chunks_rich  | Streaming download, transfer columns     | int     |

Usage:
    1. Copy the function you need (its imports travel with it).
    2. For downloads, pass ``response.iter_bytes()`` (httpx) or
       ``response.iter_content(chunk_size)`` (requests) as ``chunks``, the
       ``Content-Length`` header (or ``None``) as ``total``, and a writer such
       as ``file.write`` or ``bytearray.extend`` as ``sink``.

Dependencies:
    pip install tqdm rich

Note:
    Every function returns the number of bytes consumed. Errors propagate:
    a half-written destination is the caller's to clean up.
"""

from collections.abc import Callable, Iterable
from pathlib import Path

# 64 KiB matches shutil.copyfileobj's default and keeps the bar refresh
# frequent enough to look live on a fast disk.
CHUNK_SIZE = 64 * 1024

# =============================================================================
# 1. Copying a file
# =============================================================================


def copy_file_tqdm(src: Path, dst: Path, chunk_size: int = CHUNK_SIZE) -> int:
    """Copy ``src`` to ``dst`` with a tqdm bar measured in bytes.

    [Best for] Any copy/convert step where the user waits on a large file.
    [Note] ``unit="B", unit_scale=True, unit_divisor=1024`` renders "12.3MiB/s".
    """
    from tqdm import tqdm

    total = src.stat().st_size
    written = 0
    with (
        src.open("rb") as reader,
        dst.open("wb") as writer,
        tqdm(
            total=total, desc=src.name, unit="B", unit_scale=True, unit_divisor=1024
        ) as bar,
    ):
        while chunk := reader.read(chunk_size):
            written += writer.write(chunk)
            bar.update(len(chunk))
    return written


def copy_file_rich(src: Path, dst: Path, chunk_size: int = CHUNK_SIZE) -> int:
    """Copy ``src`` to ``dst`` with a rich bar measured in bytes.

    [Best for] The same copy with rich's transfer columns.
    [Note] ``rich.progress.open`` wraps the file so every ``read`` advances the
           bar; the bar shows size, speed and remaining time by default.
    """
    import rich.progress

    written = 0
    with (
        rich.progress.open(src, "rb", description=src.name) as reader,
        dst.open("wb") as writer,
    ):
        while chunk := reader.read(chunk_size):
            written += writer.write(chunk)
    return written


# =============================================================================
# 2. Consuming a stream of chunks (download, pipe, socket)
# =============================================================================


def consume_chunks_tqdm(
    chunks: Iterable[bytes], sink: Callable[[bytes], object], total: int | None = None
) -> int:
    """Feed ``chunks`` into ``sink`` with a tqdm bar measured in bytes.

    [Best for] Downloads where ``total`` comes from ``Content-Length``.
    [Note] With ``total=None`` tqdm shows a counter and speed but no ETA.
    """
    from tqdm import tqdm

    written = 0
    with tqdm(
        total=total, desc="Download", unit="B", unit_scale=True, unit_divisor=1024
    ) as bar:
        for chunk in chunks:
            sink(chunk)
            written += len(chunk)
            bar.update(len(chunk))
    return written


def consume_chunks_rich(
    chunks: Iterable[bytes], sink: Callable[[bytes], object], total: int | None = None
) -> int:
    """Feed ``chunks`` into ``sink`` with rich's transfer columns.

    [Best for] Downloads that should look like a package manager's.
    [Note] ``DownloadColumn`` renders "1.2/8.0 MiB", ``TransferSpeedColumn``
           the rate. With ``total=None`` the bar pulses until ``total`` is set
           via ``progress.update(task, total=...)``.
    """
    from rich.progress import (
        BarColumn,
        DownloadColumn,
        Progress,
        TextColumn,
        TimeRemainingColumn,
        TransferSpeedColumn,
    )

    written = 0
    with Progress(
        TextColumn("[bold blue]{task.description}"),
        BarColumn(),
        DownloadColumn(),
        TransferSpeedColumn(),
        TimeRemainingColumn(),
    ) as progress:
        task = progress.add_task("Download", total=total)
        for chunk in chunks:
            sink(chunk)
            written += len(chunk)
            progress.advance(task, len(chunk))
    return written


# =============================================================================
# Quick Sanity Check
# =============================================================================

if __name__ == "__main__":
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "source.bin"
        src.write_bytes(bytes(range(256)) * 4096)  # 1 MiB
        size = src.stat().st_size

        got_tqdm = copy_file_tqdm(src, Path(tmp) / "copy-tqdm.bin", chunk_size=4096)
        got_rich = copy_file_rich(src, Path(tmp) / "copy-rich.bin", chunk_size=4096)

        def chunks(count: int, size: int = 4096) -> Iterable[bytes]:
            """Yield ``count`` chunks of ``size`` zero bytes."""
            for _ in range(count):
                yield b"\0" * size

        collected = bytearray()
        got_stream_tqdm = consume_chunks_tqdm(
            chunks(256), collected.extend, total=256 * 4096
        )
        got_stream_rich = consume_chunks_rich(chunks(256), collected.extend)

    checks = {
        "copy tqdm": (got_tqdm, size),
        "copy rich": (got_rich, size),
        "stream tqdm": (got_stream_tqdm, 256 * 4096),
        "stream rich": (got_stream_rich, 256 * 4096),
    }
    for name, (got, want) in checks.items():
        if got != want:
            raise SystemExit(f"{name}: wrote {got} bytes, expected {want}")
        print(f"ok: {name} ({got} bytes)")
    print("All sanity checks passed.")
