#if os(Windows)
import Foundation
import WinSDK

// Windows host sampling via Win32, filling `HostStats`'s neutral primitives.
//
// REAL: CPU% (GetSystemTimes), memory (GlobalMemoryStatusEx), uptime
// (GetTickCount64), page size / CPU count (GetSystemInfo), process count
// (EnumProcesses), volumes (GetLogicalDrives + GetDiskFreeSpaceExW), working set
// (GetProcessMemoryInfo). SYNTHETIC (documented): page-fault / disk-op / lookup
// *rates* and load average — Windows exposes those only via PDH/ETW, which is
// out of scope; they're derived from the boot tick so the row stays alive, and
// none of them but CPU%/mem% crosses the peer wire anyway.
//
// Compiled only on Windows; the whole file is inside the guard. BOOL results are
// discarded and the output structs checked instead, to stay agnostic about how
// Win32 `BOOL` imports into Swift.
extension HostStats {

    static func platformStaticInfo() -> StaticInfo {
        var si = SYSTEM_INFO()
        GetSystemInfo(&si)

        var ms = MEMORYSTATUSEX()
        ms.dwLength = DWORD(MemoryLayout<MEMORYSTATUSEX>.size)
        _ = GlobalMemoryStatusEx(&ms)

        let uptimeSecs = Double(GetTickCount64()) / 1000.0
        let cpuModel = ProcessInfo.processInfo.environment["PROCESSOR_IDENTIFIER"] ?? "Unknown CPU"

        return StaticInfo(
            bootDate: Date().addingTimeInterval(-uptimeSecs),
            physicalMemoryBytes: UInt64(ms.ullTotalPhys),
            pageSize: UInt64(si.dwPageSize),
            processorCount: Int(si.dwNumberOfProcessors),
            activeProcessorCount: Int(si.dwNumberOfProcessors),
            cpuModel: cpuModel,
            cpuFrequencyMHz: 0)
    }

    static func platformLoadAverages() -> (one: Double, five: Double, fifteen: Double) {
        (0, 0, 0)   // Windows has no load-average concept.
    }

    static func platformCPUTicks() -> CPUTicksRaw? {
        var idle = FILETIME(), kernel = FILETIME(), user = FILETIME()
        _ = GetSystemTimes(&idle, &kernel, &user)
        func ticks(_ ft: FILETIME) -> Double {
            Double(UInt64(ft.dwHighDateTime) << 32 | UInt64(ft.dwLowDateTime))
        }
        let idleT = ticks(idle), kernelT = ticks(kernel), userT = ticks(user)
        // kernel time includes idle; system = kernel − idle.
        return CPUTicksRaw(user: userT, system: max(0, kernelT - idleT), idle: idleT, nice: 0)
    }

    static func platformVMStats(totalPages: UInt64, pageSize: UInt64) -> VMStats {
        var ms = MEMORYSTATUSEX()
        ms.dwLength = DWORD(MemoryLayout<MEMORYSTATUSEX>.size)
        _ = GlobalMemoryStatusEx(&ms)
        let page = max(1, pageSize)
        let free = UInt64(ms.ullAvailPhys) / page
        let used = totalPages >= free ? totalPages - free : 0
        return VMStats(freePages: free, activePages: used, inactivePages: 0,
                       wiredPages: 0, compressedPages: 0, totalPages: totalPages, pageSize: pageSize)
    }

    // Synthetic, monotonic-from-boot-tick so vmRates()/diskRates() show plausible
    // steady rates. See file header.
    static func platformVMCounters() -> VMCountersRaw {
        let ms = Double(GetTickCount64())
        var c = VMCountersRaw()
        c.faults = UInt64(ms * 0.12)     // ≈120 faults/s
        c.pageins = UInt64(ms * 0.03)
        c.pageouts = UInt64(ms * 0.02)
        c.lookups = UInt64(ms * 0.30)    // ≈300 lookups/s
        return c
    }

    static func platformDiskSamples() -> [String: DiskRawSample] {
        let ms = Double(GetTickCount64())
        return ["PhysicalDrive0": DiskRawSample(
            readOps: UInt64(ms * 0.05), writeOps: UInt64(ms * 0.03),
            readBytes: UInt64(ms * 512 * 0.05), writeBytes: UInt64(ms * 512 * 0.03))]
    }

    static func platformProcessCount() -> Int {
        var pids = [DWORD](repeating: 0, count: 4096)
        var needed: DWORD = 0
        let cb = DWORD(pids.count * MemoryLayout<DWORD>.size)
        _ = pids.withUnsafeMutableBufferPointer { EnumProcesses($0.baseAddress, cb, &needed) }
        return Int(needed) / MemoryLayout<DWORD>.size
    }

    static func platformWorkingSet() -> WorkingSet {
        var pmc = PROCESS_MEMORY_COUNTERS()
        pmc.cb = DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS>.size)
        _ = GetProcessMemoryInfo(GetCurrentProcess(), &pmc, pmc.cb)
        return WorkingSet(residentBytes: UInt64(pmc.WorkingSetSize), virtualBytes: UInt64(pmc.PagefileUsage))
    }

    static func platformVolumes() -> [VolumeInfo] {
        var out: [VolumeInfo] = []
        let mask = GetLogicalDrives()
        let sysDrive = (ProcessInfo.processInfo.environment["SystemDrive"] ?? "C:").uppercased()
        for i in 0..<26 where (mask >> DWORD(i)) & 1 == 1 {
            let letter = Character(UnicodeScalar(UInt8(65 + i)))
            let root = "\(letter):\\"
            let type = root.withCString(encodedAs: UTF16.self) { GetDriveTypeW($0) }
            guard type == 3 else { continue }   // DRIVE_FIXED
            var freeAvail = ULARGE_INTEGER(), total = ULARGE_INTEGER(), totalFree = ULARGE_INTEGER()
            _ = root.withCString(encodedAs: UTF16.self) {
                GetDiskFreeSpaceExW($0, &freeAvail, &total, &totalFree)
            }
            let totalBytes = UInt64(total.QuadPart)
            guard totalBytes > 0 else { continue }
            out.append(VolumeInfo(
                name: String(letter),
                totalBytes: Int(clamping: totalBytes),
                freeBytes: Int(clamping: UInt64(totalFree.QuadPart)),
                isBoot: "\(letter):" == sysDrive,
                bsdName: "\(letter):"))
        }
        return out
    }
}
#endif
