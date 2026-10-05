import Darwin
import Foundation

/// actor 밖의 프로세스도 같은 advisory lock에 참여한다. 파일 존재 여부는 잠금이 아니다.
final class ProcessWriteGate: Sendable {
    private let url: URL
    private let timeout: Duration

    init(url: URL, timeout: Duration) {
        self.url = url
        self.timeout = timeout
    }

    func acquire() async throws -> ProcessWriteLease {
        let acquisition = GateAcquisition()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [url, timeout] in
                    do {
                        let fd = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
                        guard fd >= 0 else {
                            if errno == EACCES || errno == EPERM { throw StoreError.protectedDataUnavailable }
                            throw StoreError.persistence("쓰기 조율 파일을 열 수 없습니다.")
                        }
                        var handedOff = false
                        defer { if !handedOff { close(fd) } }
                        let clock = ContinuousClock()
                        let deadline = clock.now.advanced(by: timeout)
                        while true {
                            guard !acquisition.cancelled else { throw StoreError.cancelled }
                            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                                guard !acquisition.cancelled else {
                                    flock(fd, LOCK_UN)
                                    throw StoreError.cancelled
                                }
                                handedOff = true
                                continuation.resume(returning: ProcessWriteLease(fileDescriptor: fd))
                                return
                            }
                            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                                throw StoreError.persistence("쓰기 조율 잠금을 얻을 수 없습니다.")
                            }
                            guard clock.now < deadline else { throw StoreError.busy }
                            // main thread가 아닌 전용 작업에서 짧게 재시도한다.
                            usleep(5_000)
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            acquisition.cancel()
        }
    }
}

private final class GateAcquisition: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    var cancelled: Bool { lock.withLock { isCancelled } }
    func cancel() { lock.withLock { isCancelled = true } }
}

final class ProcessWriteLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?
    init(fileDescriptor: Int32) { descriptor = fileDescriptor }

    func release() {
        lock.withLock {
            guard let descriptor else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            self.descriptor = nil
        }
    }

    deinit { release() }
}
