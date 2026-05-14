#!/usr/bin/env python3
"""Append a new <item> to appcast.xml after a release."""

import argparse
import re
import sys
from pathlib import Path


def parse_signature_line(line: str) -> dict[str, str]:
    """Sparkle's sign_update emits something like:

        sparkle:edSignature="..." length="123456"

    Bash unquoting in CI can collapse this to:

        sparkle:edSignature=... length=...

    Accept either. Values with `=`, `+`, `/` (base64) are tolerated.
    """
    attrs: dict[str, str] = {}
    quoted = re.findall(r'(\w+(?::\w+)?)="([^"]*)"', line)
    if quoted:
        for k, v in quoted:
            attrs[k] = v
        return attrs
    for match in re.finditer(r'(\w+(?::\w+)?)=(\S+?)(?=\s+\w+(?::\w+)?=|\s*$)', line):
        attrs[match.group(1)] = match.group(2)
    return attrs


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--version", required=True,
                        help="Marketing version (e.g. 0.1.8) — goes into sparkle:shortVersionString.")
    parser.add_argument("--build", required=True,
                        help="Build number (monotonically increasing, e.g. git commit count) — goes into sparkle:version, which is what Sparkle compares against the running app's CFBundleVersion.")
    parser.add_argument("--url", required=True)
    parser.add_argument("--pub-date", required=True)
    parser.add_argument("--signature", required=True,
                        help='sign_update output, e.g. sparkle:edSignature="..." length="..."')
    parser.add_argument("--release-notes-url", required=False, default="",
                        help="Optional URL to release notes (Sparkle dialog will fetch and display it).")
    parser.add_argument("--release-notes-signature", required=False, default="",
                        help="EdDSA signature of the release notes file.")
    parser.add_argument("--release-notes-length", required=False, default="",
                        help="Byte length of the release notes file.")
    args = parser.parse_args()

    sig_attrs = parse_signature_line(args.signature)
    edsig = sig_attrs.get("sparkle:edSignature", "")
    length = sig_attrs.get("length", "0")

    if not edsig:
        print("Could not parse Sparkle signature from input", file=sys.stderr)
        print(f"  raw: {args.signature!r}", file=sys.stderr)
        return 2

    min_system_version = "26.0"

    notes_link = ""
    if args.release_notes_url:
        if args.release_notes_signature and args.release_notes_length:
            notes_link = (
                f'            <sparkle:releaseNotesLink'
                f' sparkle:edSignature="{args.release_notes_signature}"'
                f' length="{args.release_notes_length}"'
                f'>{args.release_notes_url}</sparkle:releaseNotesLink>\n'
            )
        else:
            notes_link = f"            <sparkle:releaseNotesLink>{args.release_notes_url}</sparkle:releaseNotesLink>\n"

    item = f"""        <item>
            <title>Version {args.version}</title>
            <pubDate>{args.pub_date}</pubDate>
            <sparkle:version>{args.build}</sparkle:version>
            <sparkle:shortVersionString>{args.version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{min_system_version}</sparkle:minimumSystemVersion>
            <link>https://github.com/grahamgilbert/limpet/releases/tag/v{args.version}</link>
{notes_link}            <enclosure url="{args.url}" sparkle:edSignature="{edsig}" length="{length}" type="application/octet-stream"/>
        </item>
"""

    path = Path(args.appcast)
    text = path.read_text()
    if "</channel>" not in text:
        print("appcast.xml missing </channel>", file=sys.stderr)
        return 2

    new_text = text.replace("</channel>", item + "    </channel>")
    path.write_text(new_text)
    print(f"Appended item for v{args.version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
