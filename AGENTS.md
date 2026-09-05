# wazig development instructions

- Keep the client and its interface code in Zig. Use native Windows APIs and system libraries. Do not add Electron, WebView, .NET, Node, Java, or another bundled runtime.
- Keep startup time, installed size, and working-set memory measurable. Build release binaries with `zig build --release=small`.
- Treat WhatsApp as a provider, not the product name. The app is called `Messages`; Slack, Signal, and Telegram are planned providers.
- Use the installed official `wacli.exe` at `%LOCALAPPDATA%\Programs\wacli\wacli.exe` for WhatsApp transport and storage. Do not replace the preserved Go TUI project in the sibling `wacli-tui` directory.
- Never put API keys, WhatsApp data, contact names, message content, or local store files in Git. Deepgram reads `DEEPGRAM_API_KEY` from the user environment.
- IBM Plex Sans is loaded privately from the two font files installed beside `Messages.exe`. Keep the OFL license with them.
- Current WhatsApp support includes chat search, keyboard navigation, queued background sending, archive and unarchive, automatic mark-as-read when viewing a chat, reactions, official group names, cached contact and group profile images, automatic image downloads, animated GIF frames, video thumbnails after download, and in-app Ogg Opus voice-message playback.
- The Ctrl+K command palette is the control center for all commands (search, compose, dictate, dictation language, font size, archive, archived-chats view, reactions, refresh, sync, quit). Keep new commands registered in `buildPaletteItems`.
- Every wacli write or live-network command (send, react, archive, mark-read, media download, profile picture lookup) must pause the live-sync child first and restart it after; wacli fails with "store is locked" otherwise. Write arguments always include `--lock-wait`.
- Dictation captures the default communications microphone through WASAPI, uploads a WAV to Deepgram with WinHTTP after recording stops, and inserts the transcript into the composer. Auto-detect, English, and German modes are persisted in the registry.
