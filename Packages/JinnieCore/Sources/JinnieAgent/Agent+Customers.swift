import Foundation
import JinnieCore

/// Customers group projects: one client organisation can have several projects. New projects name their customer when
/// they are extracted; projects from before customers existed are grouped once by the model.
extension Agent {
    /// Finds a customer by name or alias, or creates it (with the project's email domains). `prospect` false promotes a
    /// potential customer to a customer; true never demotes one.
    func customerID(named raw: String, domains: [String] = [], prospect: Bool? = nil) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.lowercased() != "internal" else { return nil }
        let dir = Directory(store: store)
        if var c = dir.customer(named: name) {
            let added = domains.filter { !c.domains.contains($0) }
            let promote = c.isProspect && prospect == false
            if !added.isEmpty || promote {
                c.domains += added
                if promote { c.prospect = nil; log("\(c.name) is now a customer") }
                store.save(c)
            }
            return c.id
        }
        var c = Customer(name: name)
        c.domains = domains
        if prospect == true { c.prospect = true }
        store.save(c)
        log(prospect == true ? "New potential customer: \(name)" : "New customer: \(name)")
        return c.id
    }

    static let customersSchema = #"""
    {"type":"object","required":["customers"],"properties":{"customers":{"type":"array","items":{"type":"object",
      "required":["name","projects"],"properties":{
        "name":{"type":"string","description":"The client organisation's usual short name"},
        "aliases":{"type":"array","items":{"type":"string"}},
        "domains":{"type":"array","items":{"type":"string"}},
        "description":{"type":"string","description":"One line: who they are"},
        "prospect":{"type":"boolean","description":"True for a potential customer (presales opportunity, not a client yet)"},
        "projects":{"type":"array","items":{"type":"string"},"description":"Exact project names from the list (may be empty for an existing customer)"}}}}}}
    """#

    /// Groups projects that have no customer yet under customers (existing or new), and marks potential customers
    /// (presales). Internal projects stay without one. Runs once by itself; `jinnie customers --assign` runs it again.
    @discardableResult
    public func assignCustomers() async throws -> Int {
        let dir = Directory(store: store)
        let open = dir.projects.filter { $0.customerID == nil && $0.status != .done }
        guard !open.isEmpty || !dir.customers.isEmpty else { return 0 }
        let people = Dictionary(grouping: dir.people.filter { !$0.isMe }) { $0.projectIDs.first ?? "" }
        let list = open.map { p in
            let orgs = Set((people[p.id] ?? []).compactMap(\.org)).sorted().prefix(6).joined(separator: ", ")
            return "- \(p.name) | aliases: \(p.aliases.joined(separator: ", ")) | domains: \(p.domains.joined(separator: ", ")) | \(p.description.prefix(200)) | people's orgs: \(orgs)"
        }.joined(separator: "\n")
        let existing = dir.customers.map { c in
            let projects = dir.projects(of: c).map { "\($0.name): \($0.description.prefix(150))" }.joined(separator: "; ")
            return "- \(c.name)\(c.isProspect ? " (potential)" : "") | \(c.domains.joined(separator: ", ")) | projects: \(projects)"
        }.joined(separator: "\n")
        var call = Claude.Call(prompt: """
        The owner (\(JinnieConfig.ownerName), \(OwnerProfile.current.role) at \(OwnerProfile.current.organization)) tracks these \
        projects. Group them by CUSTOMER: the client organisation the work is for. Several projects can belong to one \
        customer. Use an existing customer when it is the same organisation. A presales opportunity with one prospective \
        client gets that client as a POTENTIAL customer (prospect: true): they aren't paying yet (proposal, demo, \
        discovery, RFP). Leave out internal work (the owner's own company, sales activity not tied to one client, \
        learning, admin, personal) — those projects have no customer.
        Also return every EXISTING customer with prospect set (true if it is still only a presales opportunity), with \
        projects empty unless you add one of the projects below to it.
        Name customers as the organisation is usually called (often the project name itself, e.g. project "Acme" → customer "Acme"); \
        a project named after a partner or reseller still belongs to the end client if the descriptions show it.

        EXISTING CUSTOMERS:
        \(existing.isEmpty ? "none" : existing)

        PROJECTS WITHOUT A CUSTOMER (name | aliases | domains | description | orgs of people on it):
        \(list)
        """)
        call.systemPrompt = Prompts.system
        call.strictMCP = true
        call.mcpConfig = #"{"mcpServers":{}}"#
        call.jsonSchema = Agent.customersSchema
        call.label = "customers"
        call.model = Agent.routineModel
        call.timeout = 300
        let r = try await claude.run(call)
        var assigned = 0
        for c in (r.structured as? [String: Any])?["customers"] as? [[String: Any]] ?? [] {
            guard let name = c["name"] as? String else { continue }
            let names = c["projects"] as? [String] ?? []
            let projects = names.compactMap { Directory(store: store).project(named: $0) }.filter { $0.customerID == nil }
            if projects.isEmpty, var existing = Directory(store: store).customer(named: name) {
                // Classification only. Never demote a customer someone marked as a client by hand: only flag new ones.
                if let p = c["prospect"] as? Bool, p != existing.isProspect, store.meta("customers.assigned.v2") == nil {
                    existing.prospect = p ? true : nil
                    store.save(existing)
                }
                continue
            }
            guard !projects.isEmpty else { continue }
            let domains = ((c["domains"] as? [String] ?? []) + projects.flatMap(\.domains)).map { $0.lowercased() }
            guard let id = customerID(named: name, domains: Array(Set(domains)).sorted(), prospect: c["prospect"] as? Bool) else { continue }
            if var customer = store.get(Customer.self, id) {
                for a in c["aliases"] as? [String] ?? [] where !customer.aliases.contains(a) && a != customer.name { customer.aliases.append(a) }
                if customer.description.isEmpty { customer.description = c["description"] as? String ?? "" }
                store.save(customer)
            }
            for var p in projects { p.customerID = id; store.save(p); assigned += 1 }
        }
        store.setMeta("customers.assigned.v2", String(Date().timeIntervalSince1970))
        log("Customers: \(assigned) projects grouped · $\(String(format: "%.2f", r.costUSD))")
        return assigned
    }
}

extension Agent {
    static let prospectsSchema = #"""
    {"type":"object","required":["prospects"],"properties":{"prospects":{"type":"array","items":{"type":"object",
      "required":["name","why"],"properties":{
        "name":{"type":"string","description":"The organisation's usual short name"},
        "aliases":{"type":"array","items":{"type":"string"}},
        "domains":{"type":"array","items":{"type":"string"},"description":"Their email domains, if seen"},
        "description":{"type":"string","description":"One line: who they are and what the opportunity is"},
        "why":{"type":"string","description":"The evidence, briefly"}}}}}}
    """#

    /// Finds potential customers discussed in internal projects (a general "Sales" or "opportunities" project) and adds
    /// them as prospects, so each gets a customer page. Weekly; `jinnie customers --discover` runs it now.
    @discardableResult
    public func discoverProspects(days: Double = 120) async throws -> [String] {
        let dir = Directory(store: store)
        let internalIDs = Set(dir.projects.filter { $0.customerID == nil }.map(\.id))
        let cutoff = Date().addingTimeInterval(-days * 86400)
        let items = store.all(Item.self)
            .filter { $0.occurredAt > cutoff && $0.occurredAt <= Date() && !internalIDs.isDisjoint(with: $0.projectIDs) }
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(400)
        guard !items.isEmpty else { return [] }
        let lines = items.map { i -> String in
            let orgs = Set(i.personIDs.compactMap { dir.person(id: $0)?.org }).sorted().joined(separator: ", ")
            let domain = i.authorEmail?.split(separator: "@").last.map(String.init) ?? ""
            return "- \(Prompts.dayString(i.occurredAt)) | \(i.title) | \(i.summary.prefix(220)) | \(domain) | orgs: \(orgs)"
        }.joined(separator: "\n")
        let known = dir.customers.map { $0.name + ($0.aliases.isEmpty ? "" : " (\($0.aliases.joined(separator: ", ")))") }.joined(separator: ", ")
        let me = OwnerProfile.current
        var call = Claude.Call(prompt: """
        The owner (\(me.name), \(me.role) at \(me.organization)) runs presales. Below are recent items from their general \
        (internal) projects: sales, opportunities, demos. List the organisations that are POTENTIAL CUSTOMERS: a presales \
        opportunity with them (discovery, demo, proposal, pricing, RFP, scoping), not yet a client project.
        Not potential customers: \(me.organization) itself; vendors and platform companies the owner's company works with \
        (e.g. the CRM vendor and its account team); recruiters; event organisers; existing customers (\(known.isEmpty ? "none" : known)).
        A partner that would buy or resell the owner's services counts. Only include organisations with real evidence in the \
        items. Use each organisation's usual name and include their email domains when seen.

        ITEMS (date | title | summary | sender domain | orgs of people involved):
        \(lines)
        """)
        call.systemPrompt = Prompts.system
        call.strictMCP = true
        call.mcpConfig = #"{"mcpServers":{}}"#
        call.jsonSchema = Agent.prospectsSchema
        call.label = "prospects"
        call.model = Agent.routineModel
        call.timeout = 400
        let r = try await claude.run(call)
        var added: [String] = []
        for p in (r.structured as? [String: Any])?["prospects"] as? [[String: Any]] ?? [] {
            guard let name = (p["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  Directory(store: store).customer(named: name) == nil else { continue }
            var c = Customer(name: name)
            c.prospect = true
            c.aliases = (p["aliases"] as? [String] ?? []).filter { $0 != name }
            c.domains = (p["domains"] as? [String] ?? []).map { $0.lowercased() }
            c.description = p["description"] as? String ?? ""
            store.save(c)
            added.append(name)
            log("New potential customer: \(name) (\(p["why"] as? String ?? ""))")
        }
        store.setMeta("customers.prospectsAt", String(Date().timeIntervalSince1970))
        log("Prospects: \(added.count) new · $\(String(format: "%.2f", r.costUSD))")
        return added
    }

    var prospectsDue: Bool {
        guard let t = store.meta("customers.prospectsAt").flatMap(Double.init) else { return true }
        return Date().timeIntervalSince1970 - t > 7 * 86400
    }
}

extension Agent {
    /// Reads a customer's history from the sources, like a project scan: meetings, mail, documents and Slack that name it,
    /// come from its domains or involve its people. For potential customers without a project of their own, this is how
    /// their discovery calls and status updates get in. The customer page finds the items by name, domain and people.
    @discardableResult
    public func scanCustomer(_ customerID: String, days: Int = 180) async throws -> ApplyStats {
        guard let c = store.get(Customer.self, customerID) else { throw ClaudeError(message: "Unknown customer") }
        let key = "customerScan.\(c.id)"
        let last = store.meta(key).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        let since = last.map { $0.addingTimeInterval(-86400) } ?? Date().addingTimeInterval(-Double(days) * 86400)
        var tools: [String] = []
        for s in Source.connectors where isEnabled(s) { tools += (try? await self.tools(for: s)) ?? [] }
        guard !tools.isEmpty else { throw ClaudeError(message: "No connectors available") }
        let dir = Directory(store: store)
        let people = CustomerMatcher(c, in: dir).personIDs.compactMap { dir.person(id: $0) }
        let projects = dir.projects(of: c).map(\.name)
        let started = Date()
        var run = RunLog(kind: "scan:\(c.name)")
        store.save(run)
        log("Scanning history of \(c.name) since \(Prompts.dayString(since))…")
        let after = Prompts.dayString(since).replacingOccurrences(of: "-", with: "/")
        let task = """
        Build the history of the owner's \(c.isProspect ? "presales opportunity with the potential customer" : "work with the customer") \
        "\(c.name)" from \(Prompts.dayString(since)) until today.
        Known names: \(([c.name] + c.aliases).joined(separator: ", ")). Email domains: \(c.domains.isEmpty ? "unknown — discover them" : c.domains.joined(separator: ", ")).
        People at \(c.name): \(people.map(\.display).joined(separator: "; ").nilIfEmpty ?? "none known yet — discover them").
        \(c.description.isEmpty ? "" : "About: \(c.description)")
        \(projects.isEmpty ? "" : "Its projects: \(projects.joined(separator: ", ")).")
        1. Calendar (if available): meetings in that period whose title, description or attendees match (discovery calls, demos, \
           workshops). One item per meeting that has content.
        2. Mail: search with every name, `from:`/`to:` each domain and the people's addresses, `after:\(after)`; also internal \
           threads about \(c.name) (status updates from account executives, pricing, proposals). Read the substantive ones. One item per thread.
        3. Drive (if available): proposals, decks, estimates and meeting notes about \(c.name). One item per document.
        4. Slack (if available): conversations mentioning \(c.name).
        Name \(c.name) in each item's title or summary. Record the opportunity's stage and every status change as dated facts \
        (who said it, when). For people, capture role and organisation. Use existing projects only where the item is about one; \
        don't create a project for \(c.name). Only extract actions that are still open today.
        """
        do {
            let r = try await extract(task: task, tools: tools, label: "scan-\(c.name)", timeout: 2400)
            let stats = apply(r.structured, source: .email, actionCutoff: Date().addingTimeInterval(-30 * 86400))
            store.setMeta(key, String(started.timeIntervalSince1970))
            run.message = "\(stats.description) · $\(String(format: "%.2f", r.costUSD)) · \(r.durationMs / 1000)s"
            run.finishedAt = Date()
            store.save(run)
            log("\(c.name): \(run.message)")
            return stats
        } catch {
            run.ok = false; run.message = "\(error)"; run.finishedAt = Date(); store.save(run)
            throw error
        }
    }
}
