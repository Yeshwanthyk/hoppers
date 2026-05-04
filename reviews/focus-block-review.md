Critical:
- `scripts/install-tmux-bindings.sh:25` removes the only binding that enters the `hoppers` key table (`switch-client -T hoppers`). All `-T hoppers` bindings on lines 27-40 become unreachable via `@hoppers-prefix-key`, so `s`, `j/k`, `S-Up/S-Down`, and `1..9` regress. If Space should also open/focus the sidebar, chain it with `switch-client -T hoppers` or add a separate binding; don't replace the prefix table entry.

Warnings:
- `scripts/sidebar.sh:53-57` focuses the sidebar even when it already exists, but `open_sidebar` also creates/focuses a new split as a side effect. That is consistent for `open-focus`, but it means any caller using `open`/`sync` may still steal focus when creating a missing sidebar (pre-existing behavior). If the intent is only prefix-triggered focus, consider making `open_sidebar` preserve the previous pane and let `open-focus` explicitly select the sidebar.

Suggestions:
- `scripts/install-tmux-bindings.sh:25` lost the help/status message shown when entering the table. If keeping a prefix mode, preserve the `display-message` so users can discover bindings.

Summary:
- Quoting of `$sidebar_script open-focus >$log_path 2>&1` looks safe with the existing single-quote helper. Main blocker is binding semantics: the hoppers key table is no longer reachable from the configured prefix.
