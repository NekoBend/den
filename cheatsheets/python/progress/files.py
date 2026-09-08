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
    a half-written destination is the caller's to clean up. The two copiers
    match ``shutil.copy2``: metadata travels with the bytes and a destination
    that is the source raises ``shutil.SameFileError`` instead of truncating
    it.
"""

from collections.abc import Callable, Iterable
from pathlib import Path

# =============================================================================
# 1. Copying a file
# =============================================================================


def copy_file_tqdm(src: Path, dst: Path, chunk_size: int = 64 * 1024) -> int:
    """Copy ``src`` to ``dst`` with a tqdm bar measured in bytes.

    [Best for] Any copy/convert step where the user waits on a large file.
    [Note] ``samefile`` first: ``dst.open("wb")`` truncates before the first
           read, so copying a file onto itself (a symlink or hardlink to the
           source, or ``out_dir / src.name`` when ``out_dir`` is the source's
           own directory) would destroy it and report 0 bytes copied.
           ``shutil.copystat`` at the end keeps mode and times, as
           ``shutil.copy2`` does; without it a 0600 secret lands 0644.
           ``unit="B", unit_scale=True, unit_divisor=1024`` divides by 1024 but
           labels it "12.3MB/s": tqdm's prefixes never carry the "i".
           64 KiB is ``shutil.copyfileobj``'s block size and keeps the bar
           refresh frequent enough to look live on a fast disk.
    """
    import shutil

    from tqdm import tqdm

    if dst.exists() and src.samefile(dst):
        raise shutil.SameFileError(f"{src} and {dst} are the same file")
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
    shutil.copystat(src, dst)
    return written


def copy_file_rich(src: Path, dst: Path, chunk_size: int = 64 * 1024) -> int:
    """Copy ``src`` to ``dst`` with a rich bar measured in bytes.

    [Best for] The same copy with rich's transfer columns.
    [Note] ``progress.open`` wraps the file so every ``read`` advances the bar.
           The module-level ``rich.progress.open`` hard-codes its columns to
           description, bar, ``DownloadColumn`` and ``TimeRemainingColumn`` and
           takes no ``columns`` argument, so the speed readout needs an
           explicit ``Progress`` with ``TransferSpeedColumn``. Same
           ``samefile`` guard and ``shutil.copystat`` as ``copy_file_tqdm``.
    """
    import shutil

    from rich.progress import (
        BarColumn,
        DownloadColumn,
        Progress,
        TextColumn,
        TimeRemainingColumn,
        TransferSpeedColumn,
    )

    if dst.exists() and src.samefile(dst):
        raise shutil.SameFileError(f"{src} and {dst} are the same file")
    written = 0
    with (
        Progress(
            TextColumn("[bold blue]{task.description}"),
            BarColumn(),
            DownloadColumn(),
            TransferSpeedColumn(),
            TimeRemainingColumn(),
        ) as progress,
        progress.open(src, "rb", description=src.name) as reader,
        dst.open("wb") as writer,
    ):
        while chunk := reader.read(chunk_size):
            written += writer.write(chunk)
    shutil.copystat(src, dst)
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
    import shutil
    import stat
    import tempfile

    copiers = {"copy tqdm": copy_file_tqdm, "copy rich": copy_file_rich}

    with tempfile.TemporaryDirectory() as tmp:
        out_dir = Path(tmp)
        src = out_dir / "source.bin"
        src.write_bytes(bytes(range(256)) * 4096)  # 1 MiB
        src.chmod(0o640)
        size = src.stat().st_size
        payload = src.read_bytes()

        for name, copier in copiers.items():
            dst = out_dir / f"{name.replace(' ', '-')}.bin"
            written = copier(src, dst, chunk_size=4096)
            if written != size:
                raise SystemExit(f"{name}: wrote {written} bytes, expected {size}")
            if dst.read_bytes() != payload:
                raise SystemExit(f"{name}: the copy differs from the source")
            mode = stat.S_IMODE(dst.stat().st_mode)
            if mode != 0o640:
                raise SystemExit(f"{name}: mode is {mode:#o}, expected 0o640")
            print(f"ok: {name} ({written} bytes, mode {mode:#o})")

            # The ordinary call shape that aims the destination at the source.
            try:
                copier(src, out_dir / src.name, chunk_size=4096)
            except shutil.SameFileError:
                pass
            else:
                raise SystemExit(f"{name}: copying onto the source was not refused")
            if src.stat().st_size != size or src.read_bytes() != payload:
                raise SystemExit(f"{name}: the source was damaged by a same-file copy")
            print(f"ok: {name} refused a same-file copy, source intact")

        def chunks(count: int, size: int = 4096) -> Iterable[bytes]:
            """Yield ``count`` chunks of ``size`` zero bytes."""
            for _ in range(count):
                yield b"\0" * size

        collected = bytearray()
        got_stream_tqdm = consume_chunks_tqdm(
            chunks(256), collected.extend, total=256 * 4096
        )
        got_stream_rich = consume_chunks_rich(chunks(256), collected.extend)

    streamed = {
        "stream tqdm": (got_stream_tqdm, 256 * 4096),
        "stream rich": (got_stream_rich, 256 * 4096),
    }
    for name, (got, want) in streamed.items():
        if got != want:
            raise SystemExit(f"{name}: consumed {got} bytes, expected {want}")
        print(f"ok: {name} ({got} bytes)")
    if len(collected) != 2 * 256 * 4096:
        raise SystemExit(f"sink: collected {len(collected)} bytes, expected 2 MiB")
    print("All sanity checks passed.")
