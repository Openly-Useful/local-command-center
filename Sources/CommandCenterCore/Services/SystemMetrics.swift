import Darwin
import Foundation

public enum SystemMetricsError: Error, Equatable, Sendable, CustomStringConvertible {
    case hostPageSize(kern_return_t)
    case hostStatistics(kern_return_t)
    case taskInfo(kern_return_t)

    public var description: String {
        switch self {
        case let .hostPageSize(code):
            "host_page_size failed with Mach error \(code)"
        case let .hostStatistics(code):
            "host_statistics64 failed with Mach error \(code)"
        case let .taskInfo(code):
            "task_info failed with Mach error \(code)"
        }
    }
}

public struct SystemMemorySnapshot: Codable, Equatable, Sendable {
    public let physicalBytes: UInt64
    public let availableBytes: UInt64
    public let appResidentBytes: UInt64
    public let capturedAt: Date

    public init(
        physicalBytes: UInt64,
        availableBytes: UInt64,
        appResidentBytes: UInt64,
        capturedAt: Date = Date()
    ) {
        self.physicalBytes = physicalBytes
        self.availableBytes = min(availableBytes, physicalBytes)
        self.appResidentBytes = appResidentBytes
        self.capturedAt = capturedAt
    }
}

public protocol SystemMetricsProviding: Sendable {
    func snapshot() throws -> SystemMemorySnapshot
}

public struct DarwinSystemMetrics: SystemMetricsProviding, Sendable {
    public init() {}

    public func snapshot() throws -> SystemMemorySnapshot {
        var pageSize: vm_size_t = 0
        let host = mach_host_self()
        let pageResult = host_page_size(host, &pageSize)
        guard pageResult == KERN_SUCCESS else {
            throw SystemMetricsError.hostPageSize(pageResult)
        }

        var statistics = vm_statistics64()
        var statisticsCount = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let statisticsResult = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(statisticsCount)
            ) { rebound in
                host_statistics64(host, HOST_VM_INFO64, rebound, &statisticsCount)
            }
        }
        guard statisticsResult == KERN_SUCCESS else {
            throw SystemMetricsError.hostStatistics(statisticsResult)
        }

        var taskInformation = mach_task_basic_info()
        var taskInformationCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let taskResult = withUnsafeMutablePointer(to: &taskInformation) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(taskInformationCount)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &taskInformationCount
                )
            }
        }
        guard taskResult == KERN_SUCCESS else {
            throw SystemMetricsError.taskInfo(taskResult)
        }

        // Purgeable pages can overlap other VM queues, so counting them here could
        // overstate safe launch headroom. Free, inactive, and speculative queues are
        // mutually reported by HOST_VM_INFO64 and form a conservative admission input.
        let reclaimablePages = UInt64(statistics.free_count)
            + UInt64(statistics.inactive_count)
            + UInt64(statistics.speculative_count)
        let availableBytes = reclaimablePages.multipliedReportingOverflow(by: UInt64(pageSize))
        let physicalBytes = ProcessInfo.processInfo.physicalMemory

        return SystemMemorySnapshot(
            physicalBytes: physicalBytes,
            availableBytes: availableBytes.overflow ? physicalBytes : availableBytes.partialValue,
            appResidentBytes: UInt64(taskInformation.resident_size),
            capturedAt: Date()
        )
    }
}
