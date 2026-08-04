#!/bin/bash
# Verifies the Foundation-free layers: the SFTP wire codec and the glob matcher.
#
# This exists because it works even when the platform SDK is broken. It compiles
# the real source files directly with swiftc — no SPM, no Foundation, no XCTest —
# so it is the one test suite that runs regardless of Command Line Tools state.
#
# The full XCTest suite lives in Tests/ and needs a working SDK.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# swiftc only permits top-level code in a file named main.swift, so the
# harness is staged under that name rather than compiled where it lives.
cp "$ROOT/Scripts/CodecVerification.swift" "$OUT/main.swift"

swiftc \
    "$ROOT/Sources/SFTPKit/SFTPProtocol.swift" \
    "$ROOT/Sources/SFTPKit/SFTPPacket.swift" \
    "$ROOT/Sources/CoreKit/Glob.swift" \
    "$OUT/main.swift" \
    -o "$OUT/verify"

"$OUT/verify"
