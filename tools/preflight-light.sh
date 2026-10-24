#!/usr/bin/env bash
set -euo pipefail
cd "${1:-$(git rev-parse --show-toplevel)}"
run() { echo "preflight-light: $*"; "$@"; }
PYTHON_LIGHT_TESTS=(
    test_ai_review
    test_check_cache_keys
    test_check_private_markers
    test_fake_wa_bridge
    test_link_previews
    test_media_layout
    test_no_comments
    test_no_stories
    test_palette_archived
    test_pin_icon
    test_reaction_layout
    test_recording_paint
    test_repaint
    test_search_center
    test_show_archived
    test_slack_emoji
    test_slack_sort
    test_slack_threads
    test_tdlib_release
    test_update_cards
    test_verify_journeys
    test_workspace_names
)
PYTHON_HEAVY_TESTS=(
    'test_theme_runtime: unittest cases invoke Zig compiler and runtime harnesses'
    'test_outbox_runtime: standalone Zig runtime harness; no unittest cases'
    'test_slack_integration: standalone Zig and optional Windows/Wine harness; no unittest cases'
)
run bash tools/test-preflight-guard.sh --check-light
run bash tools/lint-repeats.sh .
run node tools/strip-comments.mjs --check
run node tools/check-fonts.mjs
run python3 tools/check_cache_keys.py
run python3 tools/verify-wazig/check-map.py
if [ -n "${PRIVATE_MARKERS:-}" ]; then
    run python3 tools/check_private_markers.py
else
    echo 'preflight-light: private-marker scan skipped (PRIVATE_MARKERS unavailable); CI enforces it.'
fi
run node --test tools/check-fonts.test.mjs tools/strip-comments.test.js
(
    cd tools
    run python3 -m unittest "${PYTHON_LIGHT_TESTS[@]}"
)
echo 'preflight-light: all checks passed'
