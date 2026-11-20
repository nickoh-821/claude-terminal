import Foundation

/// Discovers the user's Claude Code projects from ~/.claude/projects metadata.
enum ClaudeProjects {
    struct Project {
        let name: String
        let path: String
    }

    static let projectsRoot = NSHomeDirectory() + "/.claude/projects"

    /// Claude Code names project dirs by replacing non-alphanumerics with "-".
    static func sanitized(_ path: String) -> String {
        String(path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    static func hasSessions(for path: String) -> Bool {
        let dir = projectsRoot + "/" + sanitized(path)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return false
        }
        return files.contains { $0.hasSuffix(".jsonl") }
    }

    /// Recent projects, newest session first. The cwd comes from session
    /// metadata, so directories with "-" in their names resolve correctly.
    static func recent(limit: Int = 10) -> [Project] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: projectsRoot) else { return [] }

        var newestByPath: [String: Date] = [:]
        for dir in dirs {
            let full = projectsRoot + "/" + dir
            guard let files = try? fm.contentsOfDirectory(atPath: full) else { continue }

            let sessions: [(file: String, mtime: Date)] = files
                .filter { $0.hasSuffix(".jsonl") }
                .compactMap { f in
                    let p = full + "/" + f
                    let m = (try? fm.attributesOfItem(atPath: p)[.modificationDate]) as? Date
                    return m.map { (p, $0) }
                }
                .sorted { $0.mtime > $1.mtime }

            guard let newest = sessions.first, let cwd = readCwd(newest.file) else { continue }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else { continue }

            if newestByPath[cwd] == nil || newestByPath[cwd]! < newest.mtime {
                newestByPath[cwd] = newest.mtime
            }
        }

        return newestByPath
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { Project(name: ($0.key as NSString).lastPathComponent, path: $0.key) }
    }

    private static func readCwd(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 262_144)
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", maxSplits: 8, omittingEmptySubsequences: true) {
            if let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let cwd = json["cwd"] as? String {
                return cwd
            }
        }
        return nil
    }
}
