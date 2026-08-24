# Mini

[![ci](https://github.com/alvgaona/mini/actions/workflows/ci.yaml/badge.svg)](https://github.com/alvgaona/mini/actions/workflows/ci.yaml)
[![release](https://github.com/alvgaona/mini/actions/workflows/release.yaml/badge.svg)](https://github.com/alvgaona/mini/actions/workflows/release.yaml)
[![version](https://img.shields.io/badge/dynamic/regex?url=https%3A%2F%2Fraw.githubusercontent.com%2Falvgaona%2Fmini%2Fmain%2Fapp.zon&search=%5C.version%20%3D%20%22(%5B%5E%22%5D%2B)%22&replace=%241&label=version)](https://github.com/alvgaona/mini/blob/main/app.zon)
[![native-sdk](https://img.shields.io/badge/native--sdk-000000?logo=vercel&logoColor=white)](https://github.com/vercel-labs/native)

A personal web browser for macOS with no persistent state. Built on a fork of
[vercel-labs/native](https://github.com/vercel-labs/native) at `~/git/native`; it does not build against
the released SDK.

## Build and run

```sh
NATIVE_SDK_PATH=~/git/native native dev -Dweb-engine=system
NATIVE_SDK_PATH=~/git/native native test
./scripts/release.sh          # packaged mini.app in zig-out/package/
```
