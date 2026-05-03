# AGENTS.md

Project: **hoppers** — fresh Zig/libvaxis tmux agent orchestrator.

## Required Zig references

- Use `zigdoc` from <https://github.com/rockorager/zigdoc> before writing or changing non-trivial Zig APIs.
  - Examples: `zigdoc std.mem.Allocator`, `zigdoc std.process.Child`, `zigdoc vaxis.Window`.
  - Prefer verified signatures from `zigdoc` over memory.
- Follow `ziglint` from <https://github.com/rockorager/ziglint>.
  - Run `zig build lint` before finalizing Zig changes when possible.
  - `zig build test` also depends on formatting and ziglint.

## Zig style

- Zig 0.15.2.
- No inline `@import`; assign imports to top-level `const`.
- camelCase functions, snake_case variables, PascalCase types/error sets.
- Prefer `const value: T = .{}` over `const value = T{}`.
- Avoid redundant casts/type specifiers.
- `deinit` methods must release resources and end with `self.* = undefined`.
- Keep lines <= 120 chars unless a rule-specific exception is justified.

## Product direction

- hoppers is built from scratch; opensessions is reference only.
- Core language: Zig.
- TUI: libvaxis.
- Distribution must work through TPM as a tmux plugin.
- v1 scope: project-grouped agent cockpit, monitor/jump/prioritize only.
- Defer agent launching/resume/worktree mutation until jump/triage is excellent.

## Verification

Use, in order:

```sh
zig build test
zig build lint
zig build
```

Only claim a command ran if tool output confirms it.
