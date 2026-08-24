# Mini

A personal web browser for macOS with no persistent state. Built on a fork of
[vercel-labs/native](https://github.com/vercel-labs/native) at `~/git/native`; it does not build against
the released SDK.

## Build and run

```sh
NATIVE_SDK_PATH=~/git/native native dev -Dweb-engine=system
NATIVE_SDK_PATH=~/git/native native test
./scripts/release.sh          # packaged mini.app in zig-out/package/
```
