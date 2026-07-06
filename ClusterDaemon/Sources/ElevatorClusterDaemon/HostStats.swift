import Foundation

// Cross-platform port of the app's `HostStats` (Sources/ElevatorSystem/DCL/
// HostStats.swift) — the "OpenVMS accounting" model, so the daemon's nodes
// report real host numbers on every platform instead of synthetic ones.
//
// STRUCTURE: this façade holds every metric TYPE, all the delta/rate/caching
// logic (identical on every OS), and the full public API. The raw sampling —
// the only part that touches OS specifics — is a handful of `platform…()`
// primitives that return these neutral types, implemented per-OS in
// `HostStats+Darwin/Linux/Windows.swift`. Keeping platform types out of the
// façade is what lets the same delta code compile everywhere.
//
// Only the seven `HostSnapshot` fields (see Wire.swift) actually cross the peer
// wire; the rest of the surface mirrors the app faithfully for parity.
//
// Threading: one instance per node, called only from that node's serial queue,
// so — like the app's 0.75 s-cached original — it needs no locks. Platform
// coverage is real on macOS + Linux; on Windows CPU%/mem%/process-count are
// real and the IO/lock *rates* are light synthetic (documented), because those
// need PDH/ETW. None but CPU%/mem% affect the wire.
final class HostStats {
    // Static host facts, sampled once.
    let bootDate: Date
    let physicalMemoryBytes: UInt64
    let pageSize: UInt64
    let totalPages: UInt64
    let processorCount: Int
    let activeProcessorCount: Int
    let cpuModel: String
    let cpuFrequencyMHz: Int

    // Neutral cached state for rate/delta computations.
    private var lastCPUTicks: CPUTicksRaw?
    private var lastVMCounters: (raw: VMCountersRaw, time: Date)?
    private var cachedVMRates: VMRates = .zero
    private var lastDiskSamples: [String: DiskRawSample] = [:]
    private var lastDiskTime: Date?
    private var cachedDiskRates: [DiskRate] = []

    init() {
        let info = HostStats.platformStaticInfo()
        let page = info.pageSize == 0 ? 4096 : info.pageSize
        self.bootDate = info.bootDate
        self.physicalMemoryBytes = info.physicalMemoryBytes
        self.pageSize = page
        self.totalPages = page > 0 ? info.physicalMemoryBytes / page : 0
        self.processorCount = max(1, info.processorCount)
        self.activeProcessorCount = max(1, info.activeProcessorCount)
        self.cpuModel = info.cpuModel
        self.cpuFrequencyMHz = info.cpuFrequencyMHz
    }

    // MARK: -- neutral raw types (filled by the platform primitives)

    struct StaticInfo {
        var bootDate: Date
        var physicalMemoryBytes: UInt64
        var pageSize: UInt64
        var processorCount: Int
        var activeProcessorCount: Int
        var cpuModel: String
        var cpuFrequencyMHz: Int
    }

    /// Cumulative CPU time in each state (ticks/jiffies; units cancel in the ratio).
    struct CPUTicksRaw {
        var user: Double; var system: Double; var idle: Double; var nice: Double
    }

    /// Cumulative VM event counters, differenced into `VMRates`.
    struct VMCountersRaw {
        var faults: UInt64 = 0, cowFaults: UInt64 = 0, zeroFill: UInt64 = 0, reactivations: UInt64 = 0
        var pageins: UInt64 = 0, pageouts: UInt64 = 0, lookups: UInt64 = 0, hits: UInt64 = 0
    }

    /// Cumulative per-device disk counters, differenced into `DiskRate`.
    struct DiskRawSample {
        var readOps: UInt64 = 0, writeOps: UInt64 = 0, readBytes: UInt64 = 0, writeBytes: UInt64 = 0
    }

    // MARK: -- public metric types (mirror the app)

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

    struct CPUUsage {
        let user: Double; let system: Double; let idle: Double; let nice: Double
        var busy: Double { 100.0 - idle }
    }

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

    struct DiskRate {
        let bsdName: String
        let readOpsPerSec: Double
        let writeOpsPerSec: Double
        let readBytesPerSec: Double
        let writeBytesPerSec: Double

        var totalOpsPerSec: Double { readOpsPerSec + writeOpsPerSec }
    }

    struct VolumeInfo {
        let name: String
        let totalBytes: Int
        let freeBytes: Int
        let isBoot: Bool
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

    struct WorkingSet {
        let residentBytes: UInt64
        let virtualBytes: UInt64
        var residentPages: UInt64 { residentBytes / 4096 }
    }

    // MARK: -- public API (delta/caching lives here; sampling is per-OS)

    func uptime(at now: Date = Date()) -> TimeInterval { max(0, now.timeIntervalSince(bootDate)) }

    func loadAverages() -> (one: Double, five: Double, fifteen: Double) {
        HostStats.platformLoadAverages()
    }

    func vmStats() -> VMStats {
        HostStats.platformVMStats(totalPages: totalPages, pageSize: pageSize)
    }

    /// First call returns cumulative-since-boot percentages; later calls the
    /// delta since the previous sample (what `top`-style displays show).
    func cpuUsage() -> CPUUsage {
        guard let cur = HostStats.platformCPUTicks() else {
            return CPUUsage(user: 0, system: 0, idle: 100, nice: 0)
        }
        let base = lastCPUTicks ?? CPUTicksRaw(user: 0, system: 0, idle: 0, nice: 0)
        lastCPUTicks = cur
        let u = max(0, cur.user - base.user)
        let s = max(0, cur.system - base.system)
        let i = max(0, cur.idle - base.idle)
        let n = max(0, cur.nice - base.nice)
        let total = max(1.0, u + s + i + n)
        return CPUUsage(user: u * 100 / total, system: s * 100 / total,
                        idle: i * 100 / total, nice: n * 100 / total)
    }

    func processCount() -> Int { HostStats.platformProcessCount() }

    func mountedVolumes() -> [VolumeInfo] {
        HostStats.platformVolumes().sorted { a, b in
            if a.isBoot != b.isBoot { return a.isBoot }
            return a.name < b.name
        }
    }

    func bootVolume() -> VolumeInfo? { mountedVolumes().first(where: { $0.isBoot }) }

    func workingSet() -> WorkingSet { HostStats.platformWorkingSet() }

    /// VM event rates since the previous sample, cached 0.75 s so several
    /// consumers in quick succession see one consistent number rather than
    /// stealing each other's delta window.
    func vmRates() -> VMRates {
        let now = Date()
        let raw = HostStats.platformVMCounters()
        guard let prev = lastVMCounters else {
            lastVMCounters = (raw, now)
            return cachedVMRates
        }
        let dt = now.timeIntervalSince(prev.time)
        if dt < 0.75 { return cachedVMRates }
        let safeDt = max(0.001, dt)
        func rate(_ a: UInt64, _ b: UInt64) -> Double { Double(a &- b) / safeDt }
        cachedVMRates = VMRates(
            pageFaultRate:    rate(raw.faults, prev.raw.faults),
            copyOnWriteRate:  rate(raw.cowFaults, prev.raw.cowFaults),
            zeroFillRate:     rate(raw.zeroFill, prev.raw.zeroFill),
            reactivationRate: rate(raw.reactivations, prev.raw.reactivations),
            pageInRate:       rate(raw.pageins, prev.raw.pageins),
            pageOutRate:      rate(raw.pageouts, prev.raw.pageouts),
            lookupRate:       rate(raw.lookups, prev.raw.lookups),
            hitRate:          rate(raw.hits, prev.raw.hits)
        )
        lastVMCounters = (raw, now)
        return cachedVMRates
    }

    /// One rate per physical device, cached 0.75 s like `vmRates()`.
    func diskRates() -> [DiskRate] {
        refreshDiskSamplesIfNeeded()
        return cachedDiskRates
    }

    func diskRate(forBSD bsdName: String) -> DiskRate? {
        refreshDiskSamplesIfNeeded()
        return cachedDiskRates.first { $0.bsdName == bsdName }
    }

    private func refreshDiskSamplesIfNeeded() {
        let now = Date()
        if let prev = lastDiskTime, now.timeIntervalSince(prev) < 0.75 { return }
        let dt = lastDiskTime.map { max(0.001, now.timeIntervalSince($0)) } ?? 1.0
        let cur = HostStats.platformDiskSamples()
        var rates: [DiskRate] = []
        for (name, s) in cur {
            let p = lastDiskSamples[name] ?? s   // first sample: zero delta
            rates.append(DiskRate(
                bsdName: name,
                readOpsPerSec:    Double(s.readOps &- p.readOps) / dt,
                writeOpsPerSec:   Double(s.writeOps &- p.writeOps) / dt,
                readBytesPerSec:  Double(s.readBytes &- p.readBytes) / dt,
                writeBytesPerSec: Double(s.writeBytes &- p.writeBytes) / dt))
        }
        rates.sort { $0.bsdName < $1.bsdName }
        lastDiskSamples = cur
        lastDiskTime = now
        cachedDiskRates = rates
    }

    // MARK: -- snapshot for peer broadcast (the 7 wire fields)

    func snapshot() -> HostSnapshot {
        let cpu = cpuUsage()
        let vm = vmStats()
        let r = vmRates()
        let totalDiskOps = diskRates().reduce(0.0) { $0 + $1.totalOpsPerSec }
        let used = vm.totalPages >= vm.freePages ? vm.totalPages - vm.freePages : 0
        let memUsed = vm.totalPages > 0 ? Double(used) * 100.0 / Double(vm.totalPages) : 0
        return HostSnapshot(
            cpuBusy:        cpu.busy,
            memUsedPercent: memUsed,
            bufferedIORate: r.pageFaultRate,
            directIORate:   totalDiskOps,
            lockRate:       r.lookupRate,
            processCount:   processCount(),
            sampledAt:      Date()
        )
    }
}
