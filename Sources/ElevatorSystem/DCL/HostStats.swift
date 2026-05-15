import Foundation
import Darwin

/// Thin wrapper around sysctl / Mach host calls so the DCL "OpenVMS VAX"
/// shell can present numbers that actually reflect the Mac it is running on.
@MainActor
final class HostStats {
    static let shared = HostStats()

    let bootDate: Date
    let physicalMemoryBytes: UInt64
    let pageSize: UInt64
    let totalPages: UInt64
    let processorCount: Int
    let activeProcessorCount: Int
    let cpuModel: String
    let cpuFrequencyMHz: Int

    private var lastTicks: host_cpu_load_info?

    private init() {
        // Boot time -- sysctl kern.boottime returns a struct timeval
        var bt = timeval()
        var btSize = MemoryLayout<timeval>.stride
        if sysctlbyname("kern.boottime", &bt, &btSize, nil, 0) == 0, bt.tv_sec > 0 {
            let secs = TimeInterval(bt.tv_sec) + TimeInterval(bt.tv_usec) / 1_000_000.0
            self.bootDate = Date(timeIntervalSince1970: secs)
        } else {
            self.bootDate = Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
        }

        self.physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
        self.processorCount = ProcessInfo.processInfo.processorCount
        self.activeProcessorCount = ProcessInfo.processInfo.activeProcessorCount

        var ps: vm_size_t = 0
        host_page_size(mach_host_self(), &ps)
        let pageBytes = UInt64(ps == 0 ? 4096 : ps)
        self.pageSize = pageBytes
        self.totalPages = self.physicalMemoryBytes / pageBytes

        // CPU brand string -- Intel exposes machdep.cpu.brand_string;
        // Apple Silicon exposes hw.model and machdep.cpu.brand_string is empty.
        self.cpuModel = HostStats.readSysctlString("machdep.cpu.brand_string")
            ?? HostStats.readSysctlString("hw.model")
            ?? "Unknown CPU"

        // Frequency -- only Intel exposes hw.cpufrequency
        var freq: UInt64 = 0
        var freqSize = MemoryLayout<UInt64>.stride
        if sysctlbyname("hw.cpufrequency", &freq, &freqSize, nil, 0) == 0, freq > 0 {
            self.cpuFrequencyMHz = Int(freq / 1_000_000)
        } else {
            self.cpuFrequencyMHz = 0
        }
    }

    // MARK: -- Uptime

    func uptime(at now: Date = Date()) -> TimeInterval {
        return max(0, now.timeIntervalSince(bootDate))
    }

    // MARK: -- Load average

    func loadAverages() -> (one: Double, five: Double, fifteen: Double) {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return (loads[0], loads[1], loads[2])
    }

    // MARK: -- VM stats

    struct VMStats {
        let freePages: UInt64
        let activePages: UInt64
        let inactivePages: UInt64
        let wiredPages: UInt64
        let compressedPages: UInt64
        let totalPages: UInt64
        let pageSize: UInt64

        var inUsePages: UInt64 { activePages + wiredPages + compressedPages }
        var modifiedPages: UInt64 { inactivePages }
    }

    func vmStats() -> VMStats {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            return VMStats(freePages: 0, activePages: 0, inactivePages: 0,
                           wiredPages: 0, compressedPages: 0,
                           totalPages: totalPages, pageSize: pageSize)
        }
        return VMStats(
            freePages: UInt64(stats.free_count),
            activePages: UInt64(stats.active_count),
            inactivePages: UInt64(stats.inactive_count),
            wiredPages: UInt64(stats.wire_count),
            compressedPages: UInt64(stats.compressor_page_count),
            totalPages: totalPages,
            pageSize: pageSize
        )
    }

    // MARK: -- CPU usage

    /// Percentages for user / system / idle / nice. The first call returns
    /// cumulative-since-boot percentages; subsequent calls return the delta
    /// since the previous sample, which is what `top`-style displays show.
    struct CPUUsage {
        let user: Double
        let system: Double
        let idle: Double
        let nice: Double

        var busy: Double { 100.0 - idle }
    }

    func cpuUsage() -> CPUUsage {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            return CPUUsage(user: 0, system: 0, idle: 100, nice: 0)
        }

        let baseline = lastTicks ?? host_cpu_load_info()
        lastTicks = info

        // host_cpu_load_info.cpu_ticks indexed by CPU_STATE_USER (0),
        // CPU_STATE_SYSTEM (1), CPU_STATE_IDLE (2), CPU_STATE_NICE (3).
        // The field is imported into Swift as a homogeneous tuple of UInt32.
        let userDelta = Double(info.cpu_ticks.0 &- baseline.cpu_ticks.0)
        let sysDelta  = Double(info.cpu_ticks.1 &- baseline.cpu_ticks.1)
        let idleDelta = Double(info.cpu_ticks.2 &- baseline.cpu_ticks.2)
        let niceDelta = Double(info.cpu_ticks.3 &- baseline.cpu_ticks.3)
        let total = max(1.0, userDelta + sysDelta + idleDelta + niceDelta)

        return CPUUsage(
            user:   userDelta * 100.0 / total,
            system: sysDelta  * 100.0 / total,
            idle:   idleDelta * 100.0 / total,
            nice:   niceDelta * 100.0 / total
        )
    }

    // MARK: -- Process count

    func processCount() -> Int {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length: size_t = 0
        if sysctl(&name, 4, nil, &length, nil, 0) != 0 || length == 0 {
            return 0
        }
        return Int(length) / MemoryLayout<kinfo_proc>.stride
    }

    // MARK: -- Disk volumes

    struct VolumeInfo {
        let name: String
        let totalBytes: Int
        let freeBytes: Int
        let isBoot: Bool

        var vmsLabel: String {
            let clean = name.uppercased()
                .replacingOccurrences(of: " ", with: "_")
                .filter { $0.isLetter || $0.isNumber || $0 == "_" }
            return String(clean.prefix(12))
        }

        var freeBlocks: Int { freeBytes / 512 }
        var totalBlocks: Int { totalBytes / 512 }
    }

    func mountedVolumes() -> [VolumeInfo] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsRootFileSystemKey
        ]
        guard let urls = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) else { return [] }

        var volumes: [VolumeInfo] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys),
                  let name = values.volumeName,
                  let total = values.volumeTotalCapacity,
                  let free = values.volumeAvailableCapacity else { continue }
            let boot = values.volumeIsRootFileSystem ?? false
            volumes.append(VolumeInfo(name: name, totalBytes: total,
                                      freeBytes: free, isBoot: boot))
        }

        volumes.sort { a, b in
            if a.isBoot != b.isBoot { return a.isBoot }
            return a.name < b.name
        }
        return volumes
    }

    // MARK: -- helpers

    private static func readSysctlString(_ name: String) -> String? {
        var size: size_t = 0
        if sysctlbyname(name, nil, &size, nil, 0) != 0 || size == 0 { return nil }
        var buf = [CChar](repeating: 0, count: size)
        if sysctlbyname(name, &buf, &size, nil, 0) != 0 { return nil }
        let s = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
