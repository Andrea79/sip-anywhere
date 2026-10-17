import AppKit
import CryptoKit
import Foundation

/// Makes sure only one copy of SIP Anywhere (any version or build) is registered
/// with a given SIP account at a time: two registrations of the same line from the same
/// network can make the provider stop answering both.
///
/// A copy that goes online takes an exclusive lock on a file named after the account,
/// in a folder shared by every version. The system releases the lock when the app
/// quits or crashes, so a stale lock cannot block registration.
final class RegistrationLock {
    struct Holder {
        var pid: pid_t
        var name: String
    }

    private var fd: Int32 = -1
    private var account = ""

    private static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SIP Anywhere/Registrations", isDirectory: true)

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "SIP Anywhere"
    }

    private static func url(for account: String) -> URL {
        let digest = SHA256.hash(data: Data(account.lowercased().utf8))
        return directory.appendingPathComponent(digest.prefix(8).map { String(format: "%02x", $0) }.joined() + ".lock")
    }

    /// Takes the lock for `account`. Returns nil on success (or if this copy already holds
    /// it), otherwise the copy that holds it.
    func acquire(account: String) -> Holder? {
        if fd >= 0 && self.account == account { return nil }
        release()
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let path = Self.url(for: account).path
        let f = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard f >= 0 else { return nil }    // cannot check: do not block registration
        if flock(f, LOCK_EX | LOCK_NB) != 0 {
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            close(f)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let pid = lines.first.flatMap { pid_t($0) } ?? 0
            let name = lines.count > 1 && !lines[1].isEmpty ? String(lines[1]) : "Another copy of SIP Anywhere"
            return Holder(pid: pid, name: name)
        }
        let owner = "\(getpid())\n\(Self.appName)\n"
        ftruncate(f, 0)
        _ = owner.withCString { write(f, $0, strlen($0)) }
        fd = f
        self.account = account
        return nil
    }

    func release() {
        guard fd >= 0 else { return }
        ftruncate(fd, 0)
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
        account = ""
    }
}

/// Why registering was not started, shown as an alert.
struct RegistrationConflict: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    /// The other copy of the app, which can be asked to quit.
    var otherApp: NSRunningApplication?
    /// Registering anyway is allowed (the other app may use another account).
    var canRegisterAnyway = false

    var otherName: String { otherApp?.localizedName ?? "the other copy" }
}
