import AppIntents
import JinnieCore
import SwiftUI
import UIKit

@main
struct JinnieIOSApp: App {
    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            IOSRoot()
                .environment(model)
                .onChange(of: phase) { _, p in
                    if p == .active { Task { await model.sync?.syncNow() } }
                }
        }
    }
}

final class IOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        MainActor.assumeIsolated { CrashReporter.shared.start() }
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await AppModel.shared.sync?.syncNow()
        return .newData
    }
}

extension Route: Identifiable {
    var id: String { "\(self)" }
}

struct IOSRoot: View {
    @Environment(AppModel.self) private var model
    @State private var openedRoute: Route?
    // `-initialTab projects` (launch argument) opens another tab; handy for previews/screenshots.
    @State private var tab: Section_ = UserDefaults.standard.string(forKey: "initialTab").flatMap { t in Section_.allCases.first { $0.rawValue.lowercased() == t } } ?? .notes

    var body: some View {
        TabView(selection: $tab) {
            ForEach([Section_.notes, .actions, .projects, .ask, .today], id: \.self) { s in
                NavigationStack {
                    Group {
                        if s == .projects { ProjectsAndCustomers() } else { s.view }
                    }
                    .jinnieDestinations()
                        .toolbar {
                            if s == .today {
                                if ImprovementNoteRequest.isAvailable {
                                    Button { ImprovementNoteRequest.shared.start() } label: { Image(systemName: "lightbulb") }
                                        .accessibilityLabel("Suggest an Improvement")
                                }
                                NavigationLink { QuestionsView().jinnieDestinations() } label: { Image(systemName: "questionmark.bubble") }
                                NavigationLink { RecordingsView().jinnieDestinations() } label: { Image(systemName: "waveform") }
                                NavigationLink { PeopleView().jinnieDestinations() } label: { Image(systemName: "person.2") }
                                NavigationLink { ActivityView() } label: { Image(systemName: "waveform.path.ecg") }
                            }
                        }
                }
                .tabItem { Label(s == .today ? "More" : s.rawValue, systemImage: s == .today ? "ellipsis.circle" : s.symbol) }
                .badge(s == .today ? model.openClarifications.count : 0)
                .tag(s)
            }
        }
        .refreshable { await model.sync?.syncNow() }
        .onChange(of: tab, initial: true) { model.cleanUp(); model.place = "iPhone › \(tab == .today ? "More" : tab.rawValue)" }
        .sheet(item: Binding(get: { ImprovementNoteRequest.shared.pending }, set: { ImprovementNoteRequest.shared.pending = $0 })) { p in
            ImprovementNoteView(pending: p) { ImprovementNoteRequest.shared.pending = nil }
        }
        .onOpenURL { url in openedRoute = Route(url: url) }
        .sheet(item: $openedRoute) { route in
            NavigationStack {
                RouteView(route: route).jinnieDestinations()
                    .toolbar { Button("Done") { openedRoute = nil } }
            }
        }
    }
}

// MARK: - Shortcuts / Action button / Siri

struct AddNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Jinnie Note"
    static let description = IntentDescription("Saves a note to Jinnie, which links it to projects, people and actions.")
    static let openAppWhenRun = false

    @Parameter(title: "Note", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$text) to Jinnie") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard AppModel.shared.addNote(text) != nil else { return .result(dialog: "Nothing to save.") }
        await AppModel.shared.sync?.syncNow()
        return .result(dialog: "Saved to Jinnie.")
    }
}

struct JinnieShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddNoteIntent(), phrases: ["Add a note to \(.applicationName)", "\(.applicationName) note"],
                    shortTitle: "Add Note", systemImageName: "square.and.pencil")
    }
}

/// iPhone: Projects and Customers share a tab (the tab bar has room for five).
struct ProjectsAndCustomers: View {
    @AppStorage("projectsTabShowsCustomers") private var customers = false

    var body: some View {
        Group {
            if customers { CustomersView() } else { ProjectsView() }
        }
        .safeAreaInset(edge: .top) {
            Picker("Show", selection: $customers) {
                Text("Projects").tag(false)
                Text("Customers").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.bottom, 6)
            .background(.bar)
        }
    }
}
