import Darwin
import Foundation
import UIKit

@MainActor
enum DeviceMetrics {
    static var device: String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
            return UIDevice.current.model
        }
        var bytes = [CChar](repeating: 0, count: size)
        let status = bytes.withUnsafeMutableBytes {
            sysctlbyname("hw.machine", $0.baseAddress, &size, nil, 0)
        }
        guard status == 0 else { return UIDevice.current.model }
        // Export the hardware identifier, not an assumed marketing name.
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }

    static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static var battery: Float? {
        let value = UIDevice.current.batteryLevel
        return (0...1).contains(value) ? value : nil
    }

    static var memoryMB: Double? {
        var info = task_vm_info_data_t()
        let capacity = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_000_000
    }
}
