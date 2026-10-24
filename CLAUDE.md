@AGENTS.md

## Work
- Private agent rules, board, skills and handoff live in a private companion repo. Run `bash tools/agent-setup.sh` once in the main checkout: it links them in as `CLAUDE.local.md`, `HANDOFF.md`, `board.yml` and `.claude/skills` (all gitignored) and installs a `post-checkout` hook, so every worktree cut from it is linked too and `git worktree add` fails if the private repo is missing. Never commit them back.
- Nothing that names a person's machines, servers, accounts or contacts goes in this public repo, its PR text or commit messages: the `private-markers` check fails on it.
- One git worktree per ticket under `~/projects/wazig-wt/<TICKET>`, branched from `origin/main`. Never edit or build in the main checkout.
- Ship: `tools/ship.sh <TICKET> "<what changed>"` runs light checks locally, pushes, opens the PR and waits for `automerge.yml` to merge it and `auto-release.yml`/`release.yml` to publish a release for app changes.

## Build and test
- Pushes and PR commands run `tools/preflight-light.sh` locally: fast static checks and Python/Node tooling tests with J2-enforced parity against CI Python discovery and reasoned heavy exclusions, with no Zig or Wine invocation. The private-marker scan runs when `PRIVATE_MARKERS` is available; CI always enforces it.
- GitHub CI runs the unchanged full `tools/preflight.sh` with Zig 0.16.0: format, tests, Windows builds and harnesses. Never run the full preflight on the shared build server.
- `node tools/strip-comments.mjs --check`: CI rejects code comments; put the why in the commit or PR.
- build.zig harnesses slice `src/main.zig` by text markers; editing near them breaks `unfurl-verification`.

## Rules and what enforces them (WAZI-123)
| Rule | Enforced by |
|---|---|
| Pushes run only light checks locally; GitHub CI runs the full preflight. Never run full preflight on the shared build server (IGSH-518) | `.claude/hooks/preflight-guard.sh` and `tools/ship.sh` run `tools/preflight-light.sh`; `tools/test-preflight-guard.sh` rule J1 rejects full preflight and direct Zig calls in either entrypoint; rule J2 (IGSH-711) requires every CI-discovered Python test in the light list or a reasoned heavy-exclusion list; CI runs `tools/preflight.sh` |
| The wacli worker keeps the job it dequeues; a full archive queue keeps the unarchive request | `tools/lint-repeats.sh` rules A1, A2 |
| Release workflows dispatch release.yml for bot tags, wait for GUI exes, end expected-exit-3 checks with `exit 0`, never use `gh api --slurp`; automerge never requires the AI `code-review` check; workflows never call OpenRouter, Z.ai or any paid model provider, the advisory AI `code-review` job runs in `ai-review.yml` on same-repo, non-draft PR events or trusted `/ai-review` comments, checks out the default branch's tools and rules, calls the free Groq endpoint with the repository's free review key from the `GROQ_API_KEY` secret, skips with a notice when that key is unset, checks the response is JSON with a verdict instead of trusting a 200, uses per-file chunks, `AI_REVIEW_MODEL` overrides `openai/gpt-oss-120b`, and posts directly | `tools/lint-repeats.sh` rules B1 to B7 |
| Automerge waits for every non-AI check on the PR head, including unfurl-verification and the TDLib cache; missing, pending, skipped or failed checks block merging (IGSH-504) | `tools/lint-repeats.sh` rule B8 and `tools/test_no_comments.py` |
| Automerge only admits same-repository PRs by the repository owner (IGSH-635) | `tools/lint-repeats.sh` rule B9 and `tools/test_no_comments.py` |
| A pasted file is routed by the chat's provider (D1, WAZI-101) | `tools/lint-repeats.sh` rule D1 |
| Anthropic, OpenRouter and Deepgram keys and the Telegram API hash load through `slack_win.loadSecret` (DPAPI, plain values migrate on start), never as plain registry strings; `DEEPGRAM_API_KEY` seeds from the user's saved environment (`HKCU\Environment`), never the inherited process environment, and refreshes encrypted storage when it changes (WAZI-137, WAZI-145, IGSH-470) | `tools/lint-repeats.sh` rules C1, C2 |
| Rounded shapes use `smooth_shapes.fillRoundRect` and friends with explicit colours and a paint-level Context, never raw GDI RoundRect, Ellipse or rounded regions anywhere in src (WAZI-159) | `tools/lint-repeats.sh` rule F1 |
| Chat identities compare provider, account and jid with `chat_key.Key`, never two bare jids (WAZI-150) | `tools/lint-repeats.sh` rule E1 |
| No private markers in tracked files, PR title, PR body or PR commit messages; private agent files stay out of git | `tools/check_private_markers.py` in `private-markers.yml`, patterns from the `PRIVATE_MARKERS` secret (WAZI-138) |
| A dispatched auto-release waits for the running ci on main HEAD instead of refusing to tag | `tools/ci-green.sh` (WAZI-142) |
| Each check still fails on the past commit it was written for | `tools/test-preflight-guard.sh`, `tools/test-lint-repeats.sh`, `tools/test-ci-green.sh` in CI |
| New Actions run logs carry no private markers | `run-log-markers.yml` hourly, `tools/check_private_markers.py --logs` |
