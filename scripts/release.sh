#!/usr/bin/env bash
# Release build + package for mini. The fork CLI is mandatory for
# packaging: the installed CLI generates the Info.plist itself and
# would drop the bluetooth usage key.
set -euo pipefail

sdk="${NATIVE_SDK_PATH:-$HOME/git/native}"
cli="$sdk/zig-out/bin/native"
cd "$(dirname "$0")/.."

if [[ ! -x "$cli" ]]; then
    echo "fork CLI missing - building it" >&2
    (cd "$sdk" && zig build cli)
fi

NATIVE_SDK_PATH="$sdk" native build --yes -Dweb-engine=system
"$cli" package --target macos --signing adhoc --web-engine system

echo
echo "release: $(pwd)/zig-out/package/mini.app"
