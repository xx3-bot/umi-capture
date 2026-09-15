import Darwin.Mach
import Foundation
import os

enum CaptureLoadLevel: Int, Comparable {
    case normal
    case elevated
    case high
    case critical

    static func < (lhs: CaptureLoadLevel, rhs: CaptureLoadLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct CapturePerformanceSnapshot {
    let physicalMemoryMB: Int
    let availableMemoryMB: Int
    let estimatedProcessLimitMB: Int
    let safeGrowthBudgetMB: Int
    let thermalState: ProcessInfo.ThermalState
    let level: CaptureLoadLevel
}

struct CapturePerformanceMonitor {
    static let elevatedMemoryMB = 1_000
    static let highMemoryMB = 1_350
    static let criticalMemoryMB = 1_650
    static let elevatedHeadroomMB = 1_200
    static let highHeadroomMB = 800
    static let criticalHeadroomMB = 450
    static let reservedHeadroomMB = 700

    static func safeGrowthBudget(availableMemoryMB: Int) -> Int {
        max(0, availableMemoryMB - reservedHeadroomMB)
    }

    static func memoryLoadLevel(
        physicalMemoryMB: Int,
        availableMemoryMB: Int
    ) -> CaptureLoadLevel {
        let footprintLevel: CaptureLoadLevel
        if physicalMemoryMB >= criticalMemoryMB {
            footprintLevel = .critical
        } else if physicalMemoryMB >= highMemoryMB {
            footprintLevel = .high
        } else if physicalMemoryMB >= elevatedMemoryMB {
            footprintLevel = .elevated
        } else {
            footprintLevel = .normal
        }

        let headroomLevel: CaptureLoadLevel
        if availableMemoryMB == 0 {
            headroomLevel = .normal
        } else if availableMemoryMB <= criticalHeadroomMB {
            headroomLevel = .critical
        } else if availableMemoryMB <= highHeadroomMB {
            headroomLevel = .high
        } else if availableMemoryMB <= elevatedHeadroomMB {
            headroomLevel = .elevated
        } else {
            headroomLevel = .normal
        }
        return max(footprintLevel, headroomLevel)
    }

    func snapshot() -> CapturePerformanceSnapshot {
        let physicalMemoryMB = Int(
            Self.physicalFootprintBytes() / 1_048_576
        )
        let availableMemoryMB = Int(
            os_proc_available_memory() / 1_048_576
        )
        let thermalState = ProcessInfo.processInfo.thermalState
        let thermalLevel: CaptureLoadLevel
        switch thermalState {
        case .nominal:
            thermalLevel = .normal
        case .fair:
            thermalLevel = .elevated
        case .serious:
            thermalLevel = .high
        case .critical:
            thermalLevel = .critical
        @unknown default:
            thermalLevel = .high
        }
        let memoryLevel = Self.memoryLoadLevel(
            physicalMemoryMB: physicalMemoryMB,
            availableMemoryMB: availableMemoryMB
        )
        return CapturePerformanceSnapshot(
            physicalMemoryMB: physicalMemoryMB,
            availableMemoryMB: availableMemoryMB,
            estimatedProcessLimitMB:
                physicalMemoryMB + availableMemoryMB,
            safeGrowthBudgetMB: Self.safeGrowthBudget(
                availableMemoryMB: availableMemoryMB
            ),
            thermalState: thermalState,
            level: max(memoryLevel, thermalLevel)
        )
    }

    private static func physicalFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
