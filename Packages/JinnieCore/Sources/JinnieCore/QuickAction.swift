import Foundation

/// Actions typed as one sentence, without the model: "Waiting on Dana and Omar for Globex migration tool PoC" is two
/// waiting-for actions (one per person, so each can be chased on its own) in the project the text names.
/// "Send Dana the CR draft" is a next action. Names Jinnie doesn't know stay as typed.
public enum QuickAction {
    static let waitingPrefixes = ["waiting on ", "waiting for ", "wait for ", "wait on ", "waiting ", "ждем ", "ждём ", "жду ", "ожидаю "]
    /// Where the names end and the subject starts: "Dana and Omar | for | the PoC".
    static let subjectWords = [" for ", " about ", " re ", " regarding ", " to ", " on ", " по ", " про ", " насчет ", " насчёт "]
    static let nameSeparators = [",", ";", " and ", " & ", " + ", " и "]

    public static func parse(_ text: String, in dir: Directory, defaultProjectID: String? = nil, defaultKind: Action.Kind = .next) -> [Action] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        let lower = t.lowercased()
        let projectID = project(in: t, dir: dir)?.id ?? defaultProjectID

        if let prefix = waitingPrefixes.first(where: { lower.hasPrefix($0) }) {
            let rest = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            // The first subject word after at least one name splits names from the subject.
            let restLower = rest.lowercased()
            let cut = subjectWords.compactMap { w in restLower.range(of: w).map { (w, restLower.distance(from: restLower.startIndex, to: $0.lowerBound)) } }
                .filter { $0.1 > 0 }.min { $0.1 < $1.1 }
            var namesPart = rest, subject = ""
            if let (w, at) = cut {
                namesPart = String(rest.prefix(at))
                subject = String(rest.dropFirst(at + w.count)).trimmingCharacters(in: .whitespaces)
            }
            var names = [namesPart]
            for sep in nameSeparators { names = names.flatMap { $0.components(separatedBy: sep) } }
            names = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            // No subject found: the whole rest is the subject, nobody named.
            if subject.isEmpty { return [make(.waiting, title: rest, person: nil, name: nil, projectID: projectID)] }
            return names.map { n in
                let p = dir.person(name: n, projectHint: projectID)
                return make(.waiting, title: subject, person: p, name: p == nil ? n : nil, projectID: projectID)
            }
        }
        return [make(defaultKind, title: t, person: nil, name: nil, projectID: projectID)]
    }

    static func make(_ kind: Action.Kind, title: String, person: Person?, name: String?, projectID: String?) -> Action {
        var a = Action(kind: kind, title: title.prefix(1).uppercased() + title.dropFirst())
        a.personID = person?.id
        a.personName = person?.name ?? name
        a.projectID = projectID
        return a
    }

    /// The active project whose name or alias (or whose customer's name) appears in the text as a word.
    static func project(in text: String, dir: Directory) -> Project? {
        let words = " " + Directory.norm(text) + " "
        func mentioned(_ name: String) -> Bool {
            let n = Directory.norm(name)
            return n.count >= 3 && words.contains(" " + n + " ")
        }
        let active = dir.projects.filter { $0.status != .done }
        if let p = active.first(where: { p in ([p.name] + p.aliases).contains(where: mentioned) }) { return p }
        for c in dir.customers where ([c.name] + c.aliases).contains(where: mentioned) {
            if let p = dir.projects(of: c).first(where: { $0.status != .done }) { return p }
        }
        return nil
    }
}
