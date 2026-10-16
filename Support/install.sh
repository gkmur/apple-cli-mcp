#!/bin/zsh
# Builds apple-cli, wraps it in ~/Applications/AppleCLI.app, signs it, and links ~/.local/bin/apple-cli to it.
# The signed bundle is apple-cli's own identity, so macOS asks for Photos access in AppleCLI's name and
# keeps the grant across rebuilds (it is tied to the signing certificate, not the binary's hash).
set -euo pipefail
cd "${0:A:h}/.."

# Info.plist is linked into the binary, and the build does not notice when only it changes.
touch Sources/apple-cli/main.swift
swift build -c release

app=~/Applications/AppleCLI.app
# Replace, never copy over: macOS kills a binary rewritten in place (exit 137).
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp Support/Info.plist "$app/Contents/Info.plist"
cp .build/release/apple-cli "$app/Contents/MacOS/apple-cli"

# An Apple Development certificate keeps the identity stable. Ad hoc (-) works, but every rebuild asks again.
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')
# Hardened runtime makes dyld ignore DYLD_* variables, so no caller can inject code that runs with AppleCLI's grants.
codesign --force --options runtime --entitlements Support/AppleCLI.entitlements \
    --sign "${identity:--}" --identifier io.gkmur.apple-cli "$app"
codesign --verify --strict "$app"

mkdir -p ~/.local/bin
rm -f ~/.local/bin/apple-cli
ln -s "$app/Contents/MacOS/apple-cli" ~/.local/bin/apple-cli
echo "installed $(~/.local/bin/apple-cli --version), signed by ${identity:-ad hoc}"
