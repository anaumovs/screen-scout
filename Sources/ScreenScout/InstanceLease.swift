import Foundation
import Darwin

final class InstanceLease {
    private var descriptor: Int32 = -1
    let acquired: Bool
    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Screen Scout")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = open(directory.appendingPathComponent("clicker.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        acquired = descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }
    deinit { if descriptor >= 0 { if acquired { flock(descriptor, LOCK_UN) }; close(descriptor) } }
}
