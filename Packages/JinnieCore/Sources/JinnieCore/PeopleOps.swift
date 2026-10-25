import Foundation

/// Structural fixes to the people directory, used by Ask and by answers to open questions:
/// splitting a record that mixed two people, merging duplicates, taking someone off a project.
public extension Store {
    /// Moves everything that points at `fromID` to `toID`: item mentions, actions, stakeholder entries and project
    /// membership. With `projectID`, only what belongs to that project moves (splitting two people who were merged),
    /// and `fromID` leaves that project. Returns a short description of what moved.
    @discardableResult
    func movePersonLinks(from fromID: String, to toID: String, projectID: String? = nil) -> String {
        guard fromID != toID, var from = get(Person.self, fromID), var to = get(Person.self, toID) else { return "nothing moved" }
        var items = 0, actions = 0, roles = 0
        for var i in all(Item.self) where i.personIDs.contains(fromID) {
            if let projectID, !i.projectIDs.contains(projectID) { continue }
            i.personIDs.removeAll { $0 == fromID }
            if !i.personIDs.contains(toID) { i.personIDs.append(toID) }
            save(i); items += 1
        }
        for var a in all(Action.self) where a.personID == fromID {
            if let projectID, a.projectID != projectID { continue }
            a.personID = toID
            save(a); actions += 1
        }
        for var p in all(Project.self) {
            if let projectID, p.id != projectID { continue }
            guard var list = p.stakeholders else { continue }
            var changed = false
            for k in list.indices {
                if list[k].personID == fromID { list[k].personID = toID; changed = true; roles += 1 }
                if list[k].replacedByID == fromID { list[k].replacedByID = toID; changed = true }
            }
            // One entry per person: keep the first.
            var seen = Set<String>()
            list = list.filter { seen.insert($0.personID).inserted }
            if changed { p.stakeholders = list; save(p) }
        }
        let moved = projectID.map { [$0] } ?? from.projectIDs
        for pid in moved where !to.projectIDs.contains(pid) { to.projectIDs.append(pid) }
        save(to)
        if let projectID { from.projectIDs.removeAll { $0 == projectID }; save(from) }
        return "\(items) items, \(actions) actions, \(roles) project roles moved to \(to.name)"
    }

    /// Folds `mergeID` into `keepID` (emails, aliases, notes, every link) and deletes it.
    @discardableResult
    func mergePeople(keep keepID: String, merge mergeID: String) -> String {
        guard keepID != mergeID, let gone = get(Person.self, mergeID), get(Person.self, keepID) != nil else { return "nothing merged" }
        let moved = movePersonLinks(from: mergeID, to: keepID)
        guard var keep = get(Person.self, keepID) else { return moved }
        for e in gone.emails where !keep.emails.contains(e) { keep.emails.append(e) }
        for a in gone.aliases + [gone.name] where a != keep.name && !keep.aliases.contains(a) { keep.aliases.append(a) }
        if keep.org == nil { keep.org = gone.org }
        if keep.role == nil { keep.role = gone.role }
        if !gone.notes.isEmpty { keep.notes = keep.notes.isEmpty ? gone.notes : keep.notes + "\n" + gone.notes }
        save(keep)
        delete(gone)
        return "merged \(gone.name) into \(keep.name): \(moved)"
    }

    /// Takes a person off a project: membership and stakeholder entry (their items and actions stay as they are).
    func removePerson(_ personID: String, fromProject projectID: String) {
        if var p = get(Person.self, personID) { p.projectIDs.removeAll { $0 == projectID }; save(p) }
        if var proj = get(Project.self, projectID), let list = proj.stakeholders, list.contains(where: { $0.personID == personID }) {
            proj.stakeholders = list.filter { $0.personID != personID }
            save(proj)
        }
    }
}
