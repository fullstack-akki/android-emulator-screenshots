#!/usr/bin/env python3
"""Detect an Android ANR ("isn't responding") dialog in a uiautomator dump.

Stdlib only (xml.etree) so it runs on the stock python3 of a
GitHub-hosted macOS runner with nothing to install.

Usage: anr_check.py <dump.xml>

The dump is produced on the device with:
    adb shell uiautomator dump /sdcard/window_dump.xml
    adb pull /sdcard/window_dump.xml dump.xml

Output (always exit 0 unless the XML itself is unreadable):
  NO_ANR                 no "isn't responding" dialog is showing
  WAIT <x> <y>           ANR dialog is showing; <x> <y> is the centre of
                         its "Wait" button (resource-id android:id/aerr_wait)
  ANR_NO_WAIT            ANR dialog is showing but no Wait button was found

The Wait button is located by its stable resource-id, not its text, so
the check works regardless of the device locale.
"""

import sys
import xml.etree.ElementTree as ET


def main(argv):
    if len(argv) != 2:
        print("usage: anr_check.py <dump.xml>", file=sys.stderr)
        return 2
    try:
        tree = ET.parse(argv[1])
    except (ET.ParseError, OSError) as exc:
        print("ERROR: cannot parse %s: %s" % (argv[1], exc), file=sys.stderr)
        return 2
    root = tree.getroot()
    nodes = list(root.iter("node"))
    anr_present = any(
        "isn't responding" in (node.get("text") or "").lower()
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
