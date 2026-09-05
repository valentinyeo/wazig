# wazig

`wazig` is a small native Windows messaging client written in Zig. WhatsApp through `wacli` is the first provider. Slack, Signal, and Telegram can be added behind the same interface later.

The interface uses Win32, Windows Imaging Component, and Windows shell thumbnail APIs. It does not embed Electron, WebView, .NET, Node, Java, or a browser engine.

## Current features

- WhatsApp chats, messages, search, sending, archive, and unarchive through `wacli`
- Official WhatsApp group names from the local group metadata store
- Automatic image downloads, inline images, animated GIFs, and video thumbnails after download
- Click-to-download videos and click-to-open local attachments
- Per-message WhatsApp reactions from the message context menu
- IBM Plex Sans bundled as a private application font
- Deepgram dictation control prepared for `DEEPGRAM_API_KEY`; microphone capture and streaming are not implemented yet

## Keyboard

| Key | Action |
| --- | --- |
| `Up` / `Down`, `J` / `K` | Move between chats |
| `Ctrl+Tab` / `Ctrl+Shift+Tab` | Select next / previous message |
| `Enter`, `C` | Focus the composer |
| `Enter` | Send from the composer |
| `Shift+Enter` | Insert a new line |
| `Ctrl+F`, `/` | Search chats |
| `Up` / `Down` in search | Move through results |
| `Enter` in search | Open the selected chat and compose |
| `E` | Archive or unarchive the selected chat |
| `U` | Toggle unread chats |
| `Ctrl+D` | Dictation control |
| `R` | Refresh |
| `Ctrl+K` | Command menu |
| `Esc` | Return to the chat list |
| `Q` | Quit |

Click the smiley button next to the composer to insert emoji from a small picker menu. Right-click a message bubble to react.

## Build

Install Zig 0.16, then run:

```powershell
zig build --release=small
```

The executable and IBM Plex font files are written to `zig-out\bin`. The app expects the official `wacli.exe` at `%LOCALAPPDATA%\Programs\wacli\wacli.exe`.

To prepare Deepgram dictation without committing a key:

```powershell
[Environment]::SetEnvironmentVariable('DEEPGRAM_API_KEY', 'your-key', 'User')
```
