import Foundation
import JinnieCore

/// Teams meeting recordings shared with the owner (in a Teams chat), read through the same signed-in browser as Outlook.
///
/// Recordings live in the organiser's OneDrive; SharePoint search lists the ones the owner can open. Downloading them is
/// usually blocked for anyone but the organiser, and the player's stream is encrypted, so Jinnie reads the transcript Teams
/// made instead: the player shows it to anyone who can watch, with speaker names. Read-only: no clicks other than opening the
/// transcript pane, and scrolling it.
public struct TeamsRecording: Sendable, Hashable {
    public var id: String
    public var title: String
    public var start: Date
    public var duration: Double
    /// The video file (percent-encoded), and the OneDrive it lives in.
    public var fileURL: String
    public var webURL: String

    /// The Stream player page for this recording.
    public var playerURL: String {
        let path = URL(string: fileURL)?.path ?? ""
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? path
        return "\(webURL)/_layouts/15/stream.aspx?id=\(encoded)"
    }
}

public struct TeamsTranscriptLine: Codable, Sendable, Hashable {
    /// Seconds from the start, the speaker as Teams names them, and what they said.
    public var t: Double
    public var s: String
    public var x: String
}

extension OutlookReader {
    /// Runs JavaScript in the current page and returns its (string) result.
    func eval(_ js: String, timeout: TimeInterval = 60) throws -> String {
        let out = try browser(["eval", js], timeout: timeout)
        let line = out.split(separator: "\n").map(String.init).last { $0.hasPrefix("\"") } ?? out
        return (try? JSONDecoder().decode(String.self, from: Data(line.utf8))) ?? line
    }

    /// The organisation's SharePoint (https://contoso.sharepoint.com): where Stream sends a signed-in user.
    func sharePointRoot() throws -> URL {
        try open("https://stream.office.com/")
        let current = try browser(["get", "url"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: current.split(separator: "\n").last.map(String.init) ?? ""), let host = u.host,
              host.hasSuffix(".sharepoint.com") else { throw ClaudeError(message: "Stream didn't open SharePoint (\(current.prefix(80)))") }
        return URL(string: "https://\(host)")!
    }

    /// Meeting recordings in other people's OneDrive that the owner can open (shared in a Teams chat), newest first.
    public func sharedRecordings(since: Date) throws -> [TeamsRecording] {
        let root = try sharePointRoot()
        let tenant = root.host!.replacingOccurrences(of: ".sharepoint.com", with: "")
        try open(root.appendingPathComponent("_layouts/15/videohub.aspx").absoluteString)
        let day = ISO8601DateFormatter.string(from: since, timeZone: TimeZone(identifier: "UTC")!, formatOptions: [.withFullDate])
        let query = "filetype:mp4 path:https://\(tenant)-my.sharepoint.com Created>=\(day)"
        let js = """
        (async()=>{const sel=encodeURIComponent("'Title,Created,MediaDuration,DefaultEncodingURL,SPWebUrl,UniqueId'");
        const q=encodeURIComponent(\(Self.jsString("'" + query + "'")));
        const r=await fetch('/_api/search/query?querytext='+q+'&rowlimit=100&selectproperties='+sel+'&sortlist=%27Created:descending%27',{headers:{accept:'application/json;odata=nometadata'}});
        if(!r.ok)return JSON.stringify({error:r.status});const j=await r.json();
        return JSON.stringify(j.PrimaryQueryResult.RelevantResults.Table.Rows.map(x=>Object.fromEntries(x.Cells.map(c=>[c.Key,c.Value]))))})()
        """
        var raw = (try? eval(js)) ?? ""
        if !raw.hasPrefix("[") {  // the page was still loading: once more
            try browser(["wait", "4000"])
            raw = try eval(js)
        }
        guard let rows = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] else {
            throw ClaudeError(message: "SharePoint search failed: \(raw.prefix(120))")
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return rows.compactMap { r in
            guard let id = (r["UniqueId"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "{}")).lowercased(),
                  let file = r["DefaultEncodingURL"] as? String, let web = r["SPWebUrl"] as? String,
                  let created = (r["Created"] as? String).flatMap({ iso.date(from: $0.replacingOccurrences(of: "0000000Z", with: "Z")) ?? ISO8601DateFormatter().date(from: String($0.prefix(19)) + "Z") })
            else { return nil }
            return TeamsRecording(id: id, title: r["Title"] as? String ?? "Teams meeting", start: created,
                                  duration: Double(r["MediaDuration"] as? String ?? "") ?? 0, fileURL: file, webURL: web)
        }
    }

    /// The Teams transcript of a recording, as the player shows it; nil when the meeting wasn't transcribed.
    public func transcript(of rec: TeamsRecording) throws -> [TeamsTranscriptLine]? {
        try open(rec.playerURL)
        try browser(["wait", "4000"])
        // The pane is usually open already; otherwise open it.
        let opened = try eval("""
        (()=>{if(document.querySelector('[role=group][aria-label*=" seconds"]'))return "open";
        const b=[...document.querySelectorAll('button')].find(b=>(b.getAttribute('aria-label')||b.innerText||'').trim()==='Read transcript');
        if(!b)return "none";b.click();return "clicked"})()
        """)
        if opened == "none" { return nil }
        if opened == "clicked" { try browser(["wait", "4000"]) }
        // The list is virtualised: collect what is rendered, scroll, repeat until the end.
        let step = """
        (()=>{window.__jt=window.__jt||{};let sc=null;
        for(const g of document.querySelectorAll('[role=group][aria-label]')){
        const m=g.getAttribute('aria-label').match(/^(.*?) (?:(\\d+) hours? )?(\\d+) minutes? (\\d+) seconds?$/);if(!m)continue;
        const li=g.querySelector('[role=listitem]');if(!li)continue;
        const t=(+(m[2]||0))*3600+(+m[3])*60+(+m[4]);window.__jt[t+'|'+m[1]+'|'+li.innerText.slice(0,40)]={t,s:m[1],x:li.innerText.trim()};
        let p=g.parentElement;while(p&&!(p.scrollHeight>p.clientHeight+20&&getComputedStyle(p).overflowY!=='visible'))p=p.parentElement;if(p)sc=p}
        if(sc)sc.scrollTop+=sc.clientHeight*0.8;return Object.keys(window.__jt).length+' '+(sc?Math.round(sc.scrollTop):-1)})()
        """
        var last = "", same = 0
        for _ in 0..<1500 {
            let state = try eval(step)
            if state == last { same += 1; if same >= 2 { break } } else { same = 0 }
            last = state
            Thread.sleep(forTimeInterval: 0.5)
        }
        let json = try eval("JSON.stringify(Object.values(window.__jt||{}).sort((a,b)=>a.t-b.t))")
        let lines = (try? JSONDecoder().decode([TeamsTranscriptLine].self, from: Data(json.utf8))) ?? []
        return lines.isEmpty ? nil : lines
    }

    static func jsString(_ s: String) -> String {
        let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Audio: recording what the player plays

extension OutlookReader {
    public static var ffmpeg: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Plays a recording in the hidden browser, muted (nothing comes out of the speakers, so a meeting Jinnie is recording
    /// live doesn't hear it), and records the sound the player produces, into a 16 kHz
    /// mono .m4a. Real time: an hour of meeting takes an hour. Recording pauses while the player buffers, so the audio
    /// stays aligned with the meeting's clock. `progress` gets 0…1; return false from it to stop early.
    public func captureAudio(playerURL: String, duration: Double, to output: URL, progress: (Double) -> Bool) throws {
        guard let ffmpeg = Self.ffmpeg else { throw ClaudeError(message: "Recording audio needs ffmpeg (brew install ffmpeg)") }
        try open(playerURL)
        try browser(["wait", "3000"])
        // Playing needs a click (browsers block autoplay); clicking the video is that click.
        try browser(["click", "video"])
        try browser(["wait", "1500"])
        let start = try eval("""
        (async()=>{const v=document.querySelector('video');if(!v)return 'no video';
        try{v.currentTime=0;if(v.paused)await v.play()}catch(e){return 'play failed: '+e}
        v.muted=true;await new Promise(r=>setTimeout(r,800));
        const tr=v.captureStream().getAudioTracks();if(!tr.length)return 'no audio';
        const rec=new MediaRecorder(new MediaStream(tr),{mimeType:'audio/webm;codecs=opus',audioBitsPerSecond:48000});
        window.__cap={chunks:[],rec,done:false};rec.ondataavailable=e=>{if(e.data.size)window.__cap.chunks.push(e.data)};
        v.addEventListener('waiting',()=>{if(rec.state==='recording')rec.pause()});
        v.addEventListener('playing',()=>{if(rec.state==='paused')rec.resume()});
        v.addEventListener('ended',()=>{window.__cap.done=true;if(rec.state!=='inactive')rec.stop()});
        rec.start(2000);return 'ok'})()
        """)
        guard start == "ok" else { throw ClaudeError(message: "Couldn't record the player: \(start)") }

        let webm = output.deletingPathExtension().appendingPathExtension("webm")
        FileManager.default.createFile(atPath: webm.path, contents: nil)
        let handle = try FileHandle(forWritingTo: webm)
        defer { try? handle.close() }
        // Pull what was recorded every few seconds (as base64), so nothing large sits in the page.
        let pull = """
        (async()=>{const c=window.__cap;if(!c)return JSON.stringify({error:'lost'});const parts=c.chunks.splice(0);
        const buf=new Uint8Array(await new Blob(parts).arrayBuffer());let s='';
        for(let i=0;i<buf.length;i+=32768)s+=String.fromCharCode.apply(null,buf.subarray(i,i+32768));
        const v=document.querySelector('video');
        return JSON.stringify({b:btoa(s),t:v?v.currentTime:-1,done:c.done&&c.rec.state==='inactive',paused:v?v.paused:true})})()
        """
        var lastT = -1.0, stuck = 0, stopped = false
        while true {
            // Near the end the page can reset itself once the video ends: pull often there, so little is lost.
            Thread.sleep(forTimeInterval: duration - lastT < 40 ? 2 : 10)
            let raw = try eval(pull, timeout: 120)
            let o = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
            if o == nil || o?["error"] != nil {
                if duration > 0, lastT >= duration - 30 { break }  // reset at the very end: keep what we have
                throw ClaudeError(message: "Lost the player at \(Int(max(lastT, 0) / 60)) min: \(raw.prefix(80))")
            }
            guard let o else { break }
            if let b = o["b"] as? String, let data = Data(base64Encoded: b), !data.isEmpty { handle.write(data) }
            if o["done"] as? Bool == true { break }
            let t = o["t"] as? Double ?? 0
            if !progress(duration > 0 ? min(1, t / duration) : 0) {
                _ = try? eval("(()=>{const c=window.__cap;document.querySelector('video')?.pause();if(c&&c.rec.state!=='inactive')c.rec.stop();return 'ok'})()")
                stopped = true
                Thread.sleep(forTimeInterval: 2)
                if let raw = try? eval(pull), let o = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                   let b = o["b"] as? String, let data = Data(base64Encoded: b) { handle.write(data) }
                break
            }
            // A player that stopped moving (paused by the page, or stalled for good) gets a nudge, then a failure.
            if abs(t - lastT) < 0.5 {
                stuck += 1
                if stuck == 3 { _ = try? eval("(()=>{document.querySelector('video')?.play();return 'ok'})()") }
                if stuck >= 12 { throw ClaudeError(message: "The player stopped at \(Int(t / 60)) min") }
            } else { stuck = 0 }
            lastT = t
        }
        try? handle.close()
        _ = try? browser(["open", "about:blank"])
        // To Jinnie's format (16 kHz mono AAC), which Whisper reads.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-y", "-v", "error", "-i", webm.path, "-ac", "1", "-ar", "16000", "-c:a", "aac", "-b:a", "32k", output.path]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        try? FileManager.default.removeItem(at: webm)
        guard p.terminationStatus == 0 else {
            throw ClaudeError(message: "ffmpeg failed: \(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).prefix(200))")
        }
        if stopped { throw ClaudeError(message: "Stopped") }
    }
}
