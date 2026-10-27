import Foundation
import JinnieAgent
import JinnieCore
import Observation
import WhisperKit

/// Records the audio of a Teams recording shared with the owner by playing it, muted, in Jinnie's hidden browser (the
/// file itself can't be downloaded), then transcribes it with Whisper on the Mac. The Teams transcript stays the main
/// one; the Mac's own transcript sits beside it, with speakers taken from Teams at the same moment.
@MainActor @Observable
final class TeamsAudio {
    static let shared = TeamsAudio()

    /// The recording being captured or transcribed, and how far (0…1).
    private(set) var working: String?
    private(set) var phase = ""
    private(set) var progress = 0.0
    /// Read from the capture thread; a plain flag is enough.
    nonisolated(unsafe) static var stopRequested = false

    /// Starts the next requested capture, if nothing else is using the browser or the transcriber.
    func checkRequests(agent: Agent) {
        guard working == nil, !MeetingRecorder.shared.isBusy else { return }
        let store = agent.store
        guard let rec = store.all(Recording.self).filter({ $0.isExternal && $0.audioPending && $0.sourceURL != nil })
            .sorted(by: { ($0.audioRequestedAt ?? .distantPast) < ($1.audioRequestedAt ?? .distantPast) }).first else { return }
        start(rec, agent: agent)
    }

    func stop() { TeamsAudio.stopRequested = true }

    private func start(_ rec: Recording, agent: Agent) {
        working = rec.id
        phase = "Recording audio from Stream"
        progress = 0
        TeamsAudio.stopRequested = false
        let store = agent.store
        let output = MeetingRecorder.audioURL(rec.id)
        let folder = MeetingRecorder.folder
        // The browser is ours for the meeting's length plus a margin; Outlook reads wait.
        agent.browserBusyUntil = Date().addingTimeInterval(rec.duration + 600)
        Task.detached {
            var failure: String?
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try OutlookReader().captureAudio(playerURL: rec.sourceURL ?? "", duration: rec.duration, to: output) { p in
                    Task { @MainActor in TeamsAudio.shared.progress = p }
                    return !TeamsAudio.stopRequested
                }
            } catch { failure = "\(error)" }
            agent.browserBusyUntil = nil
            if failure == nil {
                await MainActor.run { TeamsAudio.shared.phase = "Transcribing on the Mac"; TeamsAudio.shared.progress = 0 }
                do { try await TeamsAudio.transcribe(rec.id, audio: output, store: store) } catch { failure = "Transcription failed: \(error.localizedDescription)" }
            } else {
                try? FileManager.default.removeItem(at: output)
            }
            var fresh = store.get(Recording.self, rec.id) ?? rec
            fresh.audioAt = Date()
            fresh.audioError = failure
            store.save(fresh)
            await MainActor.run {
                TeamsAudio.shared.working = nil
                TeamsAudio.shared.phase = ""
                AgentHooks.shared?.runNow()
            }
        }
    }

    /// Whisper on the captured audio; each segment gets the Teams speaker talking at that moment.
    nonisolated static func transcribe(_ id: String, audio: URL, store: Store) async throws {
        let path = audio.path
        let samples = try await Task.detached { try AudioProcessor.loadAudioAsFloatArray(fromPath: path) }.value
        guard samples.count > 16000 else { throw NoSound() }
        let results = try await WhisperModel.shared.transcribeLong(samples) { p in
            Task { @MainActor in TeamsAudio.shared.progress = p }
        }
        guard var rec = store.get(Recording.self, id) else { return }
        let teams = rec.segments
        var local = results.flatMap(\.segments).map {
            RecordedSegment(speaker: nil, start: Double($0.start), end: Double($0.end), text: Recording.withoutHallucinations($0.text))
        }.filter { !$0.text.isEmpty }
        for i in local.indices { local[i].speaker = speaker(at: local[i], in: teams) }
        for c in await AppModel.shared.rememberedCorrections {
            for i in local.indices { local[i].text = Recording.replacing(local[i].text, c.from, c.to).0 }
        }
        rec.localSegments = local
        store.save(rec)
    }

    struct NoSound: LocalizedError { var errorDescription: String? { "The recorded audio had no sound" } }

    /// The Teams speaker who talks most during a segment (Teams timestamps are per line, so lines are stretched to the next one).
    nonisolated static func speaker(at seg: RecordedSegment, in teams: [RecordedSegment]) -> Int? {
        var talk: [Int: Double] = [:]
        for t in teams {
            guard let s = t.speaker else { continue }
            let overlap = min(seg.end, t.end) - max(seg.start, t.start)
            if overlap > 0 { talk[s, default: 0] += overlap }
        }
        if let best = talk.max(by: { $0.value < $1.value }) { return best.key }
        // No overlap (a gap in the Teams lines): whoever spoke last before it.
        return teams.last(where: { $0.start <= seg.start })?.speaker
    }
}
