# Verification rule map

| Rule | Executable coverage | Feature map |
| --- | --- | --- |
| Right-click reactions send the clicked laughing face on WhatsApp and Slack | reactions.ps1 real SendInput, hub body ledger and check-evidence.py | [Reactions](features/reactions.md) |
| Slack archives are local per chat identity and never resurface on incoming hub rows or restart | slack-archive.ps1, SlackArchiveHandler and check-slack-archive-evidence.py with negative controls | [Slack archive](features/slack-archive.md) |
| Telegram has one saved view, opaque user/group/channel handles, a paper-plane badge and Saved Messages | src/hub_test.zig, Telegram journey row/state and blue-pixel assertions | [Telegram](features/telegram.md) |
| Telegram lists prelinked hub chats without in-app authentication | telegram journey populated rows, positive palette row and direct-command absence | [Telegram](features/telegram.md) |
| Telegram text, files, replies, reactions, reads, media and live events stay on the hub | telegram.ps1 and check-telegram-evidence.py wire/history assertions | [Telegram](features/telegram.md) |
| Telegram rate limits stay visible without retries; unsupported archive settles | src/hub_test.zig, Telegram journey failed bubble and one-attempt 429/502 ledger | [Telegram](features/telegram.md) |
| Signal is one account with opaque handles and its own saved view | src/hub_test.zig, src/messenger_view.zig, signal journey account/state assertions | [Signal](features/signal.md) |
| Signal lists prelinked hub chats without in-app authentication | signal journey populated account capture and history | [Signal](features/signal.md) |
| Signal history, text, files, reactions, read receipts, media and live events stay on the hub | signal journey, recorded writes and read-only histories, check-signal-evidence.py | [Signal](features/signal.md) |
| Signal 429/403 failures retain their reasons and never retry automatically | src/hub_test.zig mappings, signal journey failed bubbles and one-attempt ledger assertions | [Signal](features/signal.md) |
| Unsupported Signal archive settles without a retry loop | signal journey 502 and empty pending archive state | [Signal](features/signal.md) |
| Empty saved Signal/Telegram views never trap startup; Esc and every Alt view shortcut remain usable | notrap.ps1 and check-notrap-evidence.py startup seed, every-view screenshots, Escape state and full shortcut matrix | [No-trap](features/notrap.md) |
| New journeys appear in dispatch, PR matrix, evidence validation and maps | tools/verify-wazig/check-map.py checks Signal wiring and index links | [Index](features/README.md) |
| Slack icons and WhatsApp/Signal marks share the provider badge mechanism | src/hub_test.zig, workspace-icons journey screenshot crops and check-workspace-icons.py | [Workspace icons](features/workspace-icons.md) |
| WhatsApp archives stay archived on incoming messages; legacy keep flags migrate once per hub and survive restart | hub-archive.ps1, synthetic hub archive ledger and check-hub-archive-evidence.py | [Hub archive](features/hub-archive.md) |
| Ctrl+K finds every chat on every connected account, archived ones marked, from any view; Enter on an archived result opens it without unarchiving | palette-archived.ps1, PaletteArchivedHandler and check-palette-archived-evidence.py | [Palette archived](features/palette-archived.md) |
| Existing account order remains stable when empty Telegram and Signal are registered | views journey and check-views-evidence.py | [Views](features/views.md) |
| Every start maximizes on the saved monitor, including update relaunch | window journey reads native IsZoomed without forced harness maximization, including CreateProcessW launches with SW_SHOWNORMAL startup info and the updater's empty startup info, and requires the startup zoomed launch-log line; restores/resizes and closes through real keyboard input before same-profile restarts | [Window](features/window.md) |

IGSH-589: update the maps with the implementation and describe only actual assertions. GitHub execution and screenshot inspection remain required before claiming runtime success. The Signal fixture does not prove production authentication or delivery.

| Clipboard screenshots preserve dimensions and alpha through paste and Enter on every provider | paste-image.ps1 and check-paste-image-evidence.py native clipboard, decoded upload and exact send assertions | [Clipboard images](features/paste-image.md) |

| Media stays inside bubble content at the scaled height cap; time never covers the last text line | media-fit.ps1, MediaFitHandler, media-fit.cs and independent check-media-fit-evidence.py screenshot assertions | [Media fit](features/media-fit.md) |

| Composer border is equally thick on every side | composer-border.ps1 screenshot row/column probes, negative pixel control and saved app text scale cases | [Composer border](features/composer-border.md) |

| Slack standard shortcodes use generated public data; custom images stay account-scoped; Giphy animates through the hub media path | slack-emoji.ps1, SlackEmojiHandler and check-slack-emoji-evidence.py exact state, custom pixels, frame crop differences and cached hub bytes | [Slack emoji](features/slack-emoji.md) |

| Show archived is per-view, durable, marked and retains inbox unread filtering | show-archived.ps1, ShowArchivedHandler and check-show-archived-evidence.py | [Show archived](features/show-archived.md) |
