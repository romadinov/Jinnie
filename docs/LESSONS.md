# Lessons learnt

Things that cost time building Jinnie, and what to do instead.

## Headless Claude (`claude -p`)
- **claude.ai connectors attach after start-up and are deferred.** The model can only reach them through ToolSearch.
  `--tools ""` removes ToolSearch, and with it every connector; use `--tools ToolSearch`. `--strict-mcp-config` drops the
  connectors as well. The stream-json `init` message lists only local MCP servers, so an empty list there doesn't mean the
  connectors are missing.
- **Connectors belong to the claude.ai account Claude Code is signed into.** On 2026-10-26 Claude Code got signed in as
  a shared team account; every connector then looked signed out to Jinnie. Setup shows the Claude Code account and each
  connector's account ("Connected as …"), and warns when Claude Code isn't signed in as the owner.
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

## Teams recordings shared with the owner: read the transcript, not the audio
- SharePoint search (`/_api/search/query`, run with `fetch` inside the signed-in browser page) lists the recordings the owner
  can open: `filetype:mp4 path:https://<tenant>-my.sharepoint.com` = files in colleagues' OneDrive shared through Teams chats.
  The tenant comes from where stream.office.com redirects. `Created` is the recording start; `MediaDuration` is in seconds.
- Download is blocked for non-organisers (403), and the player's DASH stream is AES-encrypted with a separately served key.
  Don't decrypt it: that circumvents the tenant's protection. The player's transcript pane (speaker, time, text) is readable
  by anyone who can watch; it is virtualised, so collect rendered entries and scroll until nothing new appears (~2.5 min/hour).
- Google Meet recordings organised by another company (e.g. a vendor) live in their Drive and are usually not visible to
  the owner's account at all, even as an invited guest.
- `OutlookReader.profileDirectory` follows `JINNIE_HOME`. A scratch run starts the shared `jinnie-outlook` daemon with an
  empty profile if the real one isn't running, and Jinnie's Outlook reads then fail until `agent-browser --session
  jinnie-outlook close`. For scratch tests, symlink `<scratch>/outlook-browser` to the real profile.
- Audio of a shared Teams recording: play it in the hidden browser and record the `<video>` element with
  `captureStream()` + `MediaRecorder` (opus/webm), pulled out in base64 chunks by `eval`. This records what the player
  outputs; nothing is decrypted. It works muted (`v.muted = true` still feeds captureStream), so nothing is audible and
  a live meeting recording can't pick it up. `play()` needs a user gesture: `agent-browser click video` first.
  Pause the recorder on the video's `waiting` event so the audio stays on the meeting's clock. When the video ends, the
  page resets and `window` state is gone: pull every 2 s near the end and keep what was captured. Real time only, and
  Outlook reads must wait (`browser.busyUntil`): both use the one `jinnie-outlook` browser.

## Meeting notes by email, and Contacts
- Jinnie never sends mail. "Send Meeting Notes" opens a filled-in draft: a `mailto:` URL opened with Mimestream
  (`com.mimestream.Mimestream` registers `mailto`) via `NSWorkspace.open(_:withApplicationAt:)`, else the default mail app.
  Percent-encode everything but unreserved characters, with line breaks as `%0D%0A` (RFC 6068). Round-trip tested
  with `&`, `#`, quotes and Cyrillic.
- Contacts fill blanks only (emails, organisation, job title), matched by email, then by a unique exact full name. Never
  overwrite. "Add to Contacts" is the only write, and only on request.

## Russian meetings: what was tested (Oct 2026, a 1-hour Russian call with English terms)
- On the same 10-minute excerpt: Whisper large-v3 turbo with language detection (Jinnie's setup) was the most faithful.
  Forcing `language: "ru"` (turbo or full large-v3) left empty stretches, and large-v3 invented sentences. Parakeet v3
  (FluidAudio) was 5x faster but garbled fast or overlapping speech and English terms ("ременью Cloud"). Don't switch
  engines or force the language without re-running this comparison.
- The real loss was Whisper skipping windows of a long recording it judged silent: 39 s of speech in one place, 8% of
  the text overall. `transcribeLong` now re-transcribes gaps of 8 s or more that contain at least 3 s of speech.
- SpeakerKit's `addSpeakerInfo` skips segments without word timings. Those were empty in the test, but watch for it.
- Speaker separation can turn scattered "угу / okay / Thank you" into an extra voice: `absorbMinorSpeakers` folds in
  voices under 15 s of speech. Whisper can loop on one word ("клоджик-клоджик-…"): collapsed in `withoutHallucinations`.

## Outlook on the web shows the mailbox's time zone, not the Mac's
- A client tenant's mailbox can be set to its own zone (e.g. New Zealand, 2 h ahead of Sydney). Event labels read
  "11:30 AM … Wednesday, October 28" in that zone; Jinnie stored them as local time, so meetings looked 2 h late and a
  recording was matched to the wrong meeting. `Intl` in the page gives the browser's zone (useless here).
- The calendar's main region is labelled "calendar view, current time: Wed 1:39 PM": its difference from now is the
  shift. `OutlookReader.events()` converts every event line to local time before the model sees it.
- Mail list times are in that zone too (not converted yet).
- Checking a day view isn't enough to say "not on the calendar": it scrolls to now and hides earlier events from the
  accessibility tree. Read the week view.

## Call audio saved at half its real rate (27–28 Oct 2026): check track lengths first
- Every call track (`<id>-meeting.m4a`) from 27 Oct on was exactly half as long as its microphone track: the tap's
  declared format didn't match what arrived, so the call side played twice as fast and drifted from the microphone
  (13 min apart by the end of a 27-min call). Mixed with the mic, that gave hallucinations, phantom or wrong speakers,
  "sped-up" voice samples, and much of what looked like poor Russian transcription. The cause wasn't found (no code
  change in the path); `TapWriter` now measures the real arrival rate over the first 3 s and uses it.
- Repair: `ffmpeg -i X-meeting.m4a -af asetrate=8000,aresample=16000` restores length and sync (verified: the two
  sides then form a conversation). Originals kept in `recordings/half-rate-originals/`.
- Before judging transcription quality, compare the two tracks' durations. The Russian engine bake-off and the gap
  recovery tuning above were done on such a distorted recording: re-check them on a healthy one.
- Write repaired audio with Apple's encoder: `ffmpeg … -c:a pcm_s16le x.wav && afconvert -f m4af -d aac -b 32000 x.wav
  x.m4a`. AAC m4a files written by ffmpeg could not be read by AVAudioFile/WhisperKit ("Failed to read audio file"), and
  the recorder used to treat an unreadable call file as "no call audio": that silently transcribed calls from the
  microphone only and, through the "nobody else spoke" rule, deleted two recordings (restored from Time Machine).
  An unreadable call file is now an error. Always load-test a rewritten audio file before swapping it in.

## Russian engine comparison, redone on clean audio (28 Oct 2026)
- The first comparison above ran on a meeting whose call track was at half rate: ignore its conclusions. On the repaired
  meetings (24 s excerpts, both sides, two meetings): Whisper large-v3 turbo and full large-v3 were nearly identical and
  good; full large-v3 slightly better on a few words and punctuation (2–3× slower). Parakeet v3 was fastest but made more
  errors on conversational Russian ("по ЮА" for "по UI"). Turbo stays the default; full large-v3 is a Settings choice.

## GigaAM for Russian (sherpa-onnx)
- On the owner's Russian meetings GigaAM v3 got the words Whisper guessed ("Как вчера прошло?", "надо поговорить",
  "я делала") and wrote proper punctuation and ё, at about 1 s per 24 s on the CPU; it mangles English words
  ("проджект-менеджерам", "Contract Velve"). So Whisper transcribes first and `GigaAM.refine` re-reads only mostly
  Cyrillic stretches (one speaker, up to 20 s), each speaker from their own track on a call.
- Packaging: official sherpa-onnx static macOS arm64 "no-tts" libraries + `c-api.h` (pinned SHA-256), linked through a
  bridging header; model `sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16` (MIT, ~225 MB int8)
  downloaded in the app on first use. Python/PyTorch (what the GigaAM repo ships) is not shippable.
- The sherpa C types are opaque in Swift (`OpaquePointer`); config strings must stay alive until the recognizer exists.

- **Mac List rows: no ViewThatFits, no growing text fields.** In a macOS `List` (an NSTableView underneath), `ViewThatFits`
  measures each alternative on every pass, and a `TextField(axis: .vertical)` changes the row's height without the table
  noticing. Together they made the Questions page lag and draw rows over each other. Use a `Layout` (`FlowLayout`) for
  wrapping buttons, single-line fields on the Mac, and long secondary text with `.fixedSize(horizontal: false, vertical: true)`.
