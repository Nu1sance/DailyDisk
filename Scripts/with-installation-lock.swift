// Source-installation utility. Runs as the invoking user, never with sudo.
// Compiled/interpreted by the Swift toolchain already required to build DailyDisk.
import Darwin
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}
guard getuid() != 0 else { fail("run source installation as your normal user, not with sudo") }
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 4 else { fail("invalid installation lock arguments") }
let root = URL(fileURLWithPath: arguments[0])
do {
    var existing = stat()
    if lstat(root.path, &existing) != 0 {
        guard errno == ENOENT else { fail("cannot inspect Control directory") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    guard lstat(root.path, &existing) == 0, existing.st_uid == getuid(),
          existing.st_mode & S_IFMT == S_IFDIR, existing.st_mode & 0o077 == 0
    else { fail("unsafe Control directory") }
    var descriptors: [Int32] = []
    // Keep both locks until the installer exits. Work lock also excludes helpers
    // from old builds that predate the private installation lock.
    for name in [".installation.lock", ".update-work.lock"] {
        let fd = open(root.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { fail("cannot open installation coordination file") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0
        else { fail("unsafe installation coordination file") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { fail("scan or installation is already running") }
        descriptors.append(fd)
    }
    // exec, rather than spawning a child, keeps the lock owner identical to
    // the installer process. A killed wrapper cannot leave an unlocked installer.
    for fd in descriptors {
        guard fcntl(fd, F_SETFD, 0) == 0 else { fail("cannot transfer installation lease") }
    }
    let command = ["/bin/bash", arguments[1], "--locked", arguments[2], arguments[3]]
    var argv = command.map { strdup($0) }
    argv.append(nil)
    execv("/bin/bash", &argv)
    fail("cannot execute source installer")
} catch { fail("cannot start source installation: \(error)") }
