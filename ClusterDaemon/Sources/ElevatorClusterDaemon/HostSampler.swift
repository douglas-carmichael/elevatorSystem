import Foundation
import Darwin

/// Samples real CPU-busy and memory-used percentages off the Mach host so
/// the daemon's nodes show live numbers in the app's MONITOR CLUSTER
/// per-node rows (the app keys `peerStats` off each peer's `.stats`
/// messages). IO / lock / process figures are light synthetic values --
/// enough to make the row look alive without porting the app's full VMS
/// accounting model. Output shape matches `HostSnapshot`.
final class HostSampler {
    private var lastCPU: (busy: Double, total: Double)?

    func snapshot() -> HostSnapshot {
        HostSnapshot(
            cpuBusy: cpuBusyPercent(),
            memUsedPercent: memUsedPercent(),
            bufferedIORate: Double.random(in: 20...140),
            directIORate: Double.random(in: 5...45),
            lockRate: Double.random(in: 80...420),
            processCount: 210 + Int.random(in: -12...18),
            sampledAt: Date()
        )
    }

    // MARK: -- CPU

    private func cpuBusyPercent() -> Double {
        guard let cur = readCPU() else { return 0 }
        defer { lastCPU = cur }
        guard let last = lastCPU else { return 0 }   // first sample has no delta
        let dBusy = cur.busy - last.busy
        let dTotal = cur.total - last.total
        guard dTotal > 0 else { return 0 }
        return max(0, min(100, dBusy / dTotal * 100))
    }

    private func readCPU() -> (busy: Double, total: Double)? {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info_data_t()
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let user = Double(info.cpu_ticks.0)     // CPU_STATE_USER
        let system = Double(info.cpu_ticks.1)   // CPU_STATE_SYSTEM
        let idle = Double(info.cpu_ticks.2)     // CPU_STATE_IDLE
        let nice = Double(info.cpu_ticks.3)     // CPU_STATE_NICE
        let busy = user + system + nice
        return (busy, busy + idle)
    }

    // MARK: -- memory

    private func memUsedPercent() -> Double {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = vm_statistics64_data_t()
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let pageSize = Double(sysconf(_SC_PAGESIZE))
        let used = (Double(info.active_count) + Double(info.wire_count) + Double(info.compressor_page_count)) * pageSize
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return 0 }
        return max(0, min(100, used / total * 100))
    }
}
