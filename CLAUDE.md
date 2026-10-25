# Jinnie — working notes for Claude

Spec: README.md. Lessons: docs/LESSONS.md (read it before changing the agent, sync, the Outlook reader or the panels).

## Build, install, test
- Core: `cd Packages/JinnieCore && swift build && swift test`. The CLI is `.build/debug/jinnie`.
- Apps: `xcodegen generate`, then `scripts/install-mac.sh` and `scripts/install-iphone.sh` (signed, needs the Apple ID in
  Xcode). Run xcodebuild outside the sandbox. Install the Mac app by `pkill -x Jinnie`, then `ditto` into /Applications.
- Compile-only check: `xcodebuild … CODE_SIGNING_ALLOWED=NO` (iOS: `-destination 'generic/platform=iOS Simulator'`).
- **Never test against the user's real data or Uberdoer.** Use `JINNIE_HOME=<scratchpad>/jh` and
  `TASKER_DB=<scratchpad>/ud-test/tasker.sqlite`. Copying Uberdoer's real database is (rightly) blocked.
- UI checks: iOS Simulator with `SIMCTL_CHILD_JINNIE_HOME=…`, `-initialTab <tab>`, `-expandAll YES`, then
  `xcrun simctl io <sim> screenshot`. Mac screenshots and accessibility are unavailable; use `CGWindowListCopyWindowInfo`,
  crash reports, and `open jinnie://capture` or `jinnie://action/<id>`.

- reMarkable: `jinniectl remarkable --only "<notebook name>"` on a scratch copy (`sqlite3 <db> ".backup <scratch>/jinnie.sqlite"`)
  with `JINNIE_HOME` + `TASKER_DB` set. Never `run` on scratch data; the Uberdoer client refuses without `TASKER_DB` anyway.

## Feedback from the apps
- `swift ~/Dev/agent-feedback/feedback.swift notes jinnie` and `crashes jinnie` list improvement notes and crash reports
  written by the apps (iCloud Drive › Jinnie). Look at screenshots, fix, verify, install, then record:
  `notes jinnie "<text in note>" "<fix>"` / `crashes jinnie --mark "<file>"`. Never edit `Improvement notes.md` yourself.
- Raise `CURRENT_PROJECT_VERSION` in project.yml when a build should be distinguishable in notes (`@build`).

## Conventions
- The model names things; `Directory` resolves identity. Add new extraction fields to `Prompts.extractionSchema` **and**
  `Agent.apply`.
- New entity fields must be **optional** (`Codable` without defaults on decode; older records must still decode on every
  device).
- `claude -p` calls go through `Claude.run`. Connector tools only via `Agent.tools(for:)`, which returns read-only names
  (allow-list). External systems stay read-only; Ask writes only Jinnie data and Uberdoer.
- Uberdoer only through `uberdoer-mcp` (`Uberdoer.swift`). Keep the `jinnie:<id>` marker and the note-hash rule.
  Status changes made in Jinnie set `needsPush`.
- Text written for the user: refer to people by name or "they"; address the owner as "you". Never infer pronouns.
- UI follows Uberdoer: chevron disclosure, rows that expand in place, collapsible `Panel` sections, Done stays until Clean Up.
  For how Uberdoer does something, read `~/Dev/tasker/App/Shared`, or ask its Claude session ("tasker-04"; the user lets
  Jinnie request Uberdoer changes directly).
- After changing prompts or the schema, re-run on scratch data and read the transcript in `agent/traces`.
