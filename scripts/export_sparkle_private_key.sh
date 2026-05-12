#!/usr/bin/env bash
#
# Print the Sparkle EdDSA private key from your login keychain to stdout.
# Use this once to seed the SPARKLE_PRIVATE_KEY GitHub Actions secret.
#
# The key was created locally by Sparkle's generate_keys tool. It lives in
# the login keychain under service "https://sparkle-project.org" account
# "ed25519". The key never leaves your Mac unless you copy it; this script
# only prints it.

set -euo pipefail

ACCOUNT="ed25519"
SERVICE="https://sparkle-project.org"

if ! security find-generic-password -a "$ACCOUNT" -s "$SERVICE" -w 2>/dev/null; then
    echo "Sparkle private key not found in keychain." >&2
    echo "Run Sparkle's generate_keys tool first:" >&2
    echo "  ~/Library/Developer/Xcode/DerivedData/limpet-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys" >&2
    exit 1
fi
