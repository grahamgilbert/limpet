#!/usr/bin/env python3
"""Copy a release item from appcast-prerelease.xml into appcast.xml.

Reads the <item> matching --version from the prerelease feed and appends it
to the stable feed unchanged.  Used by the promote workflow so the DMG and
EdDSA signature are identical between channels.
"""

import argparse
import re
import sys
from pathlib import Path


def extract_item(xml: str, version: str) -> str | None:
    """Return the full <item>…</item> block for the given marketing version."""
    # Each item is bounded by </item>. Split on that so we never accidentally
    # merge consecutive items when searching with DOTALL.
    for raw in xml.split("</item>"):
        if f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>" in raw:
            start = raw.find("<item>")
            if start != -1:
                return raw[start:] + "</item>"
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prerelease-appcast", required=True)
    parser.add_argument("--stable-appcast", required=True)
    parser.add_argument("--version", required=True,
                        help="Marketing version to promote (e.g. 0.2.5)")
    args = parser.parse_args()

    prerelease_path = Path(args.prerelease_appcast)
    stable_path = Path(args.stable_appcast)

    prerelease_xml = prerelease_path.read_text()
    item = extract_item(prerelease_xml, args.version)
    if item is None:
        print(
            f"Version {args.version} not found in {prerelease_path}", file=sys.stderr
        )
        return 2

    stable_xml = stable_path.read_text()
    if f"<sparkle:shortVersionString>{args.version}</sparkle:shortVersionString>" in stable_xml:
        print(f"Version {args.version} already present in stable appcast — nothing to do.")
        return 0

    if "</channel>" not in stable_xml:
        print("Stable appcast.xml missing </channel>", file=sys.stderr)
        return 2

    new_stable = stable_xml.replace("</channel>", f"        {item}\n    </channel>")
    stable_path.write_text(new_stable)
    print(f"Promoted v{args.version} to stable appcast.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
