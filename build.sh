#!/bin/bash
# Builds mac-apps-mcp. Run from this folder:  ./build.sh
set -e
cd "$(dirname "$0")"
command -v swiftc >/dev/null || { echo "swiftc not found. Run: xcode-select --install"; exit 1; }
swiftc -O Sources/*.swift -o mac-apps-mcp \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
codesign --force --sign - --identifier local.mac-apps-mcp mac-apps-mcp
echo
echo "Built: $(pwd)/mac-apps-mcp"
echo "Quick check:  ./mac-apps-mcp --test"
