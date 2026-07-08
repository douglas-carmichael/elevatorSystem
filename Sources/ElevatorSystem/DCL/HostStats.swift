import Foundation
import Darwin
import IOKit

/// Thin wrapper around sysctl / Mach host calls so the DCL "OpenVMS VAX"
/// shell can present numbers that actually reflect the Mac it is running on.
@MainActor
final class HostStats {
    static let shared = HostStats()

    let bootDate: Date
    let physicalMemoryBytes: UInt64
    /// Memory the VM manager actually accounts for (`hw.memsize_usable`).
    /// Slightly less than installed RAM because firmware/hardware reserve a
    /// slice; basing the page total on it keeps SHOW MEMORY self-consistent.
    let usableMemoryBytes: UInt64
    let pageSize: UInt64
    let totalPages: UInt64
    let processorCount: Int
    let activeProcessorCount: Int
    let cpuModel: String
    let cpuFrequencyMHz: Int

    private var lastTicks: host_cpu_load_info?
    private var lastVMRawSample: (raw: vm_statistics64, time: Date)?
    private var cachedVMRates: VMRates = .zero
    private var lastDriverSamples: [UInt64: DriverRawSample] = [:]
    private var lastBsdToDriverId: [String: UInt64] = [:]
    private var lastDiskSampleTime: Date?
    private var cachedDiskRates: [DiskRate] = []
    private var cachedDiskRatesByDriverId: [UInt64: DiskRate] = [:]

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
        var usable: UInt64 = 0
        var usableSize = MemoryLayout<UInt64>.stride
        if sysctlbyname("hw.memsize_usable", &usable, &usableSize, nil, 0) == 0, usable > 0 {
            self.usableMemoryBytes = usable
        } else {
            self.usableMemoryBytes = ProcessInfo.processInfo.physicalMemory
        }
        self.processorCount = ProcessInfo.processInfo.processorCount
        self.activeProcessorCount = ProcessInfo.processInfo.activeProcessorCount

        var ps: vm_size_t = 0
        host_page_size(mach_host_self(), &ps)
        let pageBytes = UInt64(ps == 0 ? 4096 : ps)
        self.pageSize = pageBytes
        self.totalPages = self.usableMemoryBytes / pageBytes

        // CPU brand string -- both Intel and modern Apple Silicon expose
        // machdep.cpu.brand_string (e.g. "Apple M2 Pro"); hw.model is the
        // machine model ("Mac14,10") and only used if the brand is missing.
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

    // MARK: -- Swap / paging file

    struct SwapUsage {
        let totalBytes: UInt64
        let usedBytes: UInt64
        let freeBytes: UInt64
    }

    /// Live macOS swap usage via `sysctl vm.swapusage`, so the DCL
    /// "Paging File Usage" section reflects the Mac's real backing store
    /// rather than reusing RAM page counts. Returns all-zero (swap not yet
    /// activated by the kernel) if the sysctl is unavailable.
    func swapUsage() -> SwapUsage {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else {
            return SwapUsage(totalBytes: 0, usedBytes: 0, freeBytes: 0)
        }
        return SwapUsage(totalBytes: swap.xsu_total,
                         usedBytes: swap.xsu_used,
                         freeBytes: swap.xsu_avail)
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
        /// BSD device name backing this volume (e.g. "disk3s1s1"). Used to
        /// cross-reference disk-I/O rates from IOKit against the same set
        /// of devices that SHOW DEVICES lists.
        let bsdName: String?

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

        let bsdByMount = bsdNamesByMountPath()

        var volumes: [VolumeInfo] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys),
                  let name = values.volumeName,
                  let total = values.volumeTotalCapacity,
                  let free = values.volumeAvailableCapacity else { continue }
            let boot = values.volumeIsRootFileSystem ?? false
            // FileManager returns file:// URLs; the mount path is the URL path.
            let bsd = bsdByMount[url.path]
            volumes.append(VolumeInfo(name: name, totalBytes: total,
                                      freeBytes: free, isBoot: boot,
                                      bsdName: bsd))
        }

        volumes.sort { a, b in
            if a.isBoot != b.isBoot { return a.isBoot }
            return a.name < b.name
        }
        return volumes
    }

    /// Returns a map from mount point (e.g. "/", "/System/Volumes/Data") to
    /// the BSD device name backing it (e.g. "disk3s1s1"). Built from a single
    /// `getmntinfo` call.
    private func bsdNamesByMountPath() -> [String: String] {
        var bufPtr: UnsafeMutablePointer<statfs>? = nil
        let n = getmntinfo(&bufPtr, MNT_NOWAIT)
        guard n > 0, let buf = bufPtr else { return [:] }
        var out: [String: String] = [:]
        for i in 0..<Int(n) {
            var entry = buf[i]
            let mountPath = withUnsafePointer(to: &entry.f_mntonname) { ptr -> String in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
            let devicePath = withUnsafePointer(to: &entry.f_mntfromname) { ptr -> String in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
            // /dev/disk3s1s1 -> disk3s1s1.  Synthetic entries (devfs, map -hosts,
            // ...) don't start with /dev/ so we just keep the raw string for
            // those, which won't match any IOBlockStorageDriver name.
            let bsd: String
            if devicePath.hasPrefix("/dev/") {
                bsd = String(devicePath.dropFirst(5))
            } else {
                bsd = devicePath
            }
            out[mountPath] = bsd
        }
        return out
    }

    // MARK: -- helpers

    /// Formats a byte count the way modern OpenVMS SHOW MEMORY reports
    /// installed memory: the largest binary unit that keeps the mantissa
    /// >= 1, scaling from Kb all the way up to Eb (the ceiling of a 64-bit
    /// byte count). Two-decimal mantissa, e.g. 33286717440 -> "31.00Gb".
    static func memSize(_ bytes: UInt64) -> String {
        let units = ["Kb", "Mb", "Gb", "Tb", "Pb", "Eb"]
        if bytes < 1024 { return "\(bytes) bytes" }
        var value = Double(bytes)
        var idx = -1
        while value >= 1024.0 && idx < units.count - 1 {
            value /= 1024.0
            idx += 1
        }
        return String(format: "%.2f%@", value, units[idx])
    }

    private static func readSysctlString(_ name: String) -> String? {
        var size: size_t = 0
        if sysctlbyname(name, nil, &size, nil, 0) != 0 || size == 0 { return nil }
        var buf = [CChar](repeating: 0, count: size)
        if sysctlbyname(name, &buf, &size, nil, 0) != 0 { return nil }
        let s = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    // MARK: -- VM rates (page faults, pageins, pageouts, etc.)

    struct VMRates {
        let pageFaultRate: Double
        let copyOnWriteRate: Double
        let zeroFillRate: Double
        let reactivationRate: Double
        let pageInRate: Double
        let pageOutRate: Double
        let lookupRate: Double
        let hitRate: Double

        static let zero = VMRates(pageFaultRate: 0, copyOnWriteRate: 0, zeroFillRate: 0,
                                   reactivationRate: 0, pageInRate: 0, pageOutRate: 0,
                                   lookupRate: 0, hitRate: 0)
    }

    /// Returns rates derived from `vm_statistics64` counters since the previous
    /// sample. Internally caches the result for 0.75s so multiple consumers
    /// (MONITOR refresh, peer broadcast, SHOW MEMORY) hitting the rate function
    /// in quick succession all see the same number instead of stealing each
    /// other's delta window.
    func vmRates() -> VMRates {
        let now = Date()
        let raw = sampleVMStatistics64()
        if let prev = lastVMRawSample {
            let dt = now.timeIntervalSince(prev.time)
            if dt < 0.75 { return cachedVMRates }
            let safeDt = max(0.001, dt)
            cachedVMRates = VMRates(
                pageFaultRate:    Double(raw.faults           &- prev.raw.faults)           / safeDt,
                copyOnWriteRate:  Double(raw.cow_faults       &- prev.raw.cow_faults)       / safeDt,
                zeroFillRate:     Double(raw.zero_fill_count  &- prev.raw.zero_fill_count)  / safeDt,
                reactivationRate: Double(raw.reactivations    &- prev.raw.reactivations)    / safeDt,
                pageInRate:       Double(raw.pageins          &- prev.raw.pageins)          / safeDt,
                pageOutRate:      Double(raw.pageouts         &- prev.raw.pageouts)         / safeDt,
                lookupRate:       Double(raw.lookups          &- prev.raw.lookups)          / safeDt,
                hitRate:          Double(raw.hits             &- prev.raw.hits)             / safeDt
            )
            lastVMRawSample = (raw, now)
            return cachedVMRates
        }
        lastVMRawSample = (raw, now)
        return cachedVMRates
    }

    private func sampleVMStatistics64() -> vm_statistics64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        _ = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        return stats
    }

    // MARK: -- Disk I/O rates via IOKit IOMedia + IOBlockStorageDriver

    struct DiskRawSample {
        let readOps: UInt64
        let writeOps: UInt64
        let readBytes: UInt64
        let writeBytes: UInt64
    }

    struct DiskRate {
        let bsdName: String
        let readOpsPerSec: Double
        let writeOpsPerSec: Double
        let readBytesPerSec: Double
        let writeBytesPerSec: Double

        var totalOpsPerSec: Double { readOpsPerSec + writeOpsPerSec }
    }

    /// Internal: counters + the "primary" (typically whole-disk) BSD name
    /// for a given IOBlockStorageDriver. APFS synthesized volumes share
    /// the same physical driver, so multiple slice BSD names map to the
    /// same DriverRawSample.
    private struct DriverRawSample {
        let primaryBsd: String
        let sample: DiskRawSample
    }

    /// Returns one rate per *physical* block-storage driver. APFS slice
    /// IOMedia entries are NOT in this list -- they share a parent
    /// driver, and reporting them separately would double-count system
    /// I/O. Use `diskRate(forBSD:)` to attribute a per-volume rate.
    func diskRates() -> [DiskRate] {
        refreshDiskSamplesIfNeeded()
        return cachedDiskRates
    }

    /// Looks up the I/O rate that should be attributed to a particular
    /// IOMedia BSD name (e.g. `disk3s3s1`). Walks up the IORegistry to
    /// find the underlying IOBlockStorageDriver, so a mounted volume on
    /// an APFS synthesized container correctly reports the physical
    /// disk's rate.
    func diskRate(forBSD bsdName: String) -> DiskRate? {
        refreshDiskSamplesIfNeeded()
        guard let driverId = lastBsdToDriverId[bsdName] else { return nil }
        return cachedDiskRatesByDriverId[driverId]
    }

    private func refreshDiskSamplesIfNeeded() {
        let now = Date()
        if let prev = lastDiskSampleTime, now.timeIntervalSince(prev) < 0.75 { return }
        let dt: Double
        if let prev = lastDiskSampleTime {
            dt = max(0.001, now.timeIntervalSince(prev))
        } else {
            dt = 1.0
        }

        let (drivers, bsdToDriverId) = sampleAllMedia()

        var ratesById: [UInt64: DiskRate] = [:]
        var physicalRates: [DiskRate] = []
        for (driverId, cur) in drivers {
            let prev = lastDriverSamples[driverId]?.sample ?? DiskRawSample(
                readOps: cur.sample.readOps,
                writeOps: cur.sample.writeOps,
                readBytes: cur.sample.readBytes,
                writeBytes: cur.sample.writeBytes)
            let r = DiskRate(
                bsdName:          cur.primaryBsd,
                readOpsPerSec:    Double(cur.sample.readOps    &- prev.readOps)    / dt,
                writeOpsPerSec:   Double(cur.sample.writeOps   &- prev.writeOps)   / dt,
                readBytesPerSec:  Double(cur.sample.readBytes  &- prev.readBytes)  / dt,
                writeBytesPerSec: Double(cur.sample.writeBytes &- prev.writeBytes) / dt
            )
            ratesById[driverId] = r
            physicalRates.append(r)
        }
        physicalRates.sort { $0.bsdName < $1.bsdName }

        lastDriverSamples = drivers
        lastBsdToDriverId = bsdToDriverId
        lastDiskSampleTime = now
        cachedDiskRates = physicalRates
        cachedDiskRatesByDriverId = ratesById
    }

    /// Enumerates every `IOMedia` entry, walks up the IOService plane to
    /// find the owning `IOBlockStorageDriver`, and reads its Statistics
    /// once per unique driver. Returns:
    ///  - `drivers`: per-driver counter sample, keyed by IORegistry
    ///    entry id, with the alphabetically-smallest descendant BSD name
    ///    chosen as the "primary" (typically the whole-disk name).
    ///  - `bsdToDriver`: every IOMedia BSD name (slice and whole-disk)
    ///    mapped back to the driver-id that owns its Statistics.
    private func sampleAllMedia() -> (drivers: [UInt64: DriverRawSample],
                                       bsdToDriver: [String: UInt64]) {
        var drivers: [UInt64: DriverRawSample] = [:]
        var bsdToDriver: [String: UInt64] = [:]

        guard let matching = IOServiceMatching("IOMedia") else {
            return (drivers, bsdToDriver)
        }
        var iter: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter)
        guard kr == KERN_SUCCESS else { return (drivers, bsdToDriver) }
        defer { IOObjectRelease(iter) }

        var media = IOIteratorNext(iter)
        while media != 0 {
            defer {
                IOObjectRelease(media)
                media = IOIteratorNext(iter)
            }

            guard let bsdAny = IORegistryEntryCreateCFProperty(
                    media, "BSD Name" as CFString,
                    kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let bsd = bsdAny as? String else { continue }

            // Walk up the IOService plane until we hit IOBlockStorageDriver.
            // We retain `current` ourselves so the loop body can release it
            // freely without affecting the iterator's hold on `media`.
            IOObjectRetain(media)
            var current: io_registry_entry_t = media
            var driver: io_registry_entry_t = 0
            for _ in 0..<32 {
                if IOObjectConformsTo(current, "IOBlockStorageDriver") != 0 {
                    driver = current
                    current = 0
                    break
                }
                var parent: io_registry_entry_t = 0
                let pkr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
                IOObjectRelease(current)
                current = 0
                if pkr != KERN_SUCCESS || parent == 0 { break }
                current = parent
            }
            if current != 0 { IOObjectRelease(current) }
            if driver == 0 { continue }
            defer { IOObjectRelease(driver) }

            var driverId: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(driver, &driverId)
            bsdToDriver[bsd] = driverId

            if let existing = drivers[driverId] {
                if bsd < existing.primaryBsd {
                    drivers[driverId] = DriverRawSample(primaryBsd: bsd, sample: existing.sample)
                }
            } else if let statsAny = IORegistryEntryCreateCFProperty(
                        driver, "Statistics" as CFString,
                        kCFAllocatorDefault, 0)?.takeRetainedValue(),
                      let stats = statsAny as? [String: Any] {
                let sample = DiskRawSample(
                    readOps:    (stats["Operations (Read)"]  as? NSNumber)?.uint64Value ?? 0,
                    writeOps:   (stats["Operations (Write)"] as? NSNumber)?.uint64Value ?? 0,
                    readBytes:  (stats["Bytes (Read)"]       as? NSNumber)?.uint64Value ?? 0,
                    writeBytes: (stats["Bytes (Write)"]      as? NSNumber)?.uint64Value ?? 0
                )
                drivers[driverId] = DriverRawSample(primaryBsd: bsd, sample: sample)
            }
        }

        return (drivers, bsdToDriver)
    }

    // MARK: -- Working set / resident size

    struct WorkingSet {
        let residentBytes: UInt64
        let virtualBytes: UInt64

        var residentPages: UInt64 { residentBytes / 4096 }
    }

    /// Returns the current process's resident and virtual memory size via
    /// `task_info(MACH_TASK_BASIC_INFO)`.
    func workingSet() -> WorkingSet {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return WorkingSet(residentBytes: 0, virtualBytes: 0) }
        return WorkingSet(residentBytes: info.resident_size, virtualBytes: info.virtual_size)
    }

    // MARK: -- Boot volume capacity (used by SHOW QUOTA)

    func bootVolume() -> VolumeInfo? {
        return mountedVolumes().first(where: { $0.isBoot })
    }

    // MARK: -- Snapshot for broadcast to peer nodes

    /// A bundle of host-level metrics broadcast to remote DCL peers so the
    /// MONITOR CLUSTER per-node row can show real numbers for each member.
    struct HostSnapshot: Codable {
        let cpuBusy: Double            // percent
        let memUsedPercent: Double
        let bufferedIORate: Double     // page fault rate per second
        let directIORate: Double       // total disk ops per second
        let lockRate: Double           // synthetic; lookups/sec
        let processCount: Int
        let sampledAt: Date
    }

    func snapshot() -> HostSnapshot {
        let cpu = cpuUsage()
        let vm  = vmStats()
        let r   = vmRates()
        let disks = diskRates()
        let totalDiskOps = disks.reduce(0.0) { $0 + $1.totalOpsPerSec }
        let memUsed: Double
        if vm.totalPages > 0 {
            memUsed = Double(vm.totalPages - vm.freePages) * 100.0 / Double(vm.totalPages)
        } else {
            memUsed = 0
        }
        return HostSnapshot(
            cpuBusy:         cpu.busy,
            memUsedPercent:  memUsed,
            bufferedIORate:  r.pageFaultRate,
            directIORate:    totalDiskOps,
            lockRate:        r.lookupRate,
            processCount:    processCount(),
            sampledAt:       Date()
        )
    }
}
