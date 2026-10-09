# wazig handoff (2026-10-09, from the "Wazig" Claude session to triage-c3)

## State of main
- main = `8ccd8f9`. Merged today: #184 (automerge lists PR files again), #180 (media catch-up no longer spins the UI thread, WAZI-103), #181 (viewing a Slack chat calls conversations.mark, WAZI-104).
- **Released as v0.9.85** (contains #180, #181, #184). Not yet installed or tested on Valentin's PC: install it per the steps below.
- **Not tested on the PC yet.** #180 and #181 were reviewed by Codex (gpt-6.1-sol) and pass `zig build test` (168+ tests) and the Windows release build, but nobody has run them in the real app.

## Open work (all on board 4874, "Wazig")
| Ticket | PR | State |
|---|---|---|
| WAZI-79 open chat misses newest messages | #182 (branch `agent/wazig-dev-4-wazi-79-fresh`) | Rebased onto main at `4784e9f` (183/183 tests, Windows build ok), MERGEABLE. No hand edits to workflows, so automerge takes it once checks are green. Includes `.gitattributes` (`*.zig text eol=lf`) so the build.zig source harness matches on Windows CI. |
| WAZI-100 outbox: sends never lost or doubled | #183 (branch `agent/wazig-dev-1-wazi-100`) | Biggest change (journal in `%LOCALAPPDATA%\Messages\outbox.jsonl`, `src/outbox.zig`). Codex fixed ~15 defects and says it builds and tests clean, but is only safe after a Windows run: queue many sends, kill and restart, check order and no duplicates. It edits `.github/workflows/ci.yml`, so automerge skips it on purpose: merge by hand. The `code-review` check (OCR on GLM) keeps crashing on this diff (malformed tool calls); rerun it or merge on the other green checks. Needs a rebase after #182. |
| WAZI-101 Slack paste goes to WhatsApp + account-qualified ids | none | Not started. Do after #183 (same send path). |
| WAZI-102 one provider interface incl. archive | none | Not started. Groundwork for the wa-bridge provider. |
| WAZI-103, WAZI-104 | #180, #181 | Merged, awaiting release + PC test. |
- Old stale PRs #140, #131, #123 (conflicting, three weeks old) were left untouched as agreed; #182 supersedes the #123/#140 idea.
- Each ticket has a "Claimed." comment from this session. Move to Done only after a PC test.

## Build, ship, install
- Build here (Linux VPS): Zig **0.16.0** at `~/.local/zig-0.16.0/zig` (the `zig` on PATH is 0.15.2 and cannot build this repo).
  - `zig build test`
  - `zig build -Dtarget=x86_64-windows-gnu --release=small`
- Ship: PR, all checks green (`ci`, `windows-smoke`, `tdlib`, `unfurl-verification`, `code-review`), then `automerge.yml` merges it (runs after each `ci`, every 6 h, or `gh workflow run automerge.yml`). It skips drafts, `hold`, conflicts and PRs that edit the release-gating workflows. `auto-release.yml` then tags and `release.yml` publishes the zip with `SHA256SUMS.txt`.
- Merging by hand from a Claude session: the Hypertask `ship-check` merge guard is now scoped to Hypertask work only (`~/.claude/hooks/hypertask-only.sh` wraps it in `~/.claude/settings.json`), so `gh pr merge <n> --squash -R valentinyeo/wazig` works.
- Install on Valentin's PC (rule in CLAUDE.md): through `lh` (Windows box `laptop1`): download the release zip, verify SHA256 with `certutil` against `SHA256SUMS.txt`, stop Messages and wacli, delete `Messages.exe` (no `.old` copy), copy the new files, start the app, then test the new behaviour on screen (keys, clicks, `lh screenshot`). `wazigctl` (installed beside Messages.exe) reads app state without stealing focus: `wazigctl status`, `chats`, `select`, `messages`.

## How wazig gets messages today
- **WhatsApp: its own wacli session on the PC.** `%LOCALAPPDATA%\Programs\wacli\wacli.exe`, store in `%USERPROFILE%\.wacli\`. Live sync is `wacli --events sync --follow --download-media`; the UI polls the `wacli.db-wal` mtime every second. This is the second linked device that caused the 429s. **wa-bridge is not wired into wazig yet** (Phase 3 of https://yeoux.net/nh6ppjn). "Very old messages" today come from this local session or its snapshots (`%LOCALAPPDATA%\Messages\chats-<hash>.json`, per-chat snapshots), not from the bridge.
- Slack: native token mode (Socket Mode push) or bridge mode via slack-bridge (polls the open chat every 5 s, stops when minimized). Tokens are DPAPI-encrypted in the registry.
- Telegram: disabled in releases (TDLib cut from release.yml for CI time).

## Keys and config (locations only)
- wa-bridge key for wazig: on Hetzner `~/.config/wa-bridge/wazig-pc.key` (read scope). Not used by wazig yet.
- hax preset `wazig` (GLM 5.3 Flash via OpenRouter, 50 USD/month key): `~/.config/hax/config.json` on this VPS. `/hax-setup` skill mints more keys from `~/.config/openrouter/management.env`.
- GitHub secret `OPENROUTER_API_KEY` (code-review bot): replaced today with a dedicated 10 USD/month key; the old one was dead (401).

## Things that will bite you
- Executors on GLM write buggy code (Codex found ~15 defects in #183). Always have Codex review before merge.
- `pgrep -f`/`pkill -f` on a prompt marker matches your own wait loop or shell. Wait on saved PIDs.
- build.zig harnesses slice `src/main.zig` by text markers; editing near those markers breaks `unfurl-verification`.
- Analysis reports from today (sync deep dive, top problems): `sync.md` and `problems.md` in this session's scratchpad; the summary is in WAZI-100..104 descriptions.
