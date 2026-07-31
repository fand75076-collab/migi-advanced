import Darwin
import Foundation

enum MigiInstanceControl {
    static let notificationName = Notification.Name(
        "local.fdk.migi-advanced.request-show"
    )
    static let notificationObject = "local.fdk.migi-advanced"

    static func requestShowExistingInstance() {
        DistributedNotificationCenter.default().postNotificationName(
            notificationName,
            object: notificationObject,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

enum MigiSingleInstanceAcquisition {
    case acquired(MigiSingleInstanceGate)
    case alreadyRunning
    case failed(String)
}

/// Holds an atomic advisory lock shared by every copy of Migi Advanced.
///
/// LaunchServices can run two bundles with the same identifier when they live
/// at different paths. A kernel lock closes that gap without a racy process
/// lookup. The lock file is intentionally never unlinked: closing the file
/// descriptor releases the lock, while retaining the inode avoids split-lock
/// races between an old and newly created file.
final class MigiSingleInstanceGate {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        Darwin.close(descriptor)
    }

    static func acquireDefault() -> MigiSingleInstanceAcquisition {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        else {
            return .failed("Unable to resolve the user Application Support directory.")
        }
        let lockURL = applicationSupport
            .appendingPathComponent("Migi Advanced", isDirectory: true)
            .appendingPathComponent("instance.lock", isDirectory: false)
        return acquire(at: lockURL)
    }

    static func acquire(at lockURL: URL) -> MigiSingleInstanceAcquisition {
        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return .failed("Unable to create the instance-lock directory: \(error)")
        }

        let flags = O_CREAT | O_RDWR | O_CLOEXEC | O_EXLOCK | O_NONBLOCK
        let permissions = mode_t(S_IRUSR | S_IWUSR)
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, flags, permissions)
        }
        if descriptor >= 0 {
            return .acquired(MigiSingleInstanceGate(descriptor: descriptor))
        }

        if errno == EWOULDBLOCK || errno == EAGAIN {
            return .alreadyRunning
        }
        return .failed(
            "Unable to acquire the instance lock at \(lockURL.path): errno \(errno)."
        )
    }
}
