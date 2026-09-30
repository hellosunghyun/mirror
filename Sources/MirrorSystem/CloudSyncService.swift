import Foundation
import CloudKit
import CoreData
import MirrorDomain
import MirrorData

public struct CloudSyncSetup: Sendable {
    public let containerIdentifier: String?
    public let appGroupIdentifier: String?
    /// 첫 계정 공간의 공통 세대다. 기기별 UUID로 만들지 않는다. 삭제 세대 권위와는 별개다.
    public let workspaceEpoch: String
    public init(containerIdentifier: String?, appGroupIdentifier: String?, workspaceEpoch: String = "local-v1") {
        self.containerIdentifier = containerIdentifier; self.appGroupIdentifier = appGroupIdentifier
        self.workspaceEpoch = workspaceEpoch
    }
}
public enum CloudPrerequisite: String, Hashable, Codable, Sendable {
    case cloudContainerIdentifier, appGroupIdentifier, signedAppGroupAccess, stableWorkspaceEpoch
}
public enum CloudAccountAvailability: String, Hashable, Codable, Sendable {
    case available, noAccount, restricted, temporarilyUnavailable, couldNotDetermine
    public init(_ status: CKAccountStatus) {
        switch status {
        case .available: self = .available
        case .noAccount: self = .noAccount
        case .restricted: self = .restricted
        case .temporarilyUnavailable: self = .temporarilyUnavailable
        case .couldNotDetermine: self = .couldNotDetermine
        @unknown default: self = .couldNotDetermine
        }
    }
}
public enum CloudMirrorPhase: String, Hashable, Codable, Sendable { case setup, importing, exporting }
public enum CloudSyncFailure: String, Hashable, Codable, Sendable {
    case networkUnavailable, quotaExceeded, notAuthenticated, permissionDenied, serviceUnavailable
    case persistenceFailure, epochMigrationRequired, unknown
}
public struct CloudActivationPreview: Hashable, Sendable {
    public let token: String
    public let accountFingerprint: String
    public let localOperationCount: Int
    public let cloudOperationCount: Int
    public let duplicateCount: Int
    public let warnings: [String]
}
public enum CloudSyncStatus: Equatable, Sendable {
    case localOnly
    case configurationRequired([CloudPrerequisite])
    case checkingAccount
    case accountUnavailable(CloudAccountAvailability)
    case awaitingMergeConsent(CloudActivationPreview)
    case awaitingSynchronization(accountFingerprint: String)
    case synchronizing(CloudMirrorPhase)
    /// 한 미러링 이벤트가 끝났다는 뜻이며 다른 모든 기기의 반영 완료를 보장하지 않는다.
    case idle(lastSuccessfulEvent: Date)
    case failed(CloudSyncFailure)
    case accountTransitionRequired
}
public enum CloudSyncServiceError: Error, Equatable, Sendable {
    case configurationRequired, accountTransitionRequired, accountUnavailable, staleConsent
}
public enum CloudDeletionGate: String, Hashable, Codable, Sendable {
    case authoritativeEpochNotConfigured, offlineResurrectionNotVerified, accountNotVerified, networkNotVerified
}
public enum CloudDeletionStatus: Equatable, Sendable {
    case configurationRequired
    case requiresDoubleConfirmation
    case blocked([CloudDeletionGate])
}
public struct CloudMirrorEvent: Sendable {
    public let phase: CloudMirrorPhase
    public let endedAt: Date?
    public let succeeded: Bool
    public let failure: CloudSyncFailure?
    public init(phase: CloudMirrorPhase, endedAt: Date? = nil, succeeded: Bool = false, failure: CloudSyncFailure? = nil) {
        self.phase = phase; self.endedAt = endedAt; self.succeeded = succeeded; self.failure = failure
    }
}
/// SDK 통신 대신 순수 전이를 검증한다. 실제 계정·두 기기 동기화는 별도 G-SYNC다.
public enum CloudSyncPolicy {
    public static func mayInspectAccount(explicitOptIn: Bool, configurationComplete: Bool) -> Bool {
        explicitOptIn && configurationComplete
    }
    public static func next(after event: CloudMirrorEvent) -> CloudSyncStatus {
        guard let ended = event.endedAt else { return .synchronizing(event.phase) }
        if event.succeeded { return .idle(lastSuccessfulEvent: ended) }
        return .failed(event.failure ?? .unknown)
    }
    public static func accountMatches(expected: String, observed: String) -> Bool {
        !expected.isEmpty && expected == observed
    }
    public static func deletion(confirmedTwice: Bool, activeAccountVerified: Bool) -> CloudDeletionStatus {
        guard confirmedTwice else { return .requiresDoubleConfirmation }
        var gates: [CloudDeletionGate] = [.authoritativeEpochNotConfigured, .offlineResurrectionNotVerified]
        if !activeAccountVerified { gates.insert(.accountNotVerified, at: 0) }
        return .blocked(gates)
    }
}

private struct ActiveCloudPointer: Codable, Sendable {
    let version: Int
    let optedIn: Bool
    let transitionRequired: Bool
    let containerIdentifier: String
    let accountFingerprint: String
    let workspaceKey: String
    let workspaceEpoch: String
    let initialTimeZoneID: String
    let initialPolicyRevision: String
}
private final class CloudNotificationObservation: @unchecked Sendable {
    // NotificationCenter의 등록 토큰만 소유한다. 알림 payload를 다른 actor로 보내지 않는다.
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}
private struct CloudEventNotice: Sendable {
    let identifier: UUID
    let storeIdentifier: String
    let event: CloudMirrorEvent
}

/// 사용자 opt-in 이후에만 CloudKit을 호출한다. 로컬 자료 병합은 별도 확인 후 실행한다.
public actor CloudSyncService {
    private let localConfiguration: StoreConfiguration
    private let setup: CloudSyncSetup
    private var currentStatus: CloudSyncStatus = .localOnly
    private var optedIn = false
    private var generation = 0
    private var pendingToken: String?
    private var pendingArchive: Data?
    private var pendingLocalStore: MirrorStore?
    private var candidateStore: MirrorStore?
    private var activeStore: MirrorStore?
    private var fingerprint: String?
    private var rootDirectory: URL?
    private var observedStoreIDs: Set<String> = []
    private var runningEvents: [UUID: CloudMirrorPhase] = [:]
    private var observations: [CloudNotificationObservation] = []

    public init(localConfiguration: StoreConfiguration, setup: CloudSyncSetup) {
        self.localConfiguration = localConfiguration; self.setup = setup
    }
    public func status() -> CloudSyncStatus { currentStatus }
    public func resumeActiveStore(_ active: MirrorStore) async throws {
        try await resumeActiveStore(active: active)
    }
    /// 프로세스 재시작 후 공유 opt-in pointer와 현재 계정을 재확인하여 관찰을 복원한다.
    public func resumeActiveStore(active: MirrorStore) async throws {
        guard let groupID = setup.appGroupIdentifier, let identifier = setup.containerIdentifier,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID),
              let verified = try await Self.resolveActiveConfiguration(appGroupIdentifier: groupID,
                deviceID: localConfiguration.deviceID, expectedContainerIdentifier: identifier),
              let cloud = active.configuration.cloudSync,
              verified.directory.standardizedFileURL == active.configuration.directory.standardizedFileURL,
              cloud.accountScope == verified.cloudSync?.accountScope else {
            try? await active.suspend()
            currentStatus = .accountTransitionRequired
            throw CloudSyncServiceError.accountTransitionRequired
        }
        generation += 1; optedIn = true; rootDirectory = root; fingerprint = cloud.accountScope
        activeStore = active; observedStoreIDs = await active.cloudStoreIdentifiers()
        installObservers()
        currentStatus = .awaitingSynchronization(accountFingerprint: cloud.accountScope)
    }

    public func previewEnable(localStore: MirrorStore, explicitOptIn: Bool, at instant: Date) async -> CloudActivationPreview? {
        guard explicitOptIn else { currentStatus = .localOnly; return nil }
        let missing = missingPrerequisites()
        guard missing.isEmpty else { currentStatus = .configurationRequired(missing); return nil }
        guard let containerID = setup.containerIdentifier, let groupID = setup.appGroupIdentifier,
              let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            currentStatus = .configurationRequired([.signedAppGroupAccess]); return nil
        }
        if activeStore != nil { return nil }
        if let previous = candidateStore { try? await previous.suspend() }
        candidateStore = nil; pendingArchive = nil; pendingToken = nil; pendingLocalStore = nil
        generation += 1
        let ticket = generation
        optedIn = true; rootDirectory = shared; currentStatus = .checkingAccount
        installObservers()
        do {
            let account = try await Self.inspectAccount(containerIdentifier: containerID)
            guard optedIn, generation == ticket else { return nil }
            guard let account else { currentStatus = .accountUnavailable(.noAccount); return nil }
            let local = try await localStore.snapshot()
            let archive = try await localStore.exportArchive(exportedAt: instant)
            guard optedIn, generation == ticket else { return nil }
            if local.workspaceEpoch != setup.workspaceEpoch,
               !local.records.isEmpty || local.quarantinedCount > 0 {
                currentStatus = .failed(.epochMigrationRequired); return nil
            }
            let configuration = Self.configuration(root: shared, account: account, setup: setup,
                                                   base: localConfiguration, policy: local.policy)
            let cloud = try await MirrorStore(configuration: configuration)
            guard optedIn, generation == ticket else { try? await cloud.suspend(); return nil }
            let remote = try await cloud.snapshot()
            let preview: ImportPreview?
            if local.records.isEmpty && local.quarantinedCount == 0 { preview = nil }
            else { preview = try await cloud.previewArchive(archive) }
            guard optedIn, generation == ticket else { try? await cloud.suspend(); return nil }
            let consent = CloudActivationPreview(token: UUID().uuidString, accountFingerprint: account,
                localOperationCount: local.records.count + local.quarantinedCount,
                cloudOperationCount: remote.records.count + remote.quarantinedCount,
                duplicateCount: preview?.duplicateCount ?? 0,
                warnings: (preview?.warnings ?? []) + ["작업과 변경 이력만 Apple private database에서 동기화합니다.",
                    "캘린더 원문·세션·영수증·기기 알림 설정은 이 기기에 남습니다.",
                    "다른 기기의 자료는 비동기로 내려오므로 이 미리 보기는 이후 달라질 수 있습니다."])
            candidateStore = cloud; pendingLocalStore = localStore; pendingToken = consent.token
            pendingArchive = preview == nil ? nil : archive; fingerprint = account
            observedStoreIDs = await cloud.cloudStoreIdentifiers()
            currentStatus = .awaitingMergeConsent(consent)
            return consent
        } catch let unavailable as AccountUnavailable {
            currentStatus = .accountUnavailable(unavailable.availability)
            return nil
        } catch {
            currentStatus = .failed(Self.failure(error)); return nil
        }
    }

    public func confirmEnable(token: String, consentToMerge: Bool, at instant: Date = Date()) async -> MirrorStore? {
        guard consentToMerge else { await cancelPreview(); return nil }
        guard optedIn, token == pendingToken, let cloud = candidateStore, let expected = fingerprint,
              let containerID = setup.containerIdentifier, let root = rootDirectory else {
            currentStatus = .failed(.unknown); return nil
        }
        let ticket = generation
        do {
            guard let account = try await Self.inspectAccount(containerIdentifier: containerID),
                  CloudSyncPolicy.accountMatches(expected: expected, observed: account) else {
                await handleAccountChanged(); return nil
            }
            guard generation == ticket, optedIn else { return nil }
            let config = cloud.configuration
            // 새 확장 프로세스가 이전 로컬 writer를 열지 않게 전환 상태를 먼저 공유한다.
            try Self.write(ActiveCloudPointer(version: 1, optedIn: true, transitionRequired: true,
                containerIdentifier: containerID, accountFingerprint: expected,
                workspaceKey: config.workspaceKey, workspaceEpoch: config.workspaceEpoch,
                initialTimeZoneID: config.initialTimeZoneID, initialPolicyRevision: config.initialPolicyRevision), root: root)
            if let local = pendingLocalStore {
                // 마지막 원본 export와 writer 중지는 하나의 저장 게이트 경계에서 수행한다.
                let latest = try await local.exportAndSuspend(exportedAt: instant)
                if local.configuration.workspaceEpoch == config.workspaceEpoch {
                    // 미리 보기가 비어 있었어도 그 이후 입력을 모두 병합한다.
                    _ = try await cloud.importArchive(latest, consent: ArchiveImportConsent(accountChangeConfirmed: true))
                } else {
                    let object = try JSONSerialization.jsonObject(with: latest) as? [String: Any]
                    let operations = object?["rawOperations"] as? [[String: Any]] ?? []
                    guard operations.isEmpty else { currentStatus = .failed(.epochMigrationRequired); return nil }
                }
            }
            guard generation == ticket, optedIn else { return nil }
            let pointer = ActiveCloudPointer(version: 1, optedIn: true, transitionRequired: false,
                containerIdentifier: containerID, accountFingerprint: expected,
                workspaceKey: config.workspaceKey, workspaceEpoch: config.workspaceEpoch,
                initialTimeZoneID: config.initialTimeZoneID, initialPolicyRevision: config.initialPolicyRevision)
            try Self.write(pointer, root: root)
            activeStore = cloud; candidateStore = nil; pendingLocalStore = nil; pendingArchive = nil; pendingToken = nil
            currentStatus = .awaitingSynchronization(accountFingerprint: expected)
            return cloud
        } catch {
            currentStatus = .failed(Self.failure(error)); return nil
        }
    }

    public func cancelPreview() async {
        generation += 1
        if let candidateStore { try? await candidateStore.suspend() }
        candidateStore = nil; pendingLocalStore = nil; pendingArchive = nil; pendingToken = nil
        if activeStore == nil { optedIn = false; observations = []; currentStatus = .localOnly }
    }
    /// 클라우드 원본을 다른 로컬 공간으로 자동 복사하지 않는다. 이전 로컬 공간으로 돌아간다.
    public func disable() async throws -> MirrorStore {
        generation += 1; optedIn = false
        if let root = rootDirectory { try Self.removePointer(root: root) }
        if let activeStore { try await activeStore.suspend() }
        if let candidateStore { try await candidateStore.suspend() }
        activeStore = nil; candidateStore = nil; pendingArchive = nil; pendingToken = nil; pendingLocalStore = nil
        fingerprint = nil; observations = []; runningEvents = [:]; observedStoreIDs = []
        currentStatus = .localOnly
        return try await MirrorStore(configuration: localConfiguration)
    }
    public func verifyActiveAccount() async -> Bool {
        guard optedIn, let expected = fingerprint, let identifier = setup.containerIdentifier else { return false }
        do {
            guard let actual = try await Self.inspectAccount(containerIdentifier: identifier),
                  CloudSyncPolicy.accountMatches(expected: expected, observed: actual) else {
                await handleAccountChanged(); return false
            }
            return true
        } catch { currentStatus = .failed(Self.failure(error)); return false }
    }
    public func cloudDeletionStatus(confirmedTwice: Bool) async -> CloudDeletionStatus {
        guard setup.containerIdentifier != nil, setup.appGroupIdentifier != nil else { return .configurationRequired }
        guard confirmedTwice else { return .requiresDoubleConfirmation }
        let verified = await verifyActiveAccount()
        // 권위 있는 epoch 전환과 오프라인 재업로드 게이트를 구현·실기기 검증하기 전 purge를 실행하지 않는다.
        return CloudSyncPolicy.deletion(confirmedTwice: true, activeAccountVerified: verified)
    }

    /// opt-in pointer가 없으면 계정 API를 부르지 않는다. 확장도 같은 계정별 저장소를 연다.
    public static func resolveActiveConfiguration(appGroupIdentifier: String, deviceID: String,
                                                   expectedContainerIdentifier: String? = nil) async throws -> StoreConfiguration? {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw CloudSyncServiceError.configurationRequired
        }
        let url = pointerURL(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let pointer = try JSONDecoder().decode(ActiveCloudPointer.self, from: Data(contentsOf: url))
        guard pointer.version == 1, pointer.optedIn, !pointer.transitionRequired,
              pointer.accountFingerprint.count == 64,
              pointer.accountFingerprint.allSatisfy({ "0123456789abcdef".contains($0) }),
              !pointer.workspaceKey.isEmpty, !pointer.workspaceEpoch.isEmpty else {
            throw CloudSyncServiceError.accountTransitionRequired
        }
        if let expectedContainerIdentifier, pointer.containerIdentifier != expectedContainerIdentifier {
            throw CloudSyncServiceError.configurationRequired
        }
        guard let observed = try await inspectAccount(containerIdentifier: pointer.containerIdentifier),
              CloudSyncPolicy.accountMatches(expected: pointer.accountFingerprint, observed: observed) else {
            throw CloudSyncServiceError.accountTransitionRequired
        }
        let configuration = StoreConfiguration(directory: accountDirectory(root: root, fingerprint: observed),
            workspaceKey: pointer.workspaceKey, workspaceEpoch: pointer.workspaceEpoch, deviceID: deviceID,
            cloudSync: .init(containerIdentifier: pointer.containerIdentifier, accountScope: observed),
            initialTimeZoneID: pointer.initialTimeZoneID, initialPolicyRevision: pointer.initialPolicyRevision)
        // 계정 조회 중 host가 전환 pointer를 썼으면 이전 계정으로 열지 않는다.
        let current = try JSONDecoder().decode(ActiveCloudPointer.self, from: Data(contentsOf: url))
        guard current.optedIn, !current.transitionRequired, current.accountFingerprint == observed,
              current.workspaceEpoch == pointer.workspaceEpoch else { throw CloudSyncServiceError.accountTransitionRequired }
        return configuration
    }

    private func missingPrerequisites() -> [CloudPrerequisite] {
        var missing: [CloudPrerequisite] = []
        if setup.containerIdentifier?.hasPrefix("iCloud.") != true { missing.append(.cloudContainerIdentifier) }
        if setup.appGroupIdentifier?.hasPrefix("group.") != true { missing.append(.appGroupIdentifier) }
        if setup.workspaceEpoch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append(.stableWorkspaceEpoch) }
        return missing
    }
    private func handleAccountChanged() async {
        guard optedIn else { return }
        generation += 1
        currentStatus = .accountTransitionRequired
        if let root = rootDirectory, let identifier = setup.containerIdentifier, let fingerprint {
            let config = activeStore?.configuration ?? candidateStore?.configuration ?? localConfiguration
            let pointer = ActiveCloudPointer(version: 1, optedIn: true, transitionRequired: true,
                containerIdentifier: identifier, accountFingerprint: fingerprint,
                workspaceKey: config.workspaceKey, workspaceEpoch: config.workspaceEpoch,
                initialTimeZoneID: config.initialTimeZoneID, initialPolicyRevision: config.initialPolicyRevision)
            try? Self.write(pointer, root: root)
        }
        if let activeStore { try? await activeStore.suspend() }
        if let candidateStore { try? await candidateStore.suspend() }
        activeStore = nil; candidateStore = nil; pendingArchive = nil; pendingToken = nil; pendingLocalStore = nil
        observedStoreIDs = []; runningEvents = [:]
    }
    private func installObservers() {
        guard observations.isEmpty else { return }
        let account = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
            Task { await self?.handleAccountChanged() }
        }
        let events = NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
                                                            object: nil, queue: nil) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            let phase: CloudMirrorPhase
            switch event.type { case .setup: phase = .setup; case .import: phase = .importing; case .export: phase = .exporting
            @unknown default: return }
            let notice = CloudEventNotice(identifier: event.identifier, storeIdentifier: event.storeIdentifier,
                event: CloudMirrorEvent(phase: phase, endedAt: event.endDate, succeeded: event.succeeded,
                                       failure: event.error.map(Self.failure)))
            Task { await self?.consume(notice) }
        }
        observations = [CloudNotificationObservation(account), CloudNotificationObservation(events)]
    }
    private func consume(_ notice: CloudEventNotice) {
        guard optedIn, activeStore != nil, observedStoreIDs.contains(notice.storeIdentifier) else { return }
        if notice.event.endedAt == nil { runningEvents[notice.identifier] = notice.event.phase }
        else { runningEvents.removeValue(forKey: notice.identifier) }
        currentStatus = CloudSyncPolicy.next(after: notice.event)
        if notice.event.succeeded, let remaining = runningEvents.values.sorted(by: { $0.rawValue < $1.rawValue }).first {
            currentStatus = .synchronizing(remaining)
        }
    }
    private struct AccountUnavailable: Error { let availability: CloudAccountAvailability }
    private static func inspectAccount(containerIdentifier: String) async throws -> String? {
        let container = CKContainer(identifier: containerIdentifier)
        let availability = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CloudAccountAvailability, any Error>) in
            container.accountStatus { status, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: CloudAccountAvailability(status)) }
            }
        }
        guard availability == .available else {
            if availability == .noAccount { return nil }
            throw AccountUnavailable(availability: availability)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            container.fetchUserRecordID { record, error in
                if let error { continuation.resume(throwing: error) }
                else if let record {
                    do { continuation.resume(returning: try CanonicalDigest.hash([containerIdentifier, record.recordName])) }
                    catch { continuation.resume(throwing: error) }
                } else { continuation.resume(throwing: AccountUnavailable(availability: .couldNotDetermine)) }
            }
        }
    }
    private static func failure(_ error: any Error) -> CloudSyncFailure {
        if let error = error as? CKError {
            switch error.code {
            case .networkFailure, .networkUnavailable: return .networkUnavailable
            case .quotaExceeded: return .quotaExceeded
            case .notAuthenticated: return .notAuthenticated
            case .permissionFailure: return .permissionDenied
            case .serviceUnavailable, .requestRateLimited, .zoneBusy: return .serviceUnavailable
            default: return .unknown
            }
        }
        if error is StoreError { return .persistenceFailure }
        return .unknown
    }
    private static func configuration(root: URL, account: String, setup: CloudSyncSetup,
                                      base: StoreConfiguration, policy: PlanningPolicy) -> StoreConfiguration {
        StoreConfiguration(directory: accountDirectory(root: root, fingerprint: account),
            workspaceKey: base.workspaceKey, workspaceEpoch: setup.workspaceEpoch, deviceID: base.deviceID,
            cloudSync: .init(containerIdentifier: setup.containerIdentifier ?? "", accountScope: account),
            initialTimeZoneID: policy.timeZoneID, initialPolicyRevision: policy.revision)
    }
    private static func accountDirectory(root: URL, fingerprint: String) -> URL {
        root.appendingPathComponent("Mirror/accounts", isDirectory: true).appendingPathComponent(fingerprint, isDirectory: true)
    }
    private static func pointerURL(root: URL) -> URL { root.appendingPathComponent("Mirror/ActiveCloud.json") }
    private static func write(_ pointer: ActiveCloudPointer, root: URL) throws {
        let url = pointerURL(root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CanonicalDigest.data(pointer).write(to: url, options: .atomic)
    }
    private static func removePointer(root: URL) throws {
        let url = pointerURL(root: root)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
