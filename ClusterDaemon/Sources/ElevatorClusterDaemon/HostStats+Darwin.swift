#if canImport(Darwin)
import Foundation
import Darwin
import IOKit

// macOS host sampling — a direct port of the app's `HostStats` Mach/sysctl/IOKit
// code, reshaped to fill `HostStats`'s neutral primitive types. Compiled only on
// Apple platforms; the whole file is inside the guard because SwiftPM builds
// every source on every platform and an unguarded `import Darwin`/`IOKit` would
// break the Linux/Windows build.
extension HostStats {

    static func platformStaticInfo() -> StaticInfo {
        var bootDate = Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
        var bt = timeval()
        var btSize = MemoryLayout<timeval>.stride
        if sysctlbyname("kern.boottime", &bt, &btSize, nil, 0) == 0, bt.tv_sec > 0 {
            let secs = TimeInterval(bt.tv_sec) + TimeInterval(bt.tv_usec) / 1_000_000.0
            bootDate = Date(timeIntervalSince1970: secs)
        }

        var ps: vm_size_t = 0
        host_page_size(mach_host_self(), &ps)
        let pageBytes = UInt64(ps == 0 ? 4096 : ps)

        let cpuModel = readSysctlString("machdep.cpu.brand_string")
            ?? readSysctlString("hw.model") ?? "Unknown CPU"

        var freqMHz = 0
        var freq: UInt64 = 0
        var freqSize = MemoryLayout<UInt64>.stride
        if sysctlbyname("hw.cpufrequency", &freq, &freqSize, nil, 0) == 0, freq > 0 {
            freqMHz = Int(freq / 1_000_000)
        }

        return StaticInfo(
            bootDate: bootDate,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            pageSize: pageBytes,
            processorCount: ProcessInfo.processInfo.processorCount,
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
            cpuModel: cpuModel,
            cpuFrequencyMHz: freqMHz)
    }

    static func platformLoadAverages() -> (one: Double, five: Double, fifteen: Double) {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return (loads[0], loads[1], loads[2])
    }

    static func platformCPUTicks() -> CPUTicksRaw? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        // cpu_ticks tuple: USER, SYSTEM, IDLE, NICE.
        return CPUTicksRaw(user: Double(info.cpu_ticks.0), system: Double(info.cpu_ticks.1),
                           idle: Double(info.cpu_ticks.2), nice: Double(info.cpu_ticks.3))
    }

    private static func vmStatistics64() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? stats : nil
    }

    static func platformVMStats(totalPages: UInt64, pageSize: UInt64) -> VMStats {
        guard let s = vmStatistics64() else {
            return VMStats(freePages: 0, activePages: 0, inactivePages: 0, wiredPages: 0,
                           compressedPages: 0, totalPages: totalPages, pageSize: pageSize)
        }
        return VMStats(
            freePages: UInt64(s.free_count),
            activePages: UInt64(s.active_count),
            inactivePages: UInt64(s.inactive_count),
            wiredPages: UInt64(s.wire_count),
            compressedPages: UInt64(s.compressor_page_count),
            totalPages: totalPages,
            pageSize: pageSize)
    }

    static func platformVMCounters() -> VMCountersRaw {
        guard let s = vmStatistics64() else { return VMCountersRaw() }
        return VMCountersRaw(
            faults: UInt64(s.faults),
            cowFaults: UInt64(s.cow_faults),
            zeroFill: UInt64(s.zero_fill_count),
            reactivations: UInt64(s.reactivations),
            pageins: UInt64(s.pageins),
            pageouts: UInt64(s.pageouts),
            lookups: UInt64(s.lookups),
            hits: UInt64(s.hits))
    }

    static func platformProcessCount() -> Int {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length: size_t = 0
        if sysctl(&name, 4, nil, &length, nil, 0) != 0 || length == 0 { return 0 }
        return Int(length) / MemoryLayout<kinfo_proc>.stride
    }

    static func platformWorkingSet() -> WorkingSet {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return WorkingSet(residentBytes: 0, virtualBytes: 0) }
        return WorkingSet(residentBytes: info.resident_size, virtualBytes: info.virtual_size)
    }

    static func platformVolumes() -> [VolumeInfo] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeIsRootFileSystemKey,
        ]
        guard let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                              options: [.skipHiddenVolumes]) else { return [] }
        let bsdByMount = bsdNamesByMountPath()
        var out: [VolumeInfo] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: keys),
                  let name = v.volumeName, let total = v.volumeTotalCapacity,
                  let free = v.volumeAvailableCapacity else { continue }
            out.append(VolumeInfo(name: name, totalBytes: total, freeBytes: free,
                                  isBoot: v.volumeIsRootFileSystem ?? false,
                                  bsdName: bsdByMount[url.path]))
        }
        return out
    }

    private static func bsdNamesByMountPath() -> [String: String] {
        var bufPtr: UnsafeMutablePointer<statfs>? = nil
        let n = getmntinfo(&bufPtr, MNT_NOWAIT)
        guard n > 0, let buf = bufPtr else { return [:] }
        var out: [String: String] = [:]
        for i in 0..<Int(n) {
            var entry = buf[i]
            let mountPath = withUnsafePointer(to: &entry.f_mntonname) { p -> String in
                p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let devicePath = withUnsafePointer(to: &entry.f_mntfromname) { p -> String in
                p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            out[mountPath] = devicePath.hasPrefix("/dev/") ? String(devicePath.dropFirst(5)) : devicePath
        }
        return out
    }

    // Real disk I/O off IOKit: enumerate IOMedia, walk up to the owning
    // IOBlockStorageDriver, and read its Statistics once per unique driver (so
    // APFS synthesised slices that share a driver aren't double-counted). Keyed
    // by the alphabetically-smallest descendant BSD name (typically whole-disk).
    static func platformDiskSamples() -> [String: DiskRawSample] {
        var byPrimary: [String: DiskRawSample] = [:]
        var seenDrivers = Set<UInt64>()

        guard let matching = IOServiceMatching("IOMedia") else { return byPrimary }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return byPrimary }
        defer { IOObjectRelease(iter) }

        var media = IOIteratorNext(iter)
        while media != 0 {
            defer { IOObjectRelease(media); media = IOIteratorNext(iter) }

            guard let bsdAny = IORegistryEntryCreateCFProperty(media, "BSD Name" as CFString,
                                                               kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let bsd = bsdAny as? String else { continue }

            IOObjectRetain(media)
            var current: io_registry_entry_t = media
            var driver: io_registry_entry_t = 0
            for _ in 0..<32 {
                if IOObjectConformsTo(current, "IOBlockStorageDriver") != 0 { driver = current; current = 0; break }
                var parent: io_registry_entry_t = 0
                let pkr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
                IOObjectRelease(current); current = 0
                if pkr != KERN_SUCCESS || parent == 0 { break }
                current = parent
            }
            if current != 0 { IOObjectRelease(current) }
            if driver == 0 { continue }
            defer { IOObjectRelease(driver) }

            var driverId: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(driver, &driverId)
            if seenDrivers.contains(driverId) { continue }

            if let statsAny = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let stats = statsAny as? [String: Any] {
                seenDrivers.insert(driverId)
                byPrimary[bsd] = DiskRawSample(
                    readOps:    (stats["Operations (Read)"]  as? NSNumber)?.uint64Value ?? 0,
                    writeOps:   (stats["Operations (Write)"] as? NSNumber)?.uint64Value ?? 0,
                    readBytes:  (stats["Bytes (Read)"]       as? NSNumber)?.uint64Value ?? 0,
                    writeBytes: (stats["Bytes (Write)"]      as? NSNumber)?.uint64Value ?? 0)
            }
        }
        return byPrimary
    }

    private static func readSysctlString(_ name: String) -> String? {
        var size: size_t = 0
        if sysctlbyname(name, nil, &size, nil, 0) != 0 || size == 0 { return nil }
        var buf = [CChar](repeating: 0, count: size)
        if sysctlbyname(name, &buf, &size, nil, 0) != 0 { return nil }
        let s = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
#endif
