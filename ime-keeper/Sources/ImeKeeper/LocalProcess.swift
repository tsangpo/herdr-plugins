import Darwin
import Foundation

struct LocalProcessIdentity: Equatable {
    let parentPID: Int32
    let executableName: String
}

/// The built-in Neovim TUI can be the foreground process while the Lua core
/// runs as its direct `nvim --embed` child in another process group. Resolve
/// this relationship from the kernel, never from the editor event payload.
func localProcessIdentity(pid: Int32) -> LocalProcessIdentity? {
    guard pid > 0 else { return nil }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    // PROC_PIDPATHINFO_MAXSIZE is a C expression macro not imported by Swift.
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
    return LocalProcessIdentity(
        parentPID: Int32(info.pbi_ppid),
        executableName: (String(cString: path) as NSString).lastPathComponent
    )
}

func editorIsForeground(
    pid: Int32, processes: [ForegroundProcess],
    identity: (Int32) -> LocalProcessIdentity? = localProcessIdentity
) -> Bool {
    guard pid > 0 else { return false }
    if processes.contains(where: { $0.pid == pid }) { return true }
    guard let core = identity(pid), core.executableName == "nvim" else { return false }
    return processes.contains { process in
        guard process.pid == core.parentPID else { return false }
        return [process.name, process.argv0].compactMap { $0 }
            .contains { ($0 as NSString).lastPathComponent == "nvim" }
    }
}
