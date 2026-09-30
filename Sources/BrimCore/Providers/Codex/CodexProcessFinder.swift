import Darwin
import Foundation

/// Which running Codex process writes each session's rollout file, so a Codex
/// session can be brought forward the way a Claude Code one is.
///
/// Codex keeps a session's rollout file open for as long as the session runs.
/// Only processes named `codex` (or `codex-…`) are looked at, and of those only
/// the names of their open files: nothing is read from them, and the answer is
/// held in memory for one poll.
struct CodexProcessFinder {
    var processIDs: () -> [Int32]
    var name: (Int32) -> String?
    var openFiles: (Int32) -> [String]

    /// Session key (the rollout file's name, without `.jsonl`) → the process
    /// holding it open.
    func owners() -> [String: Int32] {
        var owners: [String: Int32] = [:]
        for pid in processIDs() {
            guard let name = name(pid), name == "codex" || name.hasPrefix("codex-") else { continue }
            for path in openFiles(pid) {
                let file = (path as NSString).lastPathComponent
                guard file.hasPrefix("rollout-"), file.hasSuffix(".jsonl") else { continue }
                owners[String(file.dropLast(".jsonl".count))] = pid
            }
        }
        return owners
    }

    static var system: CodexProcessFinder {
        CodexProcessFinder(processIDs: allProcessIDs, name: processName, openFiles: openFilePaths)
    }

    static func allProcessIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return filled > 0 ? Array(pids.prefix(Int(filled))) : []
    }

    static func processName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Paths of the files `pid` has open. Paths only: none is opened or read.
    static func openFilePaths(_ pid: Int32) -> [String] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let filled = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard filled > 0 else { return [] }
        var paths: [String] = []
        let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for descriptor in descriptors.prefix(Int(filled) / stride)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize else {
                continue
            }
            paths.append(withUnsafeBytes(of: info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) })
        }
        return paths
    }
}
