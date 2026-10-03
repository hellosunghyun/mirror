import Foundation
import CloudKit
import MirrorData
import Testing
@testable import MirrorSystem

@Suite("선택적 CloudKit 활성화와 계정·삭제 경계")
struct CloudBoundaryTests {
    @Test("명시적 opt-in과 실제 서명 설정이 모두 있어야 계정을 조회한다", arguments: [false, true])
    func inspectionNeedsOptIn(_ consented: Bool) {
        #expect(CloudSyncPolicy.mayInspectAccount(explicitOptIn: consented, configurationComplete: true) == consented)
        #expect(!CloudSyncPolicy.mayInspectAccount(explicitOptIn: consented, configurationComplete: false))
    }

    @Test("같은 로컬 계정 바인딩은 오프라인 저장을 허용하되 전환 latch가 있으면 중단한다")
    func localIdentityAndTransitionBoundary() {
        #expect(CloudSyncPolicy.mayUseVerifiedLocalAccount(optedIn: true, identityMatches: true, transitionRequired: false))
        #expect(!CloudSyncPolicy.mayUseVerifiedLocalAccount(optedIn: false, identityMatches: true, transitionRequired: false))
        #expect(!CloudSyncPolicy.mayUseVerifiedLocalAccount(optedIn: true, identityMatches: false, transitionRequired: false))
        #expect(!CloudSyncPolicy.mayUseVerifiedLocalAccount(optedIn: true, identityMatches: true, transitionRequired: true))
    }

    @Test("Apple 계정 상태를 별개의 제품 상태로 보존한다")
    func accountStatusesRemainDistinct() {
        #expect(CloudAccountAvailability(.available) == .available)
        #expect(CloudAccountAvailability(.noAccount) == .noAccount)
        #expect(CloudAccountAvailability(.restricted) == .restricted)
        #expect(CloudAccountAvailability(.temporarilyUnavailable) == .temporarilyUnavailable)
        #expect(CloudAccountAvailability(.couldNotDetermine) == .couldNotDetermine)
    }

    @Test("다른 계정 또는 미확인 계정은 기존 공간을 열지 않는다")
    func changedAccountRequiresTransition() {
        #expect(CloudSyncPolicy.accountMatches(expected: "account-a-fingerprint", observed: "account-a-fingerprint"))
        #expect(!CloudSyncPolicy.accountMatches(expected: "account-a-fingerprint", observed: "account-b-fingerprint"))
        #expect(!CloudSyncPolicy.accountMatches(expected: "", observed: ""))
    }

    @Test("미러링 시작은 import와 export와 setup을 구분한다", arguments: [CloudMirrorPhase.setup, .importing, .exporting])
    func mirrorsBeginInTheirOwnPhase(_ phase: CloudMirrorPhase) {
        #expect(CloudSyncPolicy.next(after: .init(phase: phase)) == .synchronizing(phase))
    }

    @Test("하나의 성공한 이벤트는 해당 이벤트 종료 시각만 보고한다")
    func eventCompletionDoesNotClaimEveryDeviceSynchronized() {
        let completed = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(CloudSyncPolicy.next(after: .init(phase: .exporting, endedAt: completed, succeeded: true))
            == .idle(lastSuccessfulEvent: completed))
        #expect(CloudSyncPolicy.next(after: .init(phase: .importing, endedAt: completed, succeeded: false))
            == .failed(.unknown))
    }

    @Test("실제 저장 성공과 독립적인 전송 오류를 보존한다", arguments: [CloudSyncFailure.networkUnavailable, .quotaExceeded, .notAuthenticated, .permissionDenied, .serviceUnavailable])
    func eventFailureRemainsSpecific(_ error: CloudSyncFailure) {
        #expect(CloudSyncPolicy.next(after: .init(phase: .exporting, endedAt: Date(timeIntervalSince1970: 100),
                                                 succeeded: false, failure: error)) == .failed(error))
    }

    @Test("이중 확인 없이 클라우드 삭제가 실행될 수 없다")
    func deletionRequiresDoubleConfirmation() {
        #expect(CloudSyncPolicy.deletion(confirmedTwice: false, activeAccountVerified: true) == .requiresDoubleConfirmation)
        #expect(CloudSyncPolicy.deletion(confirmedTwice: false, activeAccountVerified: false) == .requiresDoubleConfirmation)
    }

    @Test("계정이 확인돼도 미결정 epoch 권위와 오프라인 재업로드 검증은 삭제를 막는다")
    func deletionNeverFakesACompletedPurge() {
        #expect(CloudSyncPolicy.deletion(confirmedTwice: true, activeAccountVerified: true)
            == .blocked([.authoritativeEpochNotConfigured, .offlineResurrectionNotVerified]))
        #expect(CloudSyncPolicy.deletion(confirmedTwice: true, activeAccountVerified: false)
            == .blocked([.accountNotVerified, .authoritativeEpochNotConfigured, .offlineResurrectionNotVerified]))
    }

    @Test("상태 구독은 계정 API 없이 초기 로컬 상태를 제공한다")
    func statusSubscriptionHasInitialState() async {
        let service = CloudSyncService(localConfiguration: Self.configuration(),
            setup: CloudSyncSetup(containerIdentifier: nil, appGroupIdentifier: nil))
        let stream = await service.statuses()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .localOnly)
    }

    @Test("느린 상태 구독에는 오래된 초기값 대신 최신 설정 오류만 남는다")
    func statusSubscriptionKeepsLatestBoundedValue() async throws {
        let configuration = Self.configuration()
        let local = try await MirrorStore(configuration: configuration)
        let service = CloudSyncService(localConfiguration: configuration,
            setup: CloudSyncSetup(containerIdentifier: nil, appGroupIdentifier: nil))
        let stream = await service.statuses()
        let preview = await service.previewEnable(localStore: local, explicitOptIn: true,
                                                    at: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(preview == nil)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .configurationRequired([.cloudContainerIdentifier, .appGroupIdentifier]))
        try await local.suspend()
        try? FileManager.default.removeItem(at: configuration.directory)
    }

    @Test("상태 소비 취소는 추가 변화 없이 대기를 끝낸다")
    func statusSubscriptionCancellationFinishes() async {
        let service = CloudSyncService(localConfiguration: Self.configuration(),
            setup: CloudSyncSetup(containerIdentifier: nil, appGroupIdentifier: nil))
        let stream = await service.statuses()
        let consumer = Task {
            for await _ in stream {}
            return true
        }
        consumer.cancel()
        #expect(await consumer.value)
    }

    @Test("서비스 수명이 끝나면 상태 구독도 종료한다")
    func statusSubscriptionFollowsServiceLifetime() async {
        let stream = await Self.streamAfterServiceScopeEnds()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .localOnly)
        #expect(await iterator.next() == nil)
    }

    private static func streamAfterServiceScopeEnds() async -> AsyncStream<CloudSyncStatus> {
        let service = CloudSyncService(localConfiguration: configuration(),
            setup: CloudSyncSetup(containerIdentifier: nil, appGroupIdentifier: nil))
        return await service.statuses()
    }

    private static func configuration() -> StoreConfiguration {
        StoreConfiguration(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            deviceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    }

    @Test("서명 식별자가 없는 제품은 stable 기본 세대를 사용하되 설정 완료로 표시하지 않는다")
    func initialSetupHasNoInventedAppleIdentifiers() {
        let setup = CloudSyncSetup(containerIdentifier: nil, appGroupIdentifier: nil)
        #expect(setup.containerIdentifier == nil)
        #expect(setup.appGroupIdentifier == nil)
        #expect(setup.workspaceEpoch == "local-v1")
    }
}
