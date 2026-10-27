import JinnieCore
import SwiftUI

// MARK: - Customers (client organisations; each can have several projects)

struct CustomersView: View {
    @Environment(AppModel.self) private var model
    @State private var adding: Customer?

    var body: some View {
        let entries = model.customers.map { c in (customer: c, last: model.lastActivity(model.items(for: c))) }
            .sorted { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) }
        List {
            if entries.isEmpty {
                Text("No customers yet. Jinnie groups your projects by customer on its next sync; you can also set a project's customer in Edit.")
                    .foregroundStyle(.secondary)
            }
            let clients = entries.filter { !$0.customer.isProspect }
            let prospects = entries.filter { $0.customer.isProspect }
            if !clients.isEmpty {
                Section {
                    ForEach(clients, id: \.customer.id) { e in
                        NavigationLink(value: Route.customer(e.customer.id)) { CustomerRow(customer: e.customer, last: e.last) }
                    }
                }
            }
            if !prospects.isEmpty {
                Panel(id: "customers.prospects", title: "Potential customers", count: prospects.count) {
                    ForEach(prospects, id: \.customer.id) { e in
                        NavigationLink(value: Route.customer(e.customer.id)) { CustomerRow(customer: e.customer, last: e.last) }
                    }
                }
            }
            let internalWork = model.projects.filter { $0.customerID == nil && $0.status != .done }
            if !internalWork.isEmpty {
                Panel(id: "customers.internal", title: "Internal projects", count: internalWork.count) {
                    ForEach(internalWork) { p in
                        NavigationLink(value: Route.project(p.id)) { Text(p.name) }
                    }
                }
            }
        }
        .navigationTitle("Customers")
        .toolbar {
            Button {
                var c = Customer(name: "")
                c.prospect = true
                adding = c
            } label: { Label("Add Customer", systemImage: "plus") }
        }
        .sheet(item: $adding) { CustomerEditor(customer: $0) }
    }
}

struct CustomerRow: View {
    @Environment(AppModel.self) private var model
    let customer: Customer
    let last: Date?

    var body: some View { rowContent.copyable({ customer.name }, label: "Copy Name") }

    @ViewBuilder var rowContent: some View {
        let projects = model.projects(for: customer).filter { $0.status != .done }
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(customer.name).font(.body.weight(.semibold))
                Spacer()
                let open = model.actions(for: customer).filter { $0.status == .open }
                let waiting = open.filter { $0.kind == .waiting }.count
                if open.count - waiting > 0 { Label("\(open.count - waiting)", systemImage: "checklist").font(.caption).foregroundStyle(.secondary) }
                if waiting > 0 { Label("\(waiting)", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary) }
            }
            if !projects.isEmpty && !(projects.count == 1 && projects[0].name == customer.name) {
                Text(projects.map(\.name).joined(separator: " · ")).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            if let last {
                Text("Last activity \(last.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct CustomerDetail: View {
    @Environment(AppModel.self) private var model
    let customerID: String
    @State private var editing = false

    var body: some View {
        if let c = model.customer(customerID) {
            List {
                if c.isProspect || !c.description.isEmpty || !c.domains.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if c.isProspect {
                            Label("Potential customer: presales opportunity", systemImage: "sparkle.magnifyingglass")
                                .font(.callout.weight(.medium)).foregroundStyle(.orange)
                        }
                        if !c.description.isEmpty { Text(c.description) }
                        if !c.domains.isEmpty { Text(c.domains.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                let projects = model.projects(for: c)
                if !projects.isEmpty {
                Panel(id: "customer.projects", title: "Projects", count: projects.count) {
                    ForEach(projects) { p in
                        NavigationLink(value: Route.project(p.id)) {
                            ProjectRow(project: p, last: model.lastActivity(model.items(for: p)), showCustomer: false)
                        }
                    }
                }
                }
                let news = model.news(for: c)
                if !news.isEmpty {
                    Panel(id: "customer.news", title: "Latest news", count: news.count) {
                        ForEach(news.prefix(30), id: \.news) { NewsRow(news: $0.news, project: projects.count > 1 ? $0.project : nil) }
                    }
                }
                let acts = model.actions(for: c).filter { model.isListed($0) }
                Panel(id: "customer.next", title: "Next actions", count: acts.filter { $0.kind == .next }.count) {
                    ForEach(acts.filter { $0.kind == .next }) { ActionRow(action: $0, showProject: projects.count > 1) }
                }
                Panel(id: "customer.waiting", title: "Waiting for", count: acts.filter { $0.kind == .waiting }.count) {
                    ForEach(acts.filter { $0.kind == .waiting }) { ActionRow(action: $0, showProject: projects.count > 1) }
                }
                let contacts = model.contacts(for: c)
                if !contacts.isEmpty {
                    Panel(id: "customer.contacts", title: "People at \(c.name)", count: contacts.filter { $0.former != true }.count) {
                        ForEach(contacts, id: \.personID) { StakeholderRow(stakeholder: $0) }
                    }
                }
                let others = model.otherPeople(for: c)
                if !others.isEmpty {
                    Panel(id: "customer.people", title: contacts.isEmpty ? "People at \(c.name)" : "Others at \(c.name)", count: others.count) {
                        ForEach(others) { person in
                            NavigationLink(value: Route.person(person.id)) {
                                VStack(alignment: .leading) {
                                    Text(person.name)
                                    Text([person.role, person.org, person.emails.first].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                let docs = model.documents(for: c)
                if !docs.isEmpty {
                    Panel(id: "customer.documents", title: "Documents", count: docs.count) {
                        ForEach(docs.prefix(30), id: \.doc.url) { DocumentRow(doc: $0.doc, date: $0.date) }
                    }
                }
                Panel(id: "customer.timeline", title: "Timeline", count: model.items(for: c).count) {
                    ForEach(model.items(for: c).prefix(100)) { ItemRow(item: $0) }
                }
            }
            .navigationTitle(c.name)
            .toolbar {
                if let hooks = AgentHooks.shared {
                    Button("Scan History") { hooks.scanCustomer(c.id) }
                        .help("Read meetings, mail, documents and Slack about \(c.name) from the last 6 months")
                }
                Button("Edit") { editing = true }
            }
            .sheet(isPresented: $editing) { CustomerEditor(customer: c) }
        } else {
            Text("Customer not found").foregroundStyle(.secondary)
        }
    }
}

struct CustomerEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var customer: Customer
    @State private var aliases = ""
    @State private var domains = ""
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $customer.name)
                TextField("Aliases (comma separated)", text: $aliases)
                TextField("Email domains", text: $domains)
                TextField("Description", text: $customer.description, axis: .vertical)
                Toggle("Potential customer (presales opportunity)", isOn: Binding(get: { customer.isProspect }, set: { customer.prospect = $0 ? true : nil }))
                let saved = model.customer(customer.id) != nil
                if saved {
                Section("Projects") {
                    ForEach(model.projects.filter { $0.status != .done }) { p in
                        Toggle(p.name, isOn: Binding(
                            get: { p.customerID == customer.id },
                            set: { on in var q = p; q.customerID = on ? customer.id : nil; model.save(q) }))
                    }
                }
                Section {
                    Button("Delete Customer", role: .destructive) { confirmDelete = true }
                }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(model.customer(customer.id) == nil ? "New Customer" : "Edit Customer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        customer.aliases = split(aliases); customer.domains = split(domains).map { $0.lowercased() }
                        model.save(customer); dismiss()
                    }
                    .disabled(customer.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete \(customer.name)? Its projects stay, without a customer.", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { model.deleteCustomer(customer); dismiss() }
            }
            .onAppear {
                aliases = customer.aliases.joined(separator: ", ")
                domains = customer.domains.joined(separator: ", ")
            }
        }
        .frame(minWidth: 420, minHeight: 420)
    }
}
