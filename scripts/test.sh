#!/bin/bash
# Runs `swift test`. With only the Command Line Tools installed (no Xcode), the Swift Testing
# framework lives outside the default search paths, so point the compiler and linker at it.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
flags=()
developer="$(xcode-select -p 2>/dev/null || true)"
if [[ "$developer" == *CommandLineTools* ]]; then
    frameworks="$developer/Library/Developer/Frameworks"
    flags=(-Xswiftc -F -Xswiftc "$frameworks"
           -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
           -Xlinker -F -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$frameworks")
fi

exec swift test --package-path "$root" ${flags[@]+"${flags[@]}"} "$@"
