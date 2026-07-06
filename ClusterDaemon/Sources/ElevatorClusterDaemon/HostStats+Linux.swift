// FreeBSD also imports `Glibc`, but has no /proc — it has its own file, so it's
// excluded here to keep exactly one HostStats sampler compiled per platform.
#if (canImport(Glibc) || canImport(Musl)) && !os(FreeBSD)
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Musl
#endif

// Linux host sampling via /proc + statvfs + sysconf, filling `HostStats`'s
// neutral primitives. Real CPU%, memory, page-fault rate, disk-op rate,
// process count, volumes, and working set. `lookups`/`hits`/`cowFaults` have no
// /proc analogue (so `lockRate` reads 0 — honestly, not faked). Compiled only
// where glibc or musl is present; the whole file is inside the guard.
extension HostStats {

    static func platformStaticInfo() -> StaticInfo {
        let page = UInt64(max(1, sysconf(Int32(_SC_PAGESIZE))))

        // Physical memory: MemTotal (kB) if present, else pages × pagesize.
        var memBytes = UInt64(max(0, sysconf(Int32(_SC_PHYS_PAGES)))) * page
        if let kb = meminfoKB("MemTotal") { memBytes = kb * 1024 }

        // Boot time: prefer /proc/stat btime (absolute epoch), else derive from
        // /proc/uptime.
        var bootDate = Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
        if let stat = procRead("/proc/stat"),
           let line = stat.split(separator: "\n").first(where: { $0.hasPrefix("btime ") }),
           let secs = Double(line.split(separator: " ").dropFirst().first ?? "") {
            bootDate = Date(timeIntervalSince1970: secs)
        } else if let up = procRead("/proc/uptime"),
                  let secs = Double(up.split(separator: " ").first ?? "") {
            bootDate = Date().addingTimeInterval(-secs)
        }

        let cpuModel = cpuinfoValue("model name")
            ?? cpuinfoValue("Hardware") ?? cpuinfoValue("Processor") ?? "Unknown CPU"
        let mhz = cpuinfoValue("cpu MHz").flatMap { Double($0) }.map { Int($0) } ?? 0

        return StaticInfo(
            bootDate: bootDate,
            physicalMemoryBytes: memBytes,
            pageSize: page,
            processorCount: max(1, Int(sysconf(Int32(_SC_NPROCESSORS_CONF)))),
            activeProcessorCount: max(1, Int(sysconf(Int32(_SC_NPROCESSORS_ONLN)))),
            cpuModel: cpuModel,
            cpuFrequencyMHz: mhz)
    }

    static func platformLoadAverages() -> (one: Double, five: Double, fifteen: Double) {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return (loads[0], loads[1], loads[2])
    }

    static func platformCPUTicks() -> CPUTicksRaw? {
        guard let stat = procRead("/proc/stat"),
              let line = stat.split(separator: "\n").first(where: { $0.hasPrefix("cpu ") || $0.hasPrefix("cpu\t") }) else { return nil }
        let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst().compactMap { Double($0) }
        guard f.count >= 4 else { return nil }
        // user nice system idle [iowait irq softirq steal ...]
        let user = f[0], nice = f[1], system = f[2], idle = f[3]
        let iowait = f.count > 4 ? f[4] : 0
        let irq = f.count > 5 ? f[5] : 0
        let softirq = f.count > 6 ? f[6] : 0
        let steal = f.count > 7 ? f[7] : 0
        // Fold servicing time into system and non-productive wait into idle, so
        // `busy = 100 - idle` matches what `top` reports.
        return CPUTicksRaw(user: user, system: system + irq + softirq + steal,
                           idle: idle + iowait, nice: nice)
    }

    static func platformVMStats(totalPages: UInt64, pageSize: UInt64) -> VMStats {
        func pages(_ key: String) -> UInt64 { (meminfoKB(key) ?? 0) * 1024 / max(1, pageSize) }
        // Use MemAvailable as "free" so memUsedPercent reflects genuinely-used
        // memory (reclaimable cache counts as available), matching `free`.
        let free = pages("MemAvailable") != 0 ? pages("MemAvailable") : pages("MemFree")
        return VMStats(
            freePages: free,
            activePages: pages("Active"),
            inactivePages: pages("Inactive"),
            wiredPages: pages("Unevictable"),
            compressedPages: 0,
            totalPages: totalPages,
            pageSize: pageSize)
    }

    static func platformVMCounters() -> VMCountersRaw {
        var c = VMCountersRaw()
        guard let vm = procRead("/proc/vmstat") else { return c }
        var map: [Substring: UInt64] = [:]
        for line in vm.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, let v = UInt64(parts[1]) { map[parts[0]] = v }
        }
        c.faults = map["pgfault"] ?? 0
        c.pageins = map["pgpgin"] ?? 0
        c.pageouts = map["pgpgout"] ?? 0
        c.reactivations = map["pgactivate"] ?? 0
        // No Linux counterpart: cowFaults, zeroFill, lookups, hits → left 0.
        return c
    }

    static func platformProcessCount() -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return 0 }
        return entries.reduce(0) { $0 + (($1.allSatisfy { $0.isNumber } && !$1.isEmpty) ? 1 : 0) }
    }

    static func platformWorkingSet() -> WorkingSet {
        let page = UInt64(max(1, sysconf(Int32(_SC_PAGESIZE))))
        guard let statm = procRead("/proc/self/statm") else { return WorkingSet(residentBytes: 0, virtualBytes: 0) }
        let f = statm.split(separator: " ").compactMap { UInt64($0) }
        guard f.count >= 2 else { return WorkingSet(residentBytes: 0, virtualBytes: 0) }
        return WorkingSet(residentBytes: f[1] * page, virtualBytes: f[0] * page)   // size, resident (pages)
    }

    static func platformVolumes() -> [VolumeInfo] {
        guard let mounts = procRead("/proc/mounts") else { return [] }
        var out: [VolumeInfo] = []
        for line in mounts.split(separator: "\n") {
            let cols = line.split(separator: " ")
            guard cols.count >= 2 else { continue }
            let device = String(cols[0]), mountPoint = decodeOctal(String(cols[1]))
            guard device.hasPrefix("/dev/") else { continue }   // real block devices only
            var st = statvfs()
            guard statvfs(mountPoint, &st) == 0, st.f_blocks > 0 else { continue }
            let frsize = UInt64(st.f_frsize == 0 ? UInt(st.f_bsize) : st.f_frsize)
            let total = UInt64(st.f_blocks) * frsize
            let free = UInt64(st.f_bavail) * frsize
            let name = mountPoint == "/" ? "root" : (mountPoint.split(separator: "/").last.map(String.init) ?? mountPoint)
            out.append(VolumeInfo(name: name, totalBytes: Int(clamping: total), freeBytes: Int(clamping: free),
                                  isBoot: mountPoint == "/", bsdName: String(device.dropFirst(5))))
        }
        return out
    }

    static func platformDiskSamples() -> [String: DiskRawSample] {
        guard let ds = procRead("/proc/diskstats") else { return [:] }
        // Row: major minor name r rmerge rsect rtime w wmerge wsect wtime ...
        var rows: [(name: String, sample: DiskRawSample)] = []
        for line in ds.split(separator: "\n") {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count >= 11 else { continue }
            let name = String(f[2])
            if name.hasPrefix("loop") || name.hasPrefix("ram") || name.hasPrefix("fd")
                || name.hasPrefix("sr") || name.hasPrefix("dm-") { continue }
            let readOps = UInt64(f[3]) ?? 0, readSect = UInt64(f[5]) ?? 0
            let writeOps = UInt64(f[7]) ?? 0, writeSect = UInt64(f[9]) ?? 0
            rows.append((name, DiskRawSample(readOps: readOps, writeOps: writeOps,
                                             readBytes: readSect * 512, writeBytes: writeSect * 512)))
        }
        // Drop partitions (a row whose name is another whole-disk row + optional
        // "p" + digits) so I/O isn't double-counted against the parent disk.
        let names = Set(rows.map { $0.name })
        func isPartition(_ n: String) -> Bool {
            guard let last = n.last, last.isNumber else { return false }
            for parent in names where parent != n && n.hasPrefix(parent) {
                let rest = n.dropFirst(parent.count)
                let digits = rest.hasPrefix("p") ? rest.dropFirst() : rest
                if !digits.isEmpty && digits.allSatisfy({ $0.isNumber }) { return true }
            }
            return false
        }
        var out: [String: DiskRawSample] = [:]
        for row in rows where !isPartition(row.name) { out[row.name] = row.sample }
        return out
    }

    // MARK: -- /proc helpers

    private static func procRead(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    private static func meminfoKB(_ key: String) -> UInt64? {
        guard let text = procRead("/proc/meminfo") else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix(key + ":") {
            // "MemTotal:       16333764 kB"
            let nums = line.split(whereSeparator: { !($0.isNumber) }).compactMap { UInt64($0) }
            return nums.first
        }
        return nil
    }

    private static func cpuinfoValue(_ key: String) -> String? {
        guard let text = procRead("/proc/cpuinfo") else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix(key) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { return v }
        }
        return nil
    }

    /// /proc/mounts octal-escapes spaces etc. in mount paths (e.g. `\040`).
    private static func decodeOctal(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = "", it = s.startIndex
        while it < s.endIndex {
            if s[it] == "\\", let end = s.index(it, offsetBy: 4, limitedBy: s.endIndex),
               s.index(after: it) < s.endIndex {
                let oct = s[s.index(after: it)..<end]
                if oct.count == 3, let code = UInt8(oct, radix: 8) {
                    out.append(Character(UnicodeScalar(code))); it = end; continue
                }
            }
            out.append(s[it]); it = s.index(after: it)
        }
        return out
    }
}
#endif
