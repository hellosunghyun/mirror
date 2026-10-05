import Foundation
import MirrorData
import MirrorDomain

#if os(macOS)
import Darwin

private enum ProbeError: Error { case arguments, timeout, unexpectedResult }

private struct ProbeReport: Codable {
    let state: CommandResultState
    let operationID: String?
    let taskCount: Int?
    let recordCount: Int?
}

/// 합성 테스트 경로와 봉투만 받는다. 원본 내용과 파일 경로를 CLI 로그에 출력하지 않는다.
@main
private enum MirrorStoreProbe {
    static func main() async {
        var stage = "arguments"
        do {
            let arguments = CommandLine.arguments
            if arguments.count == 5, arguments[1] == "benchmark" {
                stage = "performance-baseline"
                try await PerformanceBaseline.run(directory: URL(fileURLWithPath: arguments[2], isDirectory: true),
                    reportURL: URL(fileURLWithPath: arguments[3]), metadataURL: URL(fileURLWithPath: arguments[4]))
                return
            }
            guard arguments.count == 8,
                  ["race", "after-canonical"].contains(arguments[1]),
                  let serviceSeconds = Double(arguments[7]), serviceSeconds.isFinite else { throw ProbeError.arguments }
            let mode = arguments[1]
            let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
            let envelopeURL = URL(fileURLWithPath: arguments[3])
            let readyURL = URL(fileURLWithPath: arguments[4])
            let startURL = URL(fileURLWithPath: arguments[5])
            let reportURL = URL(fileURLWithPath: arguments[6])
            // 외부 봉투는 capturedAt을 보존하지 않는다. 생산 서비스에 주입할 시각은 테스트 입력으로 따로 받는다.
            let serviceInstant = Date(timeIntervalSince1970: serviceSeconds)
            stage = "envelope"
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let envelope = try decoder.decode(CommandEnvelope.self, from: Data(contentsOf: envelopeURL))
            stage = "store-open"
            let configuration = StoreConfiguration(directory: directory, workspaceEpoch: envelope.workspaceEpoch,
                deviceID: "11111111-1111-4111-8111-111111111111", lockTimeout: .seconds(5))
            let store = try await MirrorStore(configuration: configuration)

            if mode == "race" {
                stage = "race-start"
                try Data("ready".utf8).write(to: readyURL, options: .atomic)
                try await waitForStart(startURL, timeout: .seconds(20))
                stage = "race-command"
                let result = await store.execute(envelope, at: serviceInstant)
                guard [.locallyCommitted, .alreadyApplied].contains(result.state),
                      result.operationID != nil else {
                    try write(ProbeReport(state: result.state, operationID: result.operationID,
                                          taskCount: nil, recordCount: nil), to: reportURL)
                    throw ProbeError.unexpectedResult
                }
                let snapshot = try await store.snapshot()
                try write(ProbeReport(state: result.state, operationID: result.operationID,
                                      taskCount: snapshot.tasks.count, recordCount: snapshot.records.count), to: reportURL)
                print("probe finished state=\(result.state.rawValue) tasks=\(snapshot.tasks.count) records=\(snapshot.records.count)")
            } else {
                stage = "canonical-command"
                let result = await store.execute(envelope, at: serviceInstant, failurePoint: .afterCanonicalSave)
                guard result.state == .committedProjectionPending,
                      result.operationID != nil else {
                    try write(ProbeReport(state: result.state, operationID: result.operationID,
                                          taskCount: nil, recordCount: nil), to: reportURL)
                    throw ProbeError.unexpectedResult
                }
                // snapshot/rebuild를 호출하면 투영 전 종료 경계가 사라진다. 원본 save 결과만 기록한다.
                try write(ProbeReport(state: result.state, operationID: result.operationID,
                                      taskCount: nil, recordCount: nil), to: reportURL)
                try Data("canonical-ready".utf8).write(to: readyURL, options: .atomic)
                print("probe ready state=committedProjectionPending")
                stage = "canonical-kill-wait"
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(30))
                while clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
                // 부모가 실제 SIGKILL하지 않으면 자연 종료를 성공으로 처리하지 않는다.
                throw ProbeError.timeout
            }
        } catch {
            FileHandle.standardError.write(Data("probe failed stage=\(stage)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func waitForStart(_ url: URL, timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard clock.now < deadline else { throw ProbeError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func write(_ report: ProbeReport, to url: URL) throws {
        try JSONEncoder().encode(report).write(to: url, options: .atomic)
    }
}
#else
@main
private enum MirrorStoreProbe {
    static func main() {
        fatalError("MirrorStoreProbe는 macOS의 프로세스 회귀 지원 실행 파일입니다.")
    }
}
#endif
