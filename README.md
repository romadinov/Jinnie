# Jinnie

Personal knowledge agent for Mac and iPhone. It reads email, Slack, calendars, Drive, client Outlook and your own notes. It
records who said what about which project, keeps next actions and waiting-fors in Uberdoer, maintains each project's
stakeholders, news and summary, and answers questions or carries out requests in Ask.
It runs on the Claude subscription through headless `claude -p`, so no API key is needed.

## How it works

```
 Mac app (menu bar, ⌃⌥J Quick Note)        iPhone app / Siri / Action button "Add Jinnie Note"
        │                                           │
        ▼                                           ▼
   SQLite (~/Library/Application Support/Jinnie) ◄──► CloudKit (iCloud.com.romadinov.jinnie, CKSyncEngine)
        │
        ├─ every 30 min, read-only:
        │    claude -p + claude.ai connectors: Gmail, Slack, Drive (1 h), Google Calendar (6 h); weekends every 4 h (Settings)
        │    Outlook on the web (client M365, e.g. Umbrella) via agent-browser: open + read, no clicks
        │    reMarkable Cloud via rmapi (find/get only) → rmc → PNG pages → Claude reads the handwriting (30 min)
        │    → structured extraction: items, facts, people, projects, actions, documents, directory updates
        ├─ notes, summary requests: within seconds · questions: own fast lane, in parallel
        ├─ summaries + stakeholders + news: new project → history scan; new activity → refresh (≤ every 2 h); daily
        └─ uberdoer-mcp (JSON-RPC, no LLM) ⇄ Uberdoer: tasks, projects in your work folder, status both ways in seconds
```

## Spec

### Knowledge
- **Items and attribution.** Every fact sits on an *item* (email thread, Slack thread, meeting, document, note) with its
  link, author and date. Summaries and answers cite those.
- **Identity is deterministic.** The model only names things; Jinnie resolves them. People are matched by email, then by
  full name or alias, then by a unique first name (ties go to the person on the same project). Projects are matched by
  name, alias or email domain. "Dana" → *Dana Fischer* on **Acme**. An unknown name is kept on the action and
  linked once that person is learned.
- **Notes teach the directory.** "Acme is part of Globex" adds Globex as an alias. A stated role, nickname or
  membership updates the person. A role change triggers a stakeholder and summary refresh for that project straight away.
- **Customers group projects.** One client organisation can have several projects. A new project names its customer
  when it is extracted; projects from before were grouped once by the model (`jinniectl customers --assign` re-runs it).
  Internal work has no customer. The Customers screen shows each customer's projects, news, actions, people and documents.
- **Contacts** are learned from 6 months of mail headers on the first run.
- **History.** Regular runs read only what is new. **Scan History** reads a project's last 6 months: threads with its
  names, domains and people, plus meetings, documents and Slack. A scan runs automatically before a summary if the last
  one is more than 6 hours old. `scan --full` re-reads everything. A scan never skips a thread where a number or date is
  set or revised. Commitments older than 30 days don't become tasks.
- **Figures age.** Every estimate, price, duration or date in a summary carries the date it was stated and its source.
  The newest wins, and older ones are shown as superseded. If the latest figures are in a document Jinnie hasn't read,
  the summary says so and links it.

### reMarkable (handwritten notes)
- **What**: every notebook written on since it was last read (first run: the last 30 days) is downloaded from reMarkable
  Cloud, each written page rendered to a PNG, and Claude reads the pages (Russian and English mixed, cursive,
  abbreviations; [?] for illegible words) with the directory as context, so "Maria" in an Initech meeting is Maria Chen.
- **Result**: one item per notebook with the full transcript (shown in the item, searchable), a summary and facts,
  people and projects, and actions (to-dos, "прислать…", "!"-marked lines → next actions; "X will send" → waiting).
  The meeting date comes from the notebook name (`YYYYMMDD - Topic`, also `DDMMYYYY`).
- **Cost**: about $0.10–0.25 per notebook; up to ~15 pages per `claude -p` call, which can only `Read` that run's images.
- **Safety**: rmapi can move and delete; Jinnie only runs `find` and `get`. Only notebooks are read (annotated PDFs and
  ebooks are skipped for now).
- **Setup** (once): `uv tool install rmc`; download rmapi from https://github.com/ddvk/rmapi/releases (macOS arm64 zip;
  `go install` doesn't work for this fork) into `~/.local/bin`; run `~/.local/bin/rmapi` and enter the code from
  https://my.remarkable.com/device/desktop/connect. `rsvg-convert` comes from `brew install librsvg`.

### Voice notes and meeting recordings
- **Voice notes**: 🎤 in Quick Note, the compose bars and Ask (⌘D), or **⌃⌥⇧J** for a Quick Note that starts listening.
  Whisper runs on the device (WhisperKit; on the Mac the large-v3 turbo model Uberdoer already downloaded), detects
  Russian or English, and stops after a 3-second pause. The menu on the mic switches to Apple's recogniser or fixes the
  language. A spoken question in Ask is sent when you stop talking.
- **Recordings** (Mac): **⌃⌥R**, the toolbar, or the menu bar starts and stops recording; File → Import Recording… takes any
  audio or video file (Zoom, Teams, Voice Memos). The microphone is saved as 16 kHz AAC (~15 MB per hour) in
  `recordings/`, so a quit or crash loses nothing. When you stop: Whisper transcribes with word timings, SpeakerKit (Argmax,
  pyannote) separates the speakers and fingerprints each voice, and the turns are aligned to speakers.
- **Voice learning**: a voice that matches someone's voiceprint (cosine ≥ 0.62 and clearly ahead of the next person) is named
  automatically; others show as "Speaker N" with what they said, a ▶︎ sample, likely names (meeting attendees, project
  people), and the agent's guess from the content ("Probably Dana: speaks for Acme…", one tap to confirm). Naming a
  voice stores it on the person (5 newest prints) and re-checks other recordings still waiting for names.
- **Knowledge**: the agent reads the speaker-attributed transcript like any source: one item (summary, facts by speaker,
  full transcript), actions ("You" → next; others' commitments → waiting), linked to the calendar meeting it overlaps.
  Renaming a speaker re-reads the transcript. Today shows **Who was speaking?** for recent recordings with unnamed voices.
- **Meetings record themselves** (Settings → Meetings: Off / Ask before recording (default) / Record automatically).
  When Zoom, Teams, Webex, Slack, FaceTime or a browser (Meet, Teams on the web) takes the microphone for 2 s during a
  calendar meeting, a small panel offers **Record / Not this one** (or says recording started), with **Copy notice for
  others** to paste in the meeting chat. A browser call that isn't in the calendar (yet) counts once the browser has been
  both listening and playing for 15 s; native call apps count without a calendar entry when "calendar only" is off. Detection reads Core Audio's process list (which app is capturing input). It
  stops 30 s after the call ends. Meetings whose title contains a word from the skip list are never recorded.
- **Other participants**: an online call is recorded on two tracks, the microphone and the meeting app's own audio
  (a Core Audio process tap of just that app, macOS asks once for "System Audio Recording"). The tracks are mixed for
  transcription and speaker separation, and the voice that's loud on the microphone but not in the app's audio is
  **you**: named automatically, and your voiceprint is learned from it. Manual recordings (⌃⌥R) include the call's
  audio too when a call is on.
- **Managing voices**: on a recording, **Who is this?** / **Change** names or corrects a speaker (likely names first:
  attendees, project people, the agent's guess). Correcting a voice match forgets the samples behind the wrong match
  and teaches the voice to the right person, then re-checks other recordings. Each person's page has a **Voice** panel:
  the samples Jinnie learned from (recording, ▶︎ play, Forget) and Forget voice. Ask can do it too ("Speaker 2 in this
  morning's call was Dana", `name_speaker`).
- **Not yet**: recording on the iPhone (it shows recordings and names speakers).

### Open questions
- **Jinnie asks when it isn't sure**: which side someone is on, whether one record mixes up two people (or two records
  are one person), which of two figures is current, who owns something when sources disagree. Questions are raised with
  each project brief (at most 3 open per project, never a repeat of one already asked or answered), each with *why* and
  2–4 one-tap answers.
- **Where**: Today → *Open questions* (Mac and iPhone; the iPhone's More tab shows a badge), the project page, and the
  Mac's *Questions* section, which also lists recent answers and what was changed.
- **Answers** (tap an option, type one, or ✕ to skip) are applied on the Mac in the fast lane: people are split, merged
  or corrected (`create_person`, `move_person_links`, `merge_people`, `remove_person_from_project`, `update_person`
  incl. `remove_emails`), stakeholders updated, and the answer is stored as a dated fact from you, so summaries cite it.
  The project's stakeholders and summary refresh straight away. A claim in the database (`applyingAt`) makes sure only
  one process applies an answer.

### Projects
- **Summary**: status, recent developments, decisions and key facts, key documents, my next actions, waiting on others,
  risks, key contacts and other people.
- **Stakeholders**: our team, customer and partners. Each has a project role and responsibilities; key people are marked
  ★, and former people show who replaced them. Generated from the knowledge base; the owner's notes override everything.
- **Latest news**: up to 10 dated headlines from the last 30 days, newest first, each linked to its source items. Items
  that change plans, money, dates or people are marked. Today shows **What's new** across all projects for the past week.
- **Documents**: everything linked from the project's items. Drive transcripts and Gemini notes are read in full once
  Drive is connected.
- **Freshness**: a newly learned project gets a history scan and a summary. New activity triggers a refresh at most every
  2 hours per project. Projects active in the last 30 days are refreshed daily. At most 3 refreshes per cycle; the toggle
  is in Settings.

### Actions and Uberdoer
- **Next** = something you do. **Waiting** = something someone owes you, titled `Person//What I need`. Both are tagged
  Jinnie (plus Waiting), filed in `<work folder> : <Project>`, with a due date when one was stated. New work projects are created
  under the work folder (Settings → Setup → "Uberdoer folder for work projects").
- **Task notes**: the source link, then `jinnie://action/<id>`, then 2–4 sentences of context written to you as "you",
  the exact quote, the person with role and org, project, due date, source and documents, and the `jinnie:<id>` marker.
  A note is rewritten only if its fingerprint shows you haven't edited it in Uberdoer.
- **Status both ways, within seconds**:
  - Completing, dropping or reopening a task in Uberdoer, on any device, updates Jinnie. Uberdoer posts
    `com.romadinov.uberdoer.changed`.
  - Doing the same in Jinnie, on the Mac or the iPhone, updates Uberdoer.
  - When Jinnie sees something delivered, it completes the action itself.
- **Links**: `uberdoer://task/<id>` opens the task in Uberdoer. `jinnie://action|item|project|person/<id>` and
  `jinnie://capture` (Quick Note) open Jinnie.

### Ask (Mac and iPhone)
- **Answers** come from the knowledge base first, then live Gmail, Slack, Calendar and Drive, with cited sources.
  Questions from the last 2 hours are passed along as context, so follow-ups like "add that as a task" work.
- **Requests are carried out, not explained**:
  - add a next or waiting action;
  - complete, drop or reopen an action;
  - correct a person or project, or set a project role ("Ravi replaces Lena as B2B Program Lead");
  - add a note;
  - act on non-Jinnie Uberdoer tasks.
- **Never writes to email, Slack or calendars.** Ask offers a task instead.
- **Fast lane**: questions run immediately, in parallel with background work (about 20–60 s).

### Apps
- **Mac**:
  - menu bar plus window;
  - **⌃⌥J** Quick Note: a floating panel over any app, ⌘↩ to save;
  - compose bars on Today and Notes; Dictation (🎤 / Fn Fn) works in every text field;
  - Settings for sources, Outlook sign-in, summaries and open-at-login.
- **iPhone**:
  - tabs: Notes, Actions, Projects, Ask, More (Today, People, Activity);
  - **Add Jinnie Note** App Intent for Siri, the Action button and Shortcuts;
  - keyboard: **Done** button, drag the list to dismiss; Return sends in Ask.
- **Uberdoer-style UI**:
  - rows expand in place under a › chevron (actions show context, quote, source and links; items show facts, excerpt,
    people, documents and actions);
  - sections collapse and the app remembers which;
  - **Done**: the circle fills with a check (red ring when overdue), the row stays struck through until **Clean Up** or
    you switch view; on iPhone, swipe right to complete or left to drop.

### Improvement notes and crash reports (self-improvement loop)
- **Suggest an Improvement…** (Mac: Help menu, ⇧⌘I, or the menu bar; iPhone: 💡 on the More tab) saves a note, typed or
  dictated, to iCloud Drive › Jinnie › `Improvement notes.md` (TaskPaper, with @date @where @build @device and an optional
  @screenshot taken before the sheet opened). Crashes, hangs and resource problems are saved by MetricKit to
  `Crash reports/` on the next launch.
- These follow the shared convention in `~/Dev/agent-feedback` (Jinnie is registered in its `apps.json`). A launchd router
  checks every 30 minutes and notifies you, naming the Claude session that has this repo open. That session lists them
  with `swift ~/Dev/agent-feedback/feedback.swift notes jinnie` / `crashes jinnie`, fixes, verifies, installs, and records
  them as handled. The app is the only writer of `Improvement notes.md`.
- Only in development-signed builds (`DeveloperBuild`: DEBUG, or get-task-allow in the signature / provisioning profile),
  i.e. your own installs. TestFlight and App Store builds hide the command and save no crash reports.

### Safety
- **Connector tools** are allow-listed by read verb (get, list, search, read…), and a tool is refused if any part of its
  name writes. Built-in tools are off (`--tools ToolSearch`), and everything else is refused (`--permission-mode dontAsk`).
- **Outlook** is read by a fixed script that only opens pages and reads them. It never clicks or types, so nothing is
  sent, moved or marked read.
- **Transcripts**: every `claude -p` run leaves one in `~/Library/Application Support/Jinnie/agent/traces` (the last 60).

## Install

**Mac** (macOS 15+, Apple silicon): download the latest `Jinnie-….dmg` from
[Releases](https://github.com/romadinov/Jinnie/releases), drag Jinnie to Applications and open it. **Set Up Jinnie** opens
and checks everything, with the exact steps for what's missing:

| | |
|---|---|
| **Required** | Your profile (name, email addresses, role, languages); [Claude Code](https://code.claude.com/docs/en/setup) signed in with a Claude Pro, Max, Team or Enterprise plan (Jinnie runs on your subscription); iCloud |
| **Recommended** | Gmail and Google Calendar connected at [claude.ai → Settings → Connectors](https://claude.ai/settings/connectors) |
| **Optional** | Slack and Google Drive connectors; Uberdoer; Outlook on the web for a client's Microsoft 365 (needs `agent-browser`); reMarkable (needs `rmapi`, `rmc`, `rsvg-convert`); voice (downloads a ~630 MB speech model) |

`jinniectl doctor --connectors` (Jinnie → Install Command-Line Tool… puts it on the PATH) runs the same checks in Terminal. Updates install from
the app (Jinnie → Check for Updates…; it also checks daily).

**iPhone**: through TestFlight (ask for an invitation). Use the same Apple Account as on the Mac; the agent runs on the
Mac, the iPhone shows everything and takes notes, voice notes and questions.

## Build from source

```sh
brew install xcodegen                 # once
scripts/install-mac.sh                # needs an Apple ID in Xcode → Settings → Accounts
scripts/install-iphone.sh             # iPhone connected or paired; open Jinnie once afterwards (iCloud registration)
```

Signing can also use an App Store Connect API key: `ASC_KEY_PATH=… ASC_KEY_ID=… ASC_ISSUER_ID=… scripts/install-*.sh`.
Releases (notarized Mac DMG with in-app updates, TestFlight for iPhone): [docs/RELEASING.md](docs/RELEASING.md).

## CLI and MCP

The app embeds `jinniectl` (Jinnie → Install Command-Line Tool… links it into /usr/local/bin), which is the same program as `swift run jinnie` in `Packages/JinnieCore`.

```sh
J=/Applications/Jinnie.app/Contents/MacOS/jinniectl
$J run --force                         # one cycle, all sources
$J ingest email|slack|calendar|drive|outlook|remarkable|notes
$J scan Acme 180 [--full]            # project history
$J summarize Acme · $J summaries [--dry-run] · $J stakeholders <project>|--all
$J ask "…" · $J note "…" · $J learn-contacts [days]
$J uberdoer [--enrich] · $J push · $J set-status <action> done|dropped|open
$J questions [all] · $J answer <id> <text>|--skip · $J raise <project> -- <question> · $J merge-people <keep> <merge>
$J outlook-login · $J outlook-peek · $J tools [--refresh]
$J recordings [--process] · $J remarkable-peek · $J remarkable [--since 2026-01-01] [--limit N] [--only <name>]   # backfill or one notebook
$J projects | people | actions | items
claude mcp add --scope user jinnie -- $J mcp      # the knowledge base (read + write tools) inside Claude Code
```

| Variable | Effect |
|---|---|
| `JINNIE_HOME=<dir>` | Use a scratch database |
| `TASKER_DB=<file>` | Point Uberdoer's MCP server at a test database (an empty file works). Required whenever `JINNIE_HOME` is set: without it Jinnie refuses to talk to Uberdoer |
| `JINNIE_NO_AGENT=1` | Start the app with the scheduler off |
| `JINNIE_MODEL` | Model for CLI runs |

iOS launch arguments for screenshots: `-initialTab projects|actions|…` and `-expandAll YES`. Mac: `-importAudio <file>`
processes an audio file as a recording (with `JINNIE_HOME`, `JINNIE_NO_AGENT=1`; a scratch `JINNIE_HOME` never syncs to iCloud).

## Layout

| Path | What |
|---|---|
| `Packages/JinnieCore/Sources/JinnieCore` | Entities (Project with Stakeholders and News, Person, Item, Action, Note, Question, RunLog), SQLite store + FTS5, CloudKit sync, name/project resolver |
| `Packages/JinnieCore/Sources/JinnieAgent` | `claude -p` runner, prompts and schemas, ingest/apply, history scans, summaries, stakeholders and news, Ask, Uberdoer client and sync, Outlook reader |
| `Packages/JinnieCore/Sources/jinnie` | CLI + stdio MCP server (read tools; write tools for Ask) |
| `App/Shared` | SwiftUI for both platforms (screens, expandable rows, panels) |
| `App/macOS` | Menu bar, hotkey and Quick Note panel, agent scheduler and lanes, settings |
| `App/iOS` | iPhone app, App Intent |
| `docs/LESSONS.md` | What we learned building it |

Tests: `cd Packages/JinnieCore && swift test` (resolver, apply, sync merge, read-only tool filter, summary schedule,
untouched-note detection).
