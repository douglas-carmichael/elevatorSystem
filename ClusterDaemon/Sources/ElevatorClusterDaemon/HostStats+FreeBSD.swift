#if os(FreeBSD)
import Foundation
import Glibc
import CHostStatsFreeBSD

// FreeBSD host sampling, filling `HostStats`'s neutral primitives. Like the macOS
// path it is sysctl-driven, but FreeBSD has neither Mach (no `host_statistics`)
// nor Linux's `/proc` text files, so the OIDs are its own: `kern.cp_time`,
// `vm.stats.vm.*`, `kern.boottime`, etc.
//
// SPLIT ACROSS TWO MODULES by necessity: the Swift `Glibc` overlay on FreeBSD
// exposes getmntinfo/getrusage/getloadavg/sysconf/statfs (used directly below)
// but NOT <sys/sysctl.h> — so every sysctl call goes through the tiny C shim
// `CHostStatsFreeBSD` (see its header). The daemon reaches FreeBSD through the
// `Glibc` overlay everywhere else too (main.swift / SocketShim.swift).
//
// REAL: CPU% (kern.cp_time), memory (vm.stats.vm.*), uptime (kern.boottime),
// page size / CPU count (sysconf), page-fault rate (v_vm_faults), process count
// (kern.proc), volumes (getmntinfo), load average (getloadavg), working set
// (getrusage). NOT SAMPLED (honest, not faked): per-device disk I/O needs
// devstat/libdevstat, whose version-tagged blob isn't worth a fragile hand
// decode, so `directIORate` reads 0; `lookups`/`hits` have no FreeBSD analogue,
// so `lockRate` reads 0. Of those only `directIORate` crosses the wire, and it's
// the least important of the seven fields — CPU% and mem% are both real.
//
// Compiled only on FreeBSD; the whole file is inside the guard because SwiftPM
// builds every source on every platform.
extension HostStats {

    static func platformStaticInfo() -> StaticInfo {
        let page = UInt64(max(1, sysconf(Int32(_SC_PAGESIZE))))

        // Total = the VM-managed page pool so free/active/inactive/wired below
        // stay consistent with it; fall back to hw.physmem (raw installed RAM).
        var physBytes: UInt64 = 0
        if let pages = sysctlUInt("vm.stats.vm.v_page_count"), pages > 0 {
            physBytes = pages * page
        } else if let phys = sysctlUInt("hw.physmem"), phys > 0 {
            physBytes = phys
        }

        // Absolute boot instant from kern.boottime, else derive it from the
        // process's own uptime reading.
        var bootDate = Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
        var epoch = 0.0
        if ehs_boottime(&epoch) == 0 {
            bootDate = Date(timeIntervalSince1970: epoch)
        }

        return StaticInfo(
            bootDate: bootDate,
            physicalMemoryBytes: physBytes,
            pageSize: page,
            processorCount: max(1, Int(sysconf(Int32(_SC_NPROCESSORS_CONF)))),
            activeProcessorCount: max(1, Int(sysconf(Int32(_SC_NPROCESSORS_ONLN)))),
            cpuModel: sysctlString("hw.model") ?? "Unknown CPU",
            cpuFrequencyMHz: Int(sysctlUInt("hw.clockrate") ?? 0))   // hw.clockrate is already MHz
    }

    static func platformLoadAverages() -> (one: Double, five: Double, fifteen: Double) {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return (loads[0], loads[1], loads[2])
    }

    static func platformCPUTicks() -> CPUTicksRaw? {
        var t: [UInt64] = [0, 0, 0, 0, 0]   // kern.cp_time: [USER, NICE, SYS, INTR, IDLE]
        guard ehs_cpu_ticks(&t) == 0 else { return nil }
        // Fold interrupt time into system so `busy = 100 - idle` matches top.
        return CPUTicksRaw(user: Double(t[0]), system: Double(t[2] + t[3]),
                           idle: Double(t[4]), nice: Double(t[1]))
    }

    static func platformVMStats(totalPages: UInt64, pageSize: UInt64) -> VMStats {
        func pages(_ leaf: String) -> UInt64 { sysctlUInt("vm.stats.vm." + leaf) ?? 0 }
        let inactive = pages("v_inactive_count")
        // Count reclaimable inactive pages as available so memUsedPercent tracks
        // genuinely-used memory (mirrors the Linux path's use of MemAvailable);
        // otherwise FreeBSD's aggressive caching would read as near-full.
        return VMStats(
            freePages: pages("v_free_count") + inactive,
            activePages: pages("v_active_count"),
            inactivePages: inactive,
            wiredPages: pages("v_wire_count"),
            compressedPages: 0,               // FreeBSD has no compressor-page counter
            totalPages: totalPages,
            pageSize: pageSize)
    }

    static func platformVMCounters() -> VMCountersRaw {
        func c(_ leaf: String) -> UInt64 { sysctlUInt("vm.stats.vm." + leaf) ?? 0 }
        return VMCountersRaw(
            faults: c("v_vm_faults"),
            cowFaults: c("v_cow_faults"),
            zeroFill: c("v_zfod"),
            reactivations: c("v_reactivated"),
            pageins: c("v_swappgsin") + c("v_vnodepgsin"),
            pageouts: c("v_swappgsout") + c("v_vnodepgsout"),
            lookups: 0, hits: 0)              // no FreeBSD counterpart → left 0, not faked
    }

    static func platformProcessCount() -> Int {
        let n = ehs_process_count()
        return n > 0 ? Int(n) : 0
    }

    static func platformWorkingSet() -> WorkingSet {
        // ru_maxrss (peak RSS, KiB) is a cheap proxy; current resident/virtual
        // size would mean walking our own kinfo_proc, which isn't worth it here.
        var ru = rusage()
        guard getrusage(RUSAGE_SELF, &ru) == 0 else { return WorkingSet(residentBytes: 0, virtualBytes: 0) }
        return WorkingSet(residentBytes: UInt64(max(0, ru.ru_maxrss)) * 1024, virtualBytes: 0)
    }

    static func platformVolumes() -> [VolumeInfo] {
        var bufPtr: UnsafeMutablePointer<statfs>? = nil
        let n = getmntinfo(&bufPtr, MNT_NOWAIT)
        guard n > 0, let buf = bufPtr else { return [] }
        var out: [VolumeInfo] = []
        for i in 0..<Int(n) {
            var entry = buf[i]
            let mountPath = withUnsafePointer(to: &entry.f_mntonname) { p -> String in
                p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let devicePath = withUnsafePointer(to: &entry.f_mntfromname) { p -> String in
                p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard devicePath.hasPrefix("/dev/") else { continue }   // real block devices only
            let bsize = UInt64(entry.f_bsize == 0 ? 512 : entry.f_bsize)
            let total = UInt64(entry.f_blocks) * bsize
            let availBlocks = Int64(entry.f_bavail)                 // f_bavail may be signed
            let free = availBlocks > 0 ? UInt64(availBlocks) * bsize : 0
            let name = mountPath == "/" ? "root"
                : (mountPath.split(separator: "/").last.map(String.init) ?? mountPath)
            out.append(VolumeInfo(name: name,
                                  totalBytes: Int(clamping: total),
                                  freeBytes: Int(clamping: free),
                                  isBoot: mountPath == "/",
                                  bsdName: String(devicePath.dropFirst(5))))
        }
        return out
    }

    static func platformDiskSamples() -> [String: DiskRawSample] {
        // Per-device I/O lives in devstat (kern.devstat.all / libdevstat), a
        // version-tagged binary blob that isn't worth a hand-rolled decode; it
        // feeds only the non-critical directIORate, so leave it unsampled.
        return [:]
    }

    // MARK: -- sysctl helpers (thin Swift wrappers over the C shim)

    private static func sysctlUInt(_ name: String) -> UInt64? {
        var v: UInt64 = 0
        return ehs_sysctl_u64(name, &v) == 0 ? v : nil
    }

    private static func sysctlString(_ name: String) -> String? {
        let cap = 256
        var buf = [CChar](repeating: 0, count: cap)
        guard ehs_sysctl_str(name, &buf, cap) == 0 else { return nil }
        let s = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
#endif
