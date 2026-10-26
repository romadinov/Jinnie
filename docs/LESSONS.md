# Lessons learnt

Things that cost time building Jinnie, and what to do instead.

## Headless Claude (`claude -p`)
- **claude.ai connectors attach after start-up and are deferred.** The model can only reach them through ToolSearch.
  `--tools ""` removes ToolSearch, and with it every connector; use `--tools ToolSearch`. `--strict-mcp-config` drops the
  connectors as well. The stream-json `init` message lists only local MCP servers, so an empty list there doesn't mean the
  connectors are missing.
- **A signed-out connector looks like a quiet inbox.** claude.ai keeps listing it, ToolSearch answers "No matching deferred
  tools found", and the run returns 0 items with no error. Jinnie fails any run that needed connector tools, used none and
  got that answer, so the source shows as signed out (it went unnoticed for hours on 2026-10-26).
- **Discover connector tool names at runtime and filter by an allow-list of read verbs.** A deny-list of write verbs
  leaked `unlabel_*`, `untrash_*` and `unmark_*`.
- **`--json-schema` returns the result in `structured_output`.** Use stream-json and save every run as a transcript.
  That is how "0 items" was debugged (the threads were read and were all notifications).
- **Remove `ANTHROPIC_API_KEY` from the child environment** so every run is billed to the subscription.

## Data and extraction
- **The model names, code resolves.** Give the model a directory (projects, aliases, domains, people) and resolve
  identity deterministically. Never create a person from a bare unknown first name; keep the mention and link it later.
- **A 7-day backfill knows nothing about a project.** A per-project history scan (6 months, by names, domains and people)
  is what made Acme, Initech and the other projects useful.
- **Figures age.** A June estimate was shown as current because a July re-plan was in a thread the scan skipped.
  Store every version of a number as its own dated fact, prefer the newest, and say when the real figures are in an
  unread document.
- **The owner's statements override inference.** "X replaces Y as …" must update both people and the project's
  stakeholder map at once, not wait for the daily refresh.
- **Questions are a conversation.** Pass the recent Q&A so that "follow up with him" or "add that as a task" works.
- **Users ask Jinnie to do things.** A read-only Ask frustrated the user ("add a task to follow up with Sam"). Give Ask
  write tools for Jinnie's own data and route task creation through Jinnie actions, so tasks get context and links.
- **First-name matching merged two people.** "Maria Chen" (Salesforce) resolved to the only Maria then known, a school
  contact, and their emails and projects were mixed. A full name must agree on the surname, and a one-word alias is
  only a first name (it goes through the project tie-break).
- **Let the owner validate instead of guessing.** Open questions with one-tap answers settle what no source can (who is
  who, which figure is current). The answer is applied by an agent with structural tools (split, merge, move links)
  and kept as a dated fact. Give the agent tools to *remove* wrong data too (emails, aliases, notes); without them it
  could only report what was still wrong.
- **Pronouns.** The model guessed "he/his" for people and for the owner. Tell it to use names or "they", and to address
  the owner as "you" in task context and news.

## Uberdoer integration
- **Ask the other app's agent, through a Claude session on the same machine.** Uberdoer's session answered with the
  exact write path (its MCP binary over JSON-RPC, no LLM), conventions (the Waiting tag already exists) and pitfalls
  (never write its CRDT SQLite directly). Later it shipped a change notification and a task URL on request.
- **Idempotency without an external-id field**: a `jinnie:<id>` marker in the note, looked up before creating.
  Detect changes by comparing the task's `changed` timestamp.
- **Avoid sync ping-pong.** Use an explicit `needsPush` flag for Jinnie-side status changes, and briefly ignore the other
  app's echo after Jinnie's own writes.
- **Never overwrite a note the user edited.** Fingerprint what Jinnie wrote; for older notes, accept only the known
  structural format.
- **Create tasks with `literal: true`.** Otherwise Uberdoer parses quick-entry shorthand in titles, so "Send #2 estimate"
  would gain a tag. Also pass `external_ref: "jinnie:<id>"`, which makes creation idempotent on Uberdoer's side too.
- **Test against `TASKER_DB=<empty file>`**, never the user's task database. A scratch `jinnie run` without it nearly
  synced scratch actions into the real Uberdoer (stopped before the sync step). Now `Uberdoer()` refuses to start when
  `JINNIE_HOME` is set without `TASKER_DB`. For a single step, use the single-step command (`answer`, `summarize`), not `run`.

## Apple platform
- **Case-insensitive APFS**: an embedded CLI called `jinnie` overwrote the app binary `Jinnie` in `Contents/MacOS`.
  Name it `jinniectl`.
- **Signing**: xcodebuild says "No Accounts" until an Apple ID is added in Xcode → Settings → Accounts. Xcode writes the
  account to disk only after it quits. A new iCloud container returns CloudKit "not authenticated" (internal error 1014)
  for a few minutes after it is created, then works.
- **A SwiftUI TextEditor inside a List row on macOS doesn't take keyboard focus.** Use a compose bar pinned with
  `safeAreaInset`.
- **`NSHostingController.sizingOptions = .preferredContentSize` on a panel containing a TextEditor** caused a layout loop
  that AppKit ended with "too many layout passes", crashing on ⌃⌥J. Give such panels a fixed size.
- **iPhone keyboard**: add a keyboard-toolbar Done button and `scrollDismissesKeyboard`. A vertical TextField inserts a
  newline on Return, so convert it to Send where single-line behaviour is wanted.
- **Serial agent queues starve questions.** One lane for long work (ingest, scans, summaries) and a separate, parallel
  lane for questions.
- **Per-process locks don't protect shared data.** The CLI and the app both applied the same answer (the MCP writes
  wake the app) and created a duplicate person. Claim work in the database (`applyingAt`), not in memory.
- **Verification without screen access**: iOS Simulator screenshots with launch arguments (`-initialTab`, `-expandAll`)
  on a scratch `JINNIE_HOME`; `CGWindowListCopyWindowInfo` for window presence and size; crash reports in
  `~/Library/Logs/DiagnosticReports`; `jinnie://` URLs to drive the app.

## Microsoft 365 / Outlook
- **The claude.ai Microsoft 365 connector needs the tenant's Entra Global Administrator**, which isn't realistic for a
  client tenant (Umbrella).
- **New Outlook for Mac exposes no account data to AppleScript**: only the empty "On My Computer" folders. The first
  probe timed out because a permission prompt was waiting.
- **Outlook on the web in a dedicated agent-browser profile works**: open and snapshot only, never clicks, so nothing is
  marked as read. It ignores dates in calendar URLs, so use the month view. Reading the web app's MSAL token was
  (rightly) blocked as credential access: don't go there.

## reMarkable
- **Use the maintained rmapi fork (ddvk)**; the original is archived. `go install …@latest` fails on its replace
  directives, so use the release binary. Sign-in is a one-time code typed into rmapi, so the user does it in a Terminal.
- **Render, then let Claude read the images.** rmc (v6 `.rm` → SVG) + rsvg-convert → PNG, and a `claude -p` call with
  only the `Read` tool, allowed for that run's folder (`--tools Read --allowedTools "Read(//<dir>/**)"`). Transcribing
  and extracting in one call, with the directory in the prompt, reads names far better than plain OCR would.
- **Installing third-party tools is the user's call**: the agent's install was (rightly) blocked; give the commands.

## Voice
- **SpeakerKit (in WhisperKit's package) covers separation and voice learning**: `diarize` gives segments and per-speaker
  centroid embeddings, `addSpeakerInfo(to:)` aligns Whisper's word timings. No second vendor needed (FluidAudio was the
  alternative).
- **A Whisper prompt (vocabulary) broke word timings and dropped sentences.** Found by comparing with `whisperkit-cli`
  (`swift build --product whisperkit-cli` in the checkout) using the same model: without the prompt it was right. Let the
  agent fix names from the directory instead.
- **Calibrate on real voices, not TTS.** `say` voices gave nonsense similarities (the same voice 0.16 apart). Real speech
  (two halves of a TED talk vs JFK) gave 0.90 same-speaker vs −0.06 different, so the 0.62 threshold has a wide margin.
- **Reuse the other app's model**: Uberdoer had already downloaded the 632 MB Whisper model; Jinnie loads it from there.
- **Global hotkeys collide across your own apps**: ⌃⌥V was Uberdoer's, so Jinnie uses ⌃⌥⇧J and ⌃⌥R.
- **A scratch app instance must not sync**: a second app on `JINNIE_HOME` would have pushed scratch data into the user's
  iCloud. `JINNIE_HOME` now disables CloudKit, as it disables Uberdoer.
- **Test every JSON schema string** (`schemasAreValidJSON`): an escaped quote inside a Swift multi-line string made the
  extraction schema invalid, which would have stopped every ingest.

## Meeting capture
- **Follow AudioCap for Core Audio process taps** (github.com/insidegui/AudioCap, BSD): `CATapDescription` →
  `AudioHardwareCreateProcessTap` → private aggregate device with the tap → IO proc. Without
  `NSAudioCaptureUsageDescription` every call succeeds and every buffer is silence.
- **Which app is in a call**: `kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningInput`.
  FaceTime's audio runs in `com.apple.avconferenced`; Safari's in `com.apple.WebKit.GPU`; System Settings' Sound pane
  shows as an input user too (ignore non-meeting apps).
- **Two tracks identify the owner**: loud on the microphone, quiet in the app's audio. Only with app audio: in a room
  everyone is on the microphone (a test caught the mic-only case naming the loudest person "you").
- **Undo wrong voice matches at the source**: renaming alone left the bad sample on the wrong person; forget the samples
  similar to the corrected voice, keep provenance (recording, speaker) for every sample.

- WhisperKit/Hub default to `~/Documents/huggingface` for the tokenizer. Reading Documents triggers a macOS permission
  prompt (again after every re-signed build) and `open()` blocks until it is answered: recordings sat in "processing"
  with 0% CPU. Always pass `tokenizerFolder` (and `downloadBase`) inside Application Support.
- Never query Core Audio on the main thread in a poll: each property read is a round trip to coreaudiod (~80 ms per
  detector tick here). The detector reads processes on a background queue and hands the snapshot to the main actor.

- Drive: "look through Drive and open what matters" opened 5 of ~50 new decks and sheets. Jinnie now lets the model only
  page through `search_files` and reads the file list from the tool results in the transcript (having the model copy out
  200 files took 6 minutes and $1.25, and Haiku timed out writing a table instead). Pages of 100 exceed the MCP result
  limit (saved to a file instead); Haiku garbles long page tokens. Jinnie picks unread or changed files itself, reads them
  12 per call, logs every file opened, and fails the sync if the listing didn't reach the last page.
- agent-browser `--session-name` saves cookies only on `close`: a sign-in in a window left open was lost when the next
  read started a new browser. Outlook uses a persistent `--profile` (Application Support/Jinnie/outlook-browser), and
  sign-in ends with an explicit "I've signed in" that closes the window and checks the mailbox opens.
- Mac sidebar: on macOS 27 `NavigationSplitView` with `List(selection:)` highlighted rows but the detail never changed
  (`NavigationLink(value:)` and `.id(selection)` didn't help). Like Uberdoer, use a plain column of buttons that set the
  section, beside a `NavigationStack(path:).id(section)`; no NavigationSplitView on the Mac.

## Process
- **Search before theorising.** The `-p` connector behaviour, the Microsoft 365 requirements and Outlook's scripting
  limits were all settled faster by searching and probing than by guessing.
- **Look for a working precedent first.** Uberdoer's CloudKit sync, hotkey panel, signing scripts and MCP server were
  copied rather than reinvented.
- **When a feature looks wrong to the user, read the data and the traces first.** "Not found in email" was a 7-day
  backfill. "Not reflected on the project" was a missing stakeholder concept. "Old estimate" was an unread revision.
