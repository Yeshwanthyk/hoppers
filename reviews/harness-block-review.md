Critical:
- None.

Warnings:
- None.

Suggestions:
- `scripts/test-tmux-harness.sh:100-101`: the new plugin assertion checks that `prefix Space` is bound to `sidebar.sh open-focus`, but it only validates the binding text. It does not exercise the key path or assert the resulting pane focus. Consider sending `prefix Space` in the harness and checking that the active pane is the `hoppers-sidebar` pane; that would cover the new sidebar focus UX end-to-end.
- `scripts/test-tmux-harness.sh:131`: `contains "$capture" '›'` proves some selection glyph is rendered, but not that the selected row is meaningful/current. If selection behavior regresses to always marking the wrong row, this test still passes. A stronger check would tie the marker to the expected first/ranked agent row, if the rendered ordering is stable enough.

Summary:
- The added assertions are compatible with the new sidebar UX and the full verification sequence passes. Coverage is useful but still mostly snapshot/string-based; focus behavior is not yet exercised end-to-end.

Verification:
- Ran: `zig build test && zig build lint && zig build && scripts/test-tmux-harness.sh` — passed.
