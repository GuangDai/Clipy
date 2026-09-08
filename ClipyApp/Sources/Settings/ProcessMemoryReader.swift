/// On-demand, whole-process memory facts for Maintenance (V2-07 §6.3).
/// Mach stays in the app target; no History action or cache eviction occurs.
import Darwin

actor ProcessMemoryReader {
    enum ReadFailure: Error { case unavailable }

    func read() throws -> ProcessMemoryUsage {
        try Task.checkCancellation()
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { taskInfo in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), taskInfo, &count)
            }
        }
        guard status == KERN_SUCCESS,
              let resident = Int(exactly: info.resident_size),
              let peak = Int(exactly: info.resident_size_peak),
              let footprint = Int(exactly: info.phys_footprint) else {
            throw ReadFailure.unavailable
        }
        return ProcessMemoryUsage(
            residentBytes: resident,
            peakResidentBytes: peak,
            footprintBytes: footprint
        )
    }
}
