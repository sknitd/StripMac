import AppKit
import Darwin

/// Samples each app's memory footprint as a share of physical RAM, every 2 s while running.
///
/// An app's helpers (browser renderers, web content, XPC services) are counted toward it, using
/// the same "responsible process" grouping as Activity Monitor. Sampling runs off the main thread.
@MainActor
final class RAMMonitor {
    struct Usage { let bytes: UInt64; let percent: Double }

    private(set) var usage: [pid_t: Usage] = [:]
    var onUpdate: (() -> Void)?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "StripMac.ram", qos: .utility)

    func start() {
        RAMMonitor.live = self
        guard timer == nil else { return }
        sample()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    private var sampling = false

    private func sample() {
        guard !sampling else { return }
        sampling = true
        queue.async {
            let sums = Self.footprintsByResponsiblePID()
            let total = Double(ProcessInfo.processInfo.physicalMemory)
            let result = sums.mapValues { Usage(bytes: $0, percent: Double($0) / total * 100) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { RAMMonitor.deliver(result) }
            }
        }
    }

    /// Hands a finished sample to the live monitor (the one the strip map owns).
    nonisolated(unsafe) private static weak var live: RAMMonitor?
    private static func deliver(_ result: [pid_t: Usage]) {
        guard let m = live else { return }
        m.sampling = false
        m.usage = result
        m.onUpdate?()
    }

    init() { }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    /// Private libsystem call Activity Monitor's grouping is based on; looked up at runtime.
    nonisolated private static let responsible: ResponsibleFn? = {
        guard let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(f, to: ResponsibleFn.self)
    }()

    /// Physical footprint of every readable process, summed by responsible pid.
    nonisolated private static func footprintsByResponsiblePID() -> [pid_t: UInt64] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 32)
        let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var sums: [pid_t: UInt64] = [:]
        for pid in pids.prefix(max(0, got)) where pid > 0 {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }   // other users' processes can't be read; skip them
            var owner = responsible?(pid) ?? pid
            if owner <= 0 { owner = pid }
            sums[owner, default: 0] += info.ri_phys_footprint
        }
        return sums
    }
}
