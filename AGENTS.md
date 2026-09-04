# wazig development instructions

- Keep the client and its interface code in Zig. Use native Windows APIs and system libraries. Do not add Electron, WebView, .NET, Node, Java, or another bundled runtime.
- Keep startup time, installed size, and working-set memory measurable. Build release binaries with `zig build --release=small`.
- Treat WhatsApp as a provider, not the product name. The app is called `Messages`; Slack, Signal, and Telegram are planned providers.
- Use the installed official `wacli.exe` at `%LOCALAPPDATA%\Programs\wacli\wacli.exe` for WhatsApp transport and storage. Do not replace the preserved Go TUI project in the sibling `wacli-tui` directory.
- Never put API keys, WhatsApp data, contact names, message content, or local store files in Git. Deepgram reads `DEEPGRAM_API_KEY` from the user environment.
- IBM Plex Sans is loaded privately from the two font files installed beside `Messages.exe`. Keep the OFL license with them.
- Current WhatsApp support includes chat search, keyboard navigation, sending, archive and unarchive, reactions, official group names, automatic image downloads, animated GIF frames, and video thumbnails after download.
- The Deepgram button, shortcut, and key detection are prepared. Microphone capture, streaming transcription, and insertion into the composer are the next unfinished feature.
