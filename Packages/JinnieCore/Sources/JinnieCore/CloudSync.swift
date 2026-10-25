import CloudKit
import Foundation
import os

public struct SyncStatus: Sendable, Equatable {
    public var state = "Starting"
    public var lastSync: Date?
    public var pending = 0
    public var lastError: String?
    public init() {}
}

/// CloudKit transport built on CKSyncEngine. One record per entity ("<type>/<id>") holding the
/// entity's JSON; the copy with the later `updatedAt` wins, on both sides. Deletions are tombstones
/// (`deleted = true`), so they sync like any other edit.
///
/// Shape borrowed from Uberdoer's sync: engine state persisted in the store, full re-upload when the
/// container/environment changes or the zone disappears, uploads driven by a local outbox.
public final class CloudSync: CKSyncEngineDelegate, @unchecked Sendable {
    public static let zoneName = "Jinnie"
    static let recordType = "JinnieRecord"

    let container: CKContainer
    let store: Store
    let zoneID = CKRecordZone.ID(zoneName: CloudSync.zoneName, ownerName: CKCurrentUserDefaultName)
    let log = Logger(subsystem: "Jinnie", category: "sync")
    private let lock = NSRecursiveLock()
    private var engine: CKSyncEngine?
    private var status = SyncStatus()
    /// Server copies seen this session, so saves carry the right change tag.
    private var serverRecords: [String: CKRecord] = [:]

    public var onStatus: (@Sendable (SyncStatus) -> Void)?

    public init(containerIdentifier: String = JinnieConfig.cloudContainer, store: Store) {
        self.container = CKContainer(identifier: containerIdentifier)
        self.store = store
    }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard engine == nil else { return }
        let target = "\(container.containerIdentifier ?? "")#\(JinnieConfig.cloudEnvironment)"
        if store.meta("ck.container") != target {
            if store.meta("ck.container") != nil { store.enqueueAll() }
            store.setMeta("ck.state", nil)
            store.setMeta("ck.container", target)
        }
        makeEngine()
        update { $0.state = "Syncing" }
        Task { await checkAccount() }
    }

    private func makeEngine() {
        let saved = store.meta("ck.state").flatMap { Data(base64Encoded: $0) }
            .flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        var config = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: saved, delegate: self)
        config.automaticallySync = true
        let e = CKSyncEngine(config)
        engine = e
        if saved == nil {
            e.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        scheduleUploads()
    }

    func checkAccount() async {
        do {
            let s = try await container.accountStatus()
            if s != .available { update { $0.state = "No iCloud account"; $0.lastError = "Sign in to iCloud to sync." } }
        } catch { update { $0.lastError = error.localizedDescription } }
    }

    /// Call after local writes (this process or another one). Cheap.
    public func localChangesCommitted() { scheduleUploads() }

    public func syncNow() async {
        guard let e = lock.withLock({ engine }) else { return }
        do {
            try await e.fetchChanges()
            scheduleUploads()
            try await e.sendChanges()
            update { $0.lastSync = Date(); $0.lastError = nil; $0.state = "Up to date" }
        } catch {
            update { $0.lastError = error.localizedDescription }
        }
    }

    func scheduleUploads() {
        lock.lock(); defer { lock.unlock() }
        guard let e = engine else { return }
        let pendingNames = Set(e.state.pendingRecordZoneChanges.compactMap { change -> String? in
            if case .saveRecord(let id) = change { return id.recordName }
            return nil
        })
        let changes: [CKSyncEngine.PendingRecordZoneChange] = store.outbox(limit: 2000).compactMap { row in
            let name = "\(row.type)/\(row.id)"
            return pendingNames.contains(name) ? nil : .saveRecord(CKRecord.ID(recordName: name, zoneID: zoneID))
        }
        if !changes.isEmpty { e.state.add(pendingRecordZoneChanges: changes) }
        update { $0.pending = self.store.outboxCount }
    }

    private func update(_ body: (inout SyncStatus) -> Void) {
        let s: SyncStatus = lock.withLock { body(&status); return status }
        onStatus?(s)
    }

    // MARK: CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let u):
            if let data = try? JSONEncoder().encode(u.stateSerialization) { store.setMeta("ck.state", data.base64EncodedString()) }

        case .accountChange(let change):
            switch change.changeType {
            case .signIn, .switchAccounts:
                store.enqueueAll()
                scheduleUploads()
            case .signOut:
                update { $0.state = "No iCloud account" }
            @unknown default: break
            }

        case .fetchedRecordZoneChanges(let changes):
            var applied = 0
            for m in changes.modifications {
                let r = m.record
                lock.withLock { serverRecords[r.recordID.recordName] = r }
                guard let type = r["type"] as? String, let json = r["json"] as? String else { continue }
                if store.applyRemote(type: type, json: json) { applied += 1 }
            }
            if applied > 0 { log.info("Applied \(applied) records from iCloud") }

        case .fetchedDatabaseChanges(let changes):
            for d in changes.deletions where d.zoneID == zoneID {
                // The cloud copy is gone: rebuild it from this device.
                store.enqueueAll()
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                scheduleUploads()
            }

        case .sentRecordZoneChanges(let sent):
            for r in sent.savedRecords {
                lock.withLock { serverRecords[r.recordID.recordName] = r }
                let parts = r.recordID.recordName.split(separator: "/", maxSplits: 1).map(String.init)
                // Only clear the outbox if nothing changed locally while the upload was in flight.
                if parts.count == 2, let local = store.rawRecord(type: parts[0], id: parts[1]),
                   (r["updatedAt"] as? Double).map({ $0 >= local.updatedAt }) ?? true {
                    store.removeFromOutbox(type: parts[0], id: parts[1])
                }
            }
            var retry: [CKSyncEngine.PendingRecordZoneChange] = []
            for f in sent.failedRecordSaves {
                let id = f.record.recordID
                switch f.error.code {
                case .serverRecordChanged:
                    if let server = f.error.serverRecord {
                        lock.withLock { serverRecords[id.recordName] = server }
                        if let type = server["type"] as? String, let json = server["json"] as? String {
                            store.applyRemote(type: type, json: json)
                        }
                        retry.append(.saveRecord(id))  // re-send if ours is still newer (see nextRecordZoneChangeBatch)
                    }
                case .zoneNotFound, .userDeletedZone:
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                    retry.append(.saveRecord(id))
                case .unknownItem:
                    lock.withLock { _ = serverRecords.removeValue(forKey: id.recordName) }
                    retry.append(.saveRecord(id))
                case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
                    break // CKSyncEngine retries these itself
                default:
                    log.error("Save failed for \(id.recordName): \(f.error.localizedDescription)")
                    update { $0.lastError = f.error.localizedDescription }
                }
            }
            if !retry.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: retry) }
            update { $0.pending = self.store.outboxCount; $0.lastSync = Date() }

        case .didFetchChanges, .didSendChanges:
            update { $0.state = "Up to date"; $0.lastSync = Date() }

        default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] recordID in
            guard let self else { return nil }
            let parts = recordID.recordName.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let local = self.store.rawRecord(type: parts[0], id: parts[1]) else {
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            let record: CKRecord = self.lock.withLock { self.serverRecords[recordID.recordName] }
                ?? CKRecord(recordType: CloudSync.recordType, recordID: recordID)
            if let serverUpdated = record["updatedAt"] as? Double, serverUpdated >= local.updatedAt {
                // The cloud already has this version or a newer one.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                self.store.removeFromOutbox(type: parts[0], id: parts[1])
                return nil
            }
            record["type"] = parts[0] as CKRecordValue
            record["json"] = local.json as CKRecordValue
            record["updatedAt"] = local.updatedAt as CKRecordValue
            return record
        }
    }
}
