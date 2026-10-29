import Foundation

/// Where a recording's audio lives. Calls are recorded as ADTS AAC (.aac): every frame carries its own header, so a file
/// cut off by a crash still plays up to the last frame. Older recordings and imports are .m4a.
public enum RecordingFiles {
    /// The file to record into.
    public static func recordingURL(in folder: URL, _ name: String) -> URL { folder.appendingPathComponent("\(name).aac") }

    /// The existing file for a recording (.aac, else .m4a); the .m4a path when neither exists yet (imports write there).
    public static func url(in folder: URL, _ name: String) -> URL {
        let aac = recordingURL(in: folder, name)
        return FileManager.default.fileExists(atPath: aac.path) ? aac : folder.appendingPathComponent("\(name).m4a")
    }
}
