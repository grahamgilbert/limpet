#!/usr/bin/env python3
"""Convert a minimal subset of Markdown to HTML for Sparkle release notes."""

import re
import sys


def convert(text: str) -> str:
    text = re.sub(r"^## (.+)$", r"<h2>\1</h2>", text, flags=re.MULTILINE)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"^\* (.+)$", r"<li>\1</li>", text, flags=re.MULTILINE)
    text = text.replace("\n\n", "<br>")
    return text


if __name__ == "__main__":
    body = sys.stdin.read()
    print(f"<!DOCTYPE html><html><body>{convert(body)}</body></html>", end="")
