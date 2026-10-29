@_exported import JinnieObjC
import Foundation

/// Runs `body`, turning an Objective-C exception into a thrown error. Use around AVAudioEngine calls that report
/// failures as exceptions (`installTap` with a format that no longer matches the hardware, `prepare`): uncaught, AppKit
/// swallows them mid-task and the next main-actor check crashes the app (see docs/LESSONS.md).
public func catchingObjCExceptions(_ body: () -> Void) throws {
    var failure: NSError?
    guard JRCatchException(body, &failure) else {
        throw failure ?? NSError(domain: "ObjCException", code: 0)
    }
}
