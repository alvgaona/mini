# Mini

A personal macOS browser with no persistent state. Built on a fork of
[vercel-labs/native](https://github.com/vercel-labs/native) at `~/git/native`, not the released SDK.

## Build and test

```sh
NATIVE_SDK_PATH=~/git/native native dev -Dweb-engine=system
NATIVE_SDK_PATH=~/git/native native test
NATIVE_SDK_PATH=~/git/native native check --strict
./scripts/release.sh          # packaged mini.app in zig-out/package/
```

## Documentation

Zig has no rustdoc equivalent in practice, but this project follows the same rules:

- Every `pub` declaration has a `///` doc comment: types, functions, constants, struct fields, and
  union variants.
- Every module has a top-level `//!` doc comment.
- Functions with non-obvious usage get a doctest, a `test <declName>` block placed right after the
  declaration. `test` only takes a bare identifier, so a doctest cannot live in `src/tests.zig` and
  reach `main.zig`. Every other test goes in `src/tests.zig`, which `main.zig` pulls in through its
  trailing `test` block.

Autodoc runs, but not from `.native/build/build.zig`, which is regenerated on every `native` command
and calls `addApp` (returns `void`). A throwaway build directory that calls `addAppArtifacts` and
installs `artifacts.exe.getEmittedDocs()` works, with `-Dweb-engine=system` to skip the CEF download.
Serve the output over HTTP. Opening it as `file://` hangs, because the page fetches `sources.tar`.

## Comment style

- State the non-obvious constraint, nothing else. No comment that restates the line below it.
- One to three lines, wrapped near 76 columns. `zig fmt` does not reflow comments.
- No em dashes, no hyphen-as-dash, no caps for emphasis, no colons joining two clauses.
- Deliberate shortcuts get a `ponytail:` marker naming the ceiling and the upgrade path.

## Conventions

- Conventional commits. Lefthook runs `native check --strict` on pre-commit and commitlint on the
  message. Do not commit `CLAUDE.md`, `.claude/`, or `.agents/`.
- The model never allocates. Every string is inline fixed-capacity storage, and long input truncates.
- History, reload, and find run on monotonic tokens. The value is inert; only the change matters.
