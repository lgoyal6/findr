# findr

Spotlight finds my config files before my PDF. findr is the file search I actually wanted.

Press **⌘⇧Space**, type what you'd say, and get two sections:

- **Name**: files whose name matches, best match first
- **Inside**: files that contain the word, with the line and the PDF page it's on

```
pace pdf                   PDFs named or containing "pace"
notes doc this week        documents from this week
screenshot today           today's screenshots
invoice in downloads       only look in Downloads
voltare                    still finds Voltaire.pdf (typos are fine)
```

No syntax to learn. No `kind:pdf`, no `name:`, no Finder filter rows.

## What it does

**Search**
- Name matches on top, contents matches below, in one bar
- Type words: `pdf`, `doc`, `slides`, `sheet`, `image`, `video`, `code`
- Date words: `today`, `yesterday`, `this week`, `last week`, `this month`, `last month`, `this year`
- Folder words: `in downloads`, `in desktop`, `in documents`, `in pictures`, `in movies`, `in music`
- If a type or date word filters everything out, findr searches the words as plain text instead
- Forgiving names: `pace forward` finds `Pace_Forward.pdf`, `voltare` finds `Voltaire.pdf`
- Ranking inside each section: how well the name matches, documents before code, files you opened from findr before, then most recent (last opened, added or modified)
- Skips hidden folders, `~/Library`, `node_modules`, the Go module cache and the insides of app bundles, plus any folders you add
- Files that just landed in Downloads or Desktop show up before Spotlight has indexed them
- If Spotlight returns nothing at all (it happens on Tahoe), findr scans your files by name directly

**Results**
- Where the word is inside: a short line around it, and the page number for PDFs
- Copies like `report.pdf` and `report (1).pdf` collapse into one row
- A tag on every row says why it matched: `name`, `name · typo`, `inside p.3`, `pdf · last week`
- File icon, highlighted name, folder and date

**Keys**

| Key | Action |
|---|---|
| ↵ | Open |
| ⌘↵ | Show in Finder |
| ⌘Y, or Space once you've arrowed into the list | Preview (PDFs open at the matching page, word highlighted) |
| ⌘C (in the list) | Copy the file |
| ⌘⇧C | Copy the path |
| ⌘O | Open with another app |
| ↑ in an empty bar | Previous searches |
| Esc | Close preview, then close findr |

You can also drag a result straight into Mail, Slack or a browser upload box.

**App**
- Lives in the menu bar, no Dock icon
- Settings: change the shortcut, folders to skip, launch at login, light or dark
- Uses the Spotlight index your Mac already keeps, so there's no indexing and no background CPU

## Install

1. Download `findr.dmg` from [Releases](../../releases) and drag findr to Applications.
2. The app isn't notarized, so the first time, right-click findr and choose **Open**.
3. Press ⌘⇧Space. macOS will ask once each for Downloads, Desktop and Documents; findr needs those to read new files and show where a word appears.

Requires macOS 14 or later.

## Build from source

```bash
git clone https://github.com/lgoyal6/findr && cd findr
swift test
./scripts/bundle.sh        # makes dist/findr.app and dist/findr.dmg
```

Check ranking from a terminal without opening the panel:

```bash
dist/findr.app/Contents/MacOS/findr --query "pace pdf"
```

## How it works

- `Sources/FindrCore`: the query parser, name matching, ranking, duplicate collapsing and junk filter. Plain Swift with unit tests.
- `Sources/Findr`: the app. Spotlight queries run in-process through `MDQuery`, alongside a direct read of Downloads and Desktop. The panel is SwiftUI in a non-activating `NSPanel`, so the app you were in stays in front. The shortcut uses Carbon's `RegisterEventHotKey`, which needs no Accessibility permission.

findr keeps your search history and which files you opened in `~/Library/Application Support/findr/state.json`. Nothing leaves your Mac.

## License

MIT
