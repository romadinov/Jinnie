import Foundation

/// Resolves loose mentions ("Dana", "dana.fischer@acme-telco.example", "Акме") to known
/// people and projects. Deterministic, so the LLM only has to name things; Jinnie decides identity.
extension String {
    public var nilIfEmpty: String? { isEmpty ? nil : self }
}

public struct Directory: Sendable {
    public var people: [Person]
    public var projects: [Project]
    public var customers: [Customer]

    public init(store: Store) {
        people = store.all(Person.self)
        projects = store.all(Project.self)
        customers = store.all(Customer.self)
    }

    public init(people: [Person], projects: [Project], customers: [Customer] = []) {
        self.people = people; self.projects = projects; self.customers = customers
    }

    // MARK: Customers

    public func customer(id: String?) -> Customer? { id.flatMap { i in customers.first { $0.id == i } } }

    public func customer(named name: String) -> Customer? {
        let n = Self.norm(name)
        guard !n.isEmpty else { return nil }
        return customers.first { Self.norm($0.name) == n || $0.aliases.contains { Self.norm($0) == n } }
    }

    public func customer(of project: Project) -> Customer? { customer(id: project.customerID) }
    public func projects(of customer: Customer) -> [Project] { projects.filter { $0.customerID == customer.id } }

    public static func norm(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
    }

    // MARK: People

    public func person(email: String?) -> Person? {
        guard let e = email.map(Self.norm), !e.isEmpty else { return nil }
        return people.first { $0.emails.contains { Self.norm($0) == e } }
    }

    /// Best match for a name: exact full name or alias, then a unique first-name / last-name match.
    /// `projectHint` breaks ties between two people with the same first name.
    public func person(name: String, projectHint: String? = nil) -> Person? {
        let n = Self.norm(name)
        guard !n.isEmpty else { return nil }
        if let p = people.first(where: { Self.norm($0.name) == n }) { return p }
        // A multi-word alias is as good as a name; a one-word alias ("Maria") is just a first name and goes through the
        // tie-break below, since another Maria may exist.
        let aliasHits = people.filter { $0.aliases.contains { Self.norm($0) == n } }
        if aliasHits.count == 1, n.contains(" ") { return aliasHits[0] }
        if let p = person(email: name) { return p }
        let tokens = n.split(separator: " ").map(String.init)
        let token = tokens.first ?? n
        let candidates = people.filter { p in
            let parts = Self.norm(p.name).split(separator: " ").map(String.init)
            let aliasParts = Set(p.aliases.flatMap { Self.norm($0).split(separator: " ").map(String.init) })
            guard parts.contains(token) || aliasParts.contains(token) else { return false }
            // A full name must agree on the surname too: "Maria Chen" is not "Maria Rossi". Only a record that
            // has no surname yet ("Kate") can take one.
            guard tokens.count > 1, parts.count > 1 else { return true }
            return tokens.dropFirst().allSatisfy { parts.contains($0) || aliasParts.contains($0) }
        }
        if candidates.count == 1 { return candidates[0] }
        if let hint = projectHint, candidates.count > 1 {
            let inProject = candidates.filter { $0.projectIDs.contains(hint) }
            if inProject.count == 1 { return inProject[0] }
        }
        return nil
    }

    public func resolvePerson(name: String?, email: String?, projectHint: String? = nil) -> Person? {
        person(email: email) ?? name.flatMap { person(name: $0, projectHint: projectHint) }
    }

    // MARK: Projects

    public func project(named name: String) -> Project? {
        let n = Self.norm(name)
        guard !n.isEmpty else { return nil }
        if let p = projects.first(where: { Self.norm($0.name) == n || $0.aliases.contains { Self.norm($0) == n } }) { return p }
        // "Work : Acme" or "Acme project"
        if let p = projects.first(where: { Self.norm($0.uberdoerPath ?? "") == n }) { return p }
        let loose = projects.filter { n.contains(Self.norm($0.name)) && $0.name.count >= 3 }
        return loose.count == 1 ? loose[0] : nil
    }

    public func project(forEmail email: String) -> Project? {
        guard let domain = email.split(separator: "@").last.map({ Self.norm(String($0)) }) else { return nil }
        return projects.first { $0.domains.contains { d in let d = Self.norm(d); return domain == d || domain.hasSuffix("." + d) } }
    }

    public func project(id: String?) -> Project? { id.flatMap { i in projects.first { $0.id == i } } }
    public func person(id: String?) -> Person? { id.flatMap { i in people.first { $0.id == i } } }

    /// Compact text the prompts include so the model uses canonical names.
    public func promptText(maxPeople: Int = 300) -> String {
        var lines: [String] = []
        if !customers.isEmpty {
            lines.append("CUSTOMERS (name | aliases | email domains):")
            for c in customers { lines.append("- \(c.name)\(c.isProspect ? " (potential customer)" : "") | \(c.aliases.joined(separator: ", ")) | \(c.domains.joined(separator: ", "))") }
            lines.append("")
        }
        lines.append("PROJECTS (name | customer | aliases | email domains | slack channels | uberdoer):")
        for p in projects where p.status != .done {
            lines.append("- \(p.name) | \(customer(of: p)?.name ?? "internal") | \(p.aliases.joined(separator: ", ")) | \(p.domains.joined(separator: ", ")) | \(p.channels.joined(separator: ", ")) | \(p.uberdoerPath ?? "")")
        }
        lines.append("")
        lines.append("PEOPLE (name | emails | aliases | org | role | projects):")
        for p in people.filter({ !$0.isMe }).prefix(maxPeople) {
            let projs = p.projectIDs.compactMap { id in projects.first { $0.id == id }?.name }.joined(separator: ", ")
            lines.append("- \(p.name) | \(p.emails.joined(separator: ", ")) | \(p.aliases.joined(separator: ", ")) | \(p.org ?? "") | \(p.role ?? "") | \(projs)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - What belongs to a customer

/// Decides what concerns a customer: its projects, people at it (by email domain or organisation), mail from its domains,
/// and items naming it. Customers without a project of their own (prospects discussed in a general sales project) get
/// their page from this.
public struct CustomerMatcher {
    public let projectIDs: Set<String>
    public let personIDs: Set<String>
    let domains: [String]
    let names: [String]
    let nameRegex: NSRegularExpression?

    public init(_ customer: Customer, in dir: Directory) {
        projectIDs = Set(dir.projects(of: customer).map(\.id))
        domains = customer.domains.map { Directory.norm($0) }.filter { !$0.isEmpty }
        // Names too short or common to search for in text ("THE", "REV") only match through domains, people and projects.
        names = ([customer.name] + customer.aliases).map { Directory.norm($0) }.filter { $0.count >= 5 }
        nameRegex = names.isEmpty ? nil : try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}])(" + names.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")(?![\\p{L}\\p{N}])",
            options: [.caseInsensitive])
        let domains = self.domains
        let names = self.names
        personIDs = Set(dir.people.filter { p in
            guard !p.isMe else { return false }
            if p.emails.contains(where: { Self.domain($0, in: domains) }) { return true }
            let org = Directory.norm(p.org ?? "")
            return !org.isEmpty && names.contains { org == $0 || org.hasPrefix($0 + " ") || org.hasSuffix(" " + $0) }
        }.map(\.id))
    }

    static func domain(_ email: String, in domains: [String]) -> Bool {
        guard let d = email.split(separator: "@").last.map({ Directory.norm(String($0)) }) else { return false }
        return domains.contains { d == $0 || d.hasSuffix("." + $0) }
    }

    public func matches(_ item: Item) -> Bool {
        if !projectIDs.isDisjoint(with: item.projectIDs) || !personIDs.isDisjoint(with: item.personIDs) { return true }
        if let e = item.authorEmail, Self.domain(e, in: domains) { return true }
        guard let re = nameRegex else { return false }
        let text = item.title + " " + item.summary
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public func matches(_ action: Action) -> Bool {
        if let p = action.projectID, projectIDs.contains(p) { return true }
        if let p = action.personID, personIDs.contains(p) { return true }
        guard let re = nameRegex else { return false }
        return re.firstMatch(in: action.title, range: NSRange(action.title.startIndex..., in: action.title)) != nil
    }
}
