# Show archived in each view

## Sub-features

- Independent Show archived switches for all accounts and the combined inbox.
- Archived rows remain marked; Ctrl+E toggles archive without removing mixed rows.
- Alt+A, the palette command, the existing rounded button and its shortcut tooltip.
- Same-profile restart restores inbox and account preferences; archived-only stays separate.

## How to get to it (user POV)

Alt+I opens the combined inbox; Alt+1..9 opens an account. Alt+A toggles Show archived for that view. The search-header button uses the existing rounded Wazig button style and says Show archived: On/Off. Ctrl+K offers Toggle archived chats in this view, with Alt+A shown. Inbox mixed mode keeps only unread chats, normal and archived, by time. Account mixed mode retains its existing unread filter and includes archived chats. Ctrl+E unarchives an archived selection or archives a normal selection; both stay visible in mixed mode. Show archived chats remains the separate archived-only palette command.

## Driving it with PowerShell UI Automation

Run `feature=show-archived` on GitHub Windows Actions; the registry adds it to the PR workflow matrix. `ShowArchivedHandler` seeds two WhatsApp accounts, Slack, Telegram and Signal. Each has normal read/unread and archived read/unread rows. Probe requests (limit=20) supply synthetic unread timestamps; normal history is empty so automatic reading does not consume the unread filter fixture while navigating.

`show-archived.ps1` drives Alt+I, the unread command and Alt+A, records inbox-off and inbox-on, then hovers owned UIA button 1146 and reads its visible native tooltip. Each account is off independently before being enabled. All five accounts exercise Ctrl+E archive/unarchive on the normal read row, retaining counts, selection and archive labels. Account one remains enabled while all others are disabled. The journey checks the archived-only command, quits by keyboard and relaunches the exact same isolated profile. restart-inbox, restart-one and restart-two prove independent saved values. Screenshots, UIA, status and visible chat snapshots accompany every phase. The strict evidence checker is dispatched by check-evidence.py through journeys.json and has Python positive and mutation controls.

## Gotchas

The journey-only commit is red on the old app: Alt+A has no handler, button 1146 does not exist and include_archived is absent. No live provider accounts or real delivery are verified. Windows execution and screenshot inspection must happen on Actions, not locally. Telegram, Signal and Slack actions must have no archive endpoint writes; WhatsApp actions must send both archive and unarchive.
