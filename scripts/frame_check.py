#!/usr/bin/env python3
"""Check whether an ADB screencap PNG shows a real frame or a black one.

Stdlib only (zlib/struct) so it runs on the stock python3 of a
GitHub-hosted macOS runner with nothing to install.

Usage: frame_check.py <png_path> <min_nonblack_fraction>

Prints "nonblack_fraction=... mean_brightness=... sampled=..." and exits 0
when the fraction of sampled pixels that are not near-black is at least
the threshold, 1 when the frame is (near-)black, 2 on any parse error.

A pixel counts as non-black when max(R, G, B) > 16. A real Chrome page
(light background, status bar, text) scores >0.90; the observed
all-black failure frame scores 0.0000. The threshold is deliberately
lenient (default callers pass 0.05): this check exists to reject
blank/black captures, not to judge page content.

Supported: 8-bit, non-interlaced PNG, color types 0 (gray), 2 (RGB),
3 (palette), 4 (gray+alpha), 6 (RGBA), all five row filters.
"""

import struct
import sys
import zlib

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


def fail(message):
    print("ERROR: %s" % message, file=sys.stderr)
    sys.exit(2)


def read_chunks(data):
    if data[:8] != PNG_SIGNATURE:
        fail("not a PNG file (bad signature)")
    chunks = {}
    idat = bytearray()
    pos = 8
    while pos < len(data):
        if pos + 8 > len(data):
            fail("truncated PNG chunk header")
        length, ctype = struct.unpack(">I4s", data[pos:pos + 8])
        pos += 8
        if pos + length + 4 > len(data):
            fail("truncated PNG chunk %r" % ctype)
        payload = data[pos:pos + length]
        pos += length + 4  # skip payload + CRC
        if ctype == b"IHDR":
            chunks["IHDR"] = payload
        elif ctype == b"PLTE":
            chunks["PLTE"] = payload
        elif ctype == b"IDAT":
            idat.extend(payload)
        elif ctype == b"IEND":
            break
    if "IHDR" not in chunks:
        fail("PNG has no IHDR chunk")
    if not idat:
        fail("PNG has no IDAT chunk")
    return chunks, bytes(idat)


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def unfilter(raw, width, height, channels):
    """Undo PNG row filters. Returns a list of rows, each a bytes object
    of width*channels samples (palette indices for color type 3)."""
    stride = width * channels
    expected = (stride + 1) * height
    if len(raw) != expected:
        fail("decompressed size %d != expected %d" % (len(raw), expected))
    rows = []
    prev = bytes(stride)
    offset = 0
    for _ in range(height):
        ftype = raw[offset]
        offset += 1
        line = bytearray(raw[offset:offset + stride])
        offset += stride
        if ftype == 0:
            pass
        elif ftype == 1:  # Sub
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif ftype == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:  # Average
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:  # Paeth
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                line[i] = (line[i] + paeth(a, b, c)) & 0xFF
        else:
            fail("unknown PNG filter type %d" % ftype)
        rows.append(bytes(line))
        prev = bytes(line)
    return rows


def analyze(path, threshold):
    with open(path, "rb") as fh:
        data = fh.read()
    chunks, idat = read_chunks(data)
    (width, height, bit_depth, color_type, compression, filter_method,
     interlace) = struct.unpack(">IIBBBBB", chunks["IHDR"])
    if bit_depth != 8:
        fail("unsupported bit depth %d (only 8-bit PNG)" % bit_depth)
    if color_type not in CHANNELS:
        fail("unsupported color type %d" % color_type)
    if compression != 0 or filter_method != 0:
        fail("unsupported compression/filter method in IHDR")
    if interlace != 0:
        fail("interlaced PNG not supported")
    channels = CHANNELS[color_type]
    palette = chunks.get("PLTE")
    if color_type == 3 and palette is None:
        fail("palette PNG without PLTE chunk")
    try:
        raw = zlib.decompress(idat)
    except zlib.error as exc:
        fail("zlib decompress failed: %s" % exc)
    rows = unfilter(raw, width, height, channels)

    total_pixels = width * height
    stride = max(1, total_pixels // 60000)
    sampled = 0
    nonblack = 0
    brightness_sum = 0
    index = 0
    for row in rows:
        for x in range(width):
            if index % stride == 0:
                off = x * channels
                if color_type == 0:
                    peak = row[off]
                elif color_type == 2:
                    peak = max(row[off], row[off + 1], row[off + 2])
                elif color_type == 3:
                    pi = row[off] * 3
                    if pi + 2 >= len(palette):
                        fail("palette index out of range")
                    peak = max(palette[pi], palette[pi + 1], palette[pi + 2])
                elif color_type == 4:
                    peak = row[off]
                else:  # RGBA: ignore alpha
                    peak = max(row[off], row[off + 1], row[off + 2])
                sampled += 1
                brightness_sum += peak
                if peak > 16:
                    nonblack += 1
            index += 1
    fraction = (nonblack / sampled) if sampled else 0.0
    mean = (brightness_sum / sampled) if sampled else 0.0
    print("nonblack_fraction=%.4f mean_brightness=%.1f sampled=%d "
          "size=%dx%d" % (fraction, mean, sampled, width, height))
    return 0 if fraction >= threshold else 1


def main(argv):
    if len(argv) != 3:
        print("usage: frame_check.py <png_path> <min_nonblack_fraction>",
              file=sys.stderr)
        return 2
    try:
        threshold = float(argv[2])
    except ValueError:
        print("ERROR: threshold must be a number", file=sys.stderr)
        return 2
    try:
        return analyze(argv[1], threshold)
    except FileNotFoundError:
        fail("file not found: %s" % argv[1])
    except OSError as exc:
        fail("cannot read %s: %s" % (argv[1], exc))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
