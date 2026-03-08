#!/usr/bin/env python3
"""
generate_icon.py — creates assets/fetch.ico with FETCH branding.
No external dependencies. Run once before building with PyInstaller.
"""
import struct, pathlib

# FETCH palette (BGRA byte order)
BG = (0x10, 0x08, 0x08, 0xFF)   # #080810  dark background
FG = (0x47, 0xFF, 0xC8, 0xFF)   # #c8ff47  lime accent


def _pixel_grid(size: int) -> list[list[tuple]]:
    """Draw a download-arrow icon on accent background."""
    px = [[BG] * size for _ in range(size)]
    s = size

    # Filled rounded rect in lime
    m = s // 8
    for y in range(m, s - m):
        for x in range(m, s - m):
            px[y][x] = FG

    # Arrow shaft (dark, centered vertically in top 55%)
    shaft_w = max(2, s // 6)
    shaft_x0 = (s - shaft_w) // 2
    shaft_y0 = s // 5
    shaft_y1 = s // 2
    for y in range(shaft_y0, shaft_y1):
        for x in range(shaft_x0, shaft_x0 + shaft_w):
            px[y][x] = BG

    # Arrowhead (inverted triangle below shaft)
    head_top = shaft_y1
    head_w   = shaft_w * 3
    head_h   = max(2, s // 7)
    cx       = s // 2
    for dy in range(head_h):
        half = head_w // 2 - round(dy * (head_w // 2) / head_h)
        for x in range(cx - half - head_w // 2, cx + half + head_w // 2 + 1):
            if 0 <= x < s:
                px[head_top + dy][x] = BG

    # Baseline bar below arrow
    bar_y  = head_top + head_h + max(1, s // 12)
    bar_h  = max(2, s // 10)
    bar_x0 = s // 4
    bar_x1 = s - s // 4
    for y in range(bar_y, min(bar_y + bar_h, s - m)):
        for x in range(bar_x0, bar_x1):
            px[y][x] = BG

    return px


def _make_bmp(size: int, pixels: list[list[tuple]]) -> bytes:
    """Encode pixels as ICO-compatible BITMAPINFOHEADER + BGRA pixel data + AND mask."""
    # BMP stores rows bottom-up
    raw = b"".join(
        struct.pack("BBBB", *px)
        for row in reversed(pixels)
        for px in row
    )
    # AND mask: all zeros (fully opaque), padded to 4-byte rows
    row_bytes = (size + 31) // 32 * 4
    and_mask  = b"\x00" * (row_bytes * size)

    header = struct.pack(
        "<IiiHHIIiiII",
        40,          # BITMAPINFOHEADER size
        size,        # width
        size * 2,    # height * 2 (ICO convention: includes AND mask)
        1,           # color planes
        32,          # bits per pixel (BGRA)
        0,           # compression (none)
        len(raw),    # image data size
        0, 0, 0, 0,  # resolution / color table (unused)
    )
    return header + raw + and_mask


def make_ico(out_path: pathlib.Path, sizes=(16, 32, 48)) -> None:
    images = []
    for sz in sizes:
        px  = _pixel_grid(sz)
        bmp = _make_bmp(sz, px)
        images.append((sz, bmp))

    count  = len(images)
    offset = 6 + 16 * count          # ICO header + directory

    # ICO header
    ico  = struct.pack("<HHH", 0, 1, count)

    # Directory entries
    for sz, bmp in images:
        ico += struct.pack(
            "<BBBBHHII",
            sz if sz < 256 else 0,   # width  (0 = 256)
            sz if sz < 256 else 0,   # height (0 = 256)
            0,                        # color count (0 = true color)
            0,                        # reserved
            1,                        # planes
            32,                       # bit count
            len(bmp),                 # size of image data
            offset,                   # offset from start of file
        )
        offset += len(bmp)

    # Image data
    for _, bmp in images:
        ico += bmp

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(ico)
    print(f"Created {out_path}  ({len(ico):,} bytes, sizes: {sizes})")


if __name__ == "__main__":
    dest = pathlib.Path(__file__).parent / "fetch.ico"
    make_ico(dest)
