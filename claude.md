Indent using 2 spaces.

Do not generate trailing whitespace. Trim trailing whitespace.

Prefer workflows that don't need Xcode.

Assume latest versions of MacOS.

Prefer `trash` over `rm` for deleting files and folders, except for temporary build directories which should be removed with `rm`.

Avoid unnecessary non-error logging. But always log errors.

Prefer CLI-only approaches. Avoid GUI when possible.

In all languages, use full sentences for comments: capitalized at the start, dot at the end.

In Swift, comments which fit on a single line should use `//`.

In Swift, comments which don't fit on a single line should be enclosed in `/* */`.

Avoid any timers and delays whenever possible.

In Make, rely on `MAKEFLAGS := --silent --always-build` to silence command logging, and avoid prefixing commands with `@`.

Avoid duplicating code.

Prefer early `return` over `else`.