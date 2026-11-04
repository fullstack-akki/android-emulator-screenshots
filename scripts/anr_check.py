#!/usr/bin/env python3
"""Detect an Android ANR ("isn't responding") dialog in a uiautomator dump.

Stdlib only (xml.etree) so it runs on the stock python3 of a
GitHub-hosted runner with nothing to install.

Usage:
  anr_check.py <dump.xml>   read the hierarchy dump from a file
  anr_check.py -            read the hierarchy dump from stdin

The dump is produced on the device with one of:
    adb shell uiautomator dump /sdcard/window_dump.xml   (+ adb pull/cat)
    adb exec-out uiautomator dump /dev/tty               (XML on stdout)

Stdin mode exists because the file/pull path failed silently in
production (run #3, Nov 2026): the dump step produced nothing, the
pull failed, the check degraded to "unknown", and a bright ANR frame
was then accepted as success. Dumping to stdout removes the file
transfer entirely. Input read from stdin may be prefixed by the
uiautomator status line ("UI hierarchy dumped to: /dev/tty") and may
carry CR-LF line endings; the XML is extracted starting at the first
"<?xml" (or "<hierarchy") marker, and anything before it is ignored.

Output (always exit 0 unless the input itself is unreadable):
  NO_ANR                 no "isn't responding" dialog is showing
  WAIT <x> <y>           ANR dialog is showing; <x> <y> is the centre of
                         its "Wait" button (resource-id android:id/aerr_wait)
  ANR_NO_WAIT            ANR dialog is showing but no Wait button was found

The Wait button is located by its stable resource-id, not its text, so
the check works regardless of the device locale. The dialog is
detected by the phrases "isn't responding" / "not responding" in a
node's text, which covers both the app dialog ("<App> isn't
responding") and the system dialog ("Process system isn't
responding"). A text match alone only ever REJECTS a frame (never
accepts one on its own), so a stray matching string in page content
costs retries, never a false green.
"""

import sys
import xml.etree.ElementTree as ET


def read_dump(path):
    if path == "-":
        data = sys.stdin.buffer.read()
    else:
        with open(path, "rb") as fh:
            data = fh.read()
    text = data.decode("utf-8", errors="replace")
    start = text.find("<?xml")
    if start < 0:
        start = text.find("<hierarchy")
    if start < 0:
        raise ValueError("no UI hierarchy XML found in input")
    return text[start:]


def main(argv):
    if len(argv) != 2:
        print("usage: anr_check.py <dump.xml|->", file=sys.stderr)
        return 2
    try:
        xml_text = read_dump(argv[1])
    except (OSError, ValueError) as exc:
        print("ERROR: cannot read dump: %s" % exc, file=sys.stderr)
        return 2
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError as exc:
        print("ERROR: cannot parse dump XML: %s" % exc, file=sys.stderr)
        return 2
    nodes = list(root.iter("node"))
    anr_present = any(
        ("isn't responding" in (node.get("text") or "").lower()
         or "not responding" in (node.get("text") or "").lower())
        for node in nodes
    )
    if not anr_present:
        print("NO_ANR")
        return 0
    for node in nodes:
        if node.get("resource-id") == "android:id/aerr_wait":
            bounds = node.get("bounds") or ""
            try:
                left_top, right_bottom = bounds.strip("[]").split("][")
                x1, y1 = (int(v) for v in left_top.split(","))
                x2, y2 = (int(v) for v in right_bottom.split(","))
            except ValueError:
                print("ANR_NO_WAIT")
                return 0
            print("WAIT %d %d" % ((x1 + x2) // 2, (y1 + y2) // 2))
            return 0
    print("ANR_NO_WAIT")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
