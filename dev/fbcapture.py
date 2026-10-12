#!/usr/bin/env python3
"""Dump /dev/fb0 to a PNG.

Used to see what the panel is *actually* scanning out -- a QML grabToImage only
captures the app's own surface, which hides rotation problems.  Run it while a
screen is up to check orientation.

    python3 dev/fbcapture.py /tmp/panel.png
"""
import fcntl
import os
import struct
import sys
import zlib

FBIOGET_VSCREENINFO = 0x4600
FBIOGET_FSCREENINFO = 0x4602


def write_png(path, width, height, rows):
    """rows: iterable of RGB byte strings, one per scanline."""
    raw = b"".join(b"\x00" + row for row in rows)

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    blob = (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(raw, 6))
            + chunk(b"IEND", b""))
    with open(path, "wb") as fh:
        fh.write(blob)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/panel.png"
    fd = os.open("/dev/fb0", os.O_RDONLY)

    vinfo = bytearray(160)
    fcntl.ioctl(fd, FBIOGET_VSCREENINFO, vinfo)
    xres, yres, xres_v, yres_v = struct.unpack("IIII", bytes(vinfo[:16]))
    bpp = struct.unpack("I", bytes(vinfo[24:28]))[0]

    finfo = bytearray(128)
    fcntl.ioctl(fd, FBIOGET_FSCREENINFO, finfo)
    line_length = struct.unpack("I", bytes(finfo[48:52]))[0]
    if not line_length:
        line_length = xres_v * bpp // 8

    print("fb0: %dx%d (virtual %dx%d) %d bpp, line_length=%d"
          % (xres, yres, xres_v, yres_v, bpp, line_length))

    stride = bpp // 8
    rows = []
    for y in range(yres):
        row = os.pread(fd, xres * stride, y * line_length)
        if stride == 4:
            # sunxi display engine is BGRA in memory
            rows.append(b"".join(row[i + 2:i + 3] + row[i + 1:i + 2] + row[i:i + 1]
                                 for i in range(0, len(row), 4)))
        else:
            rows.append(b"".join(row[i:i + 3] for i in range(0, len(row), stride)))

    os.close(fd)
    write_png(out, xres, yres, rows)
    print("wrote", out)


if __name__ == "__main__":
    main()
