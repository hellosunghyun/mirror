import Foundation
import Darwin

/// 클라우드 활성화는 계정 확인과 병합 안내를 마친 호출자가 명시적으로 선택한다.
public struct CloudSyncConfiguration: Hashable, Sendable {
    public let containerIdentifier: String
    public let accountScope: String

    public init(containerIdentifier: String, accountScope: String) {
        self.containerIdentifier = containerIdentifier
        self.accountScope = accountScope
    }
}

public struct StoreConfiguration: Sendable {
    public let directory: URL
    public let workspaceKey: String
    public let workspaceEpoch: String
    public let deviceID: String
    public let cloudSync: CloudSyncConfiguration?
    public let lockTimeout: Duration
    public let initialTimeZoneID: String
    public let initialPolicyRevision: String

    public init(
        directory: URL,
        workspaceKey: String = "personal-v1",
        workspaceEpoch: String = "local-v1",
        deviceID: String,
        cloudSync: CloudSyncConfiguration? = nil,
        lockTimeout: Duration = .milliseconds(250),
        initialTimeZoneID: String = "Asia/Seoul",
        initialPolicyRevision: String = "policy-v1"
    ) {
        self.directory = directory
        self.workspaceKey = workspaceKey
        self.workspaceEpoch = workspaceEpoch
        self.deviceID = deviceID
        self.cloudSync = cloudSync
        self.lockTimeout = lockTimeout
        self.initialTimeZoneID = initialTimeZoneID
        self.initialPolicyRevision = initialPolicyRevision
    }

    /// 일반 앱의 로컬 전용 저장이다. 확장에서 이 함수를 공유 폴더 대신 사용하지 않는다.
    public static func localApplicationSupport(deviceID: String) throws -> StoreConfiguration {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let directory = base.appendingPathComponent("Mirror/local", isDirectory: true)
        return StoreConfiguration(directory: directory, workspaceEpoch: try existingEpoch(in: directory), deviceID: deviceID)
    }

    /// 서명/entitlement 누락을 별도 로컬 폴더로 숨기지 않는다.
    public static func appGroup(identifier: String, deviceID: String) throws -> StoreConfiguration {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            throw StoreError.appGroupUnavailable
        }
        let local = directory.appendingPathComponent("Mirror/local", isDirectory: true)
        return StoreConfiguration(directory: local, workspaceEpoch: try existingEpoch(in: local), deviceID: deviceID)
    }

    private static func existingEpoch(in directory: URL) throws -> String {
        let url = directory.appendingPathComponent("StorageIdentity.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return "local-v1" }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let epoch = object["workspaceEpoch"] as? String, !epoch.isEmpty else { throw StoreError.invalidConfiguration }
        return epoch
    }
}

public enum StoreError: Error, Equatable, Sendable {
    case appGroupUnavailable
    case invalidConfiguration
    case accountScopeMismatch
    case workspaceMismatch
    case obsoleteEpoch
    case busy
    case cancelled
    case incompatibleArchive
    case confirmationRequired
    case cloudConnectionRequiresTransition
    case protectedDataUnavailable
    case payloadConflict(String)
    case persistence(String)

    public static func classify(_ error: any Error) -> StoreError {
        if let typed = error as? StoreError { return typed }
        var current: NSError? = error as NSError
        for _ in 0..<6 {
            guard let value = current else { break }
            if (value.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(value.code)) ||
               (value.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(value.code)) {
                return .protectedDataUnavailable
            }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .persistence("로컬 저장소 처리에 실패했습니다.")
    }
}

public enum StoreSyncState: String, Codable, Sendable {
    case localOnly
    /// 옵션 활성화만 나타낸다. 실제 CloudKit 전송 완료를 뜻하지 않는다.
    case awaitingCloudSynchronization
    case accountTransitionRequired
}

/// 실제 저장 경계 장애를 주입한다. 기본값 .none은 생산 경로다.
public enum StoreFailurePoint: Sendable, Equatable {
    case none
    case beforeCanonicalSave
    case afterCanonicalSave
    case beforeReceiptSave
}

public struct ImportReport: Sendable, Equatable {
    public let inserted: Int
    public let duplicates: Int
    public let quarantined: Int
    public let projectionPending: Bool

    public init(inserted: Int, duplicates: Int, quarantined: Int, projectionPending: Bool = false) {
        self.inserted = inserted
        self.duplicates = duplicates
        self.quarantined = quarantined
        self.projectionPending = projectionPending
    }
}
