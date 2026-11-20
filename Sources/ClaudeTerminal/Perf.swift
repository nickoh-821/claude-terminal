import Foundation
import QuartzCore

/// CT_PERF=1: wall-clock timings for the transcript overlay, written to
/// stderr as `perf <label> <ms> [extra]`. Off by default and costs one
/// branch per call. `--perf-bench` (PerfBench.swift) reads the samples back.
enum Perf {
    static let enabled = ProcessInfo.processInfo.environment["CT_PERF"] == "1"
        || CommandLine.arguments.contains("--perf-bench")

    private static let lock = NSLock()
    private static var samples: [String: [Double]] = [:]

    static func now() -> CFTimeInterval { CACurrentMediaTime() }

    static func record(_ label: String, since start: CFTimeInterval, _ extra: String = "") {
        guard enabled else { return }
        let ms = (now() - start) * 1000
        lock.lock()
        samples[label, default: []].append(ms)
        lock.unlock()
        let line = String(format: "perf %@ %.2f ms", label, ms) + (extra.isEmpty ? "" : "  " + extra) + "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    @discardableResult
    static func time<T>(_ label: String, _ extra: String = "", _ body: () -> T) -> T {
        guard enabled else { return body() }
        let start = now()
        let result = body()
        record(label, since: start, extra)
        return result
    }

    /// Hands back and clears everything recorded so far.
    static func drain() -> [String: [Double]] {
        lock.lock()
        defer { samples = [:]; lock.unlock() }
        return samples
    }

    /// Resident memory of this process, in MB.
    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }
}
