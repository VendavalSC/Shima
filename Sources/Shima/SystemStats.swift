import Darwin
import Foundation
import SwiftUI

/// Reads CPU, memory, disk and battery use. Only asked while the System page is on screen.
final class SystemSampler {
    static let shared = SystemSampler()

    struct Reading: Equatable {
        var cpu: Double = 0       // 0...1, across all cores since the previous reading
        var memory: Double = 0    // used / installed, counted as Activity Monitor's "Memory Used"
        var disk: Double = 0      // used / capacity of the startup disk
        var battery: Double?      // 0...1, nil without a battery
    }

    private var previousTicks: [UInt64]?
    private var lastDate: Date?
    private var last = Reading()

    /// One reading per timeline tick, however often the view redraws in between.
    func reading(at date: Date) -> Reading {
        if date == lastDate { return last }
        lastDate = date
        last = Reading(cpu: cpu(), memory: memory(), disk: disk(), battery: BatteryMonitor.read().map { Double($0.level) / 100 })
        return last
    }

    private func cpu() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return last.cpu }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3].map(UInt64.init)
        defer { previousTicks = ticks }
        guard let previous = previousTicks else { return 0 }
        let delta = zip(ticks, previous).map { $0 &- $1 }
        let total = delta.reduce(0, +)
        guard total > 0 else { return last.cpu }
        let idle = delta[Int(CPU_STATE_IDLE)]
        return Double(total - idle) / Double(total)
    }

    private func memory() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return last.memory }
        let page = UInt64(vm_kernel_page_size)
        // App memory (internal minus purgeable) + wired + compressed, as Activity Monitor counts it.
        let appPages = UInt64(stats.internal_page_count) - UInt64(min(stats.purgeable_count, stats.internal_page_count))
        let used = (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return min(Double(used) / Double(ProcessInfo.processInfo.physicalMemory), 1)
    }

    private func disk() -> Double {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0,
              let available = values.volumeAvailableCapacityForImportantUsage else { return last.disk }
        return min(max(1 - Double(available) / Double(total), 0), 1)
    }
}

/// The System page: four rings (CPU, memory, disk, battery) with the value inside each, refreshed
/// every two seconds while the page is showing.
struct SystemSection: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            let reading = SystemSampler.shared.reading(at: context.date)
            HStack(spacing: 0) {
                Gauge(label: "CPU", value: reading.cpu, tint: .blue)
                Gauge(label: "Memory", value: reading.memory, tint: .purple)
                Gauge(label: "Disk", value: reading.disk, tint: .orange)
                if let battery = reading.battery {
                    Gauge(label: "Battery", value: battery, tint: battery <= 0.2 ? .red : .green)
                }
            }
            .padding(.top, 24)   // centers the rings and labels in the page
        }
    }

    private struct Gauge: View {
        let label: String
        let value: Double
        let tint: Color

        var body: some View {
            VStack(spacing: 8) {
                ZStack {
                    Circle().stroke(tint.opacity(0.22), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: max(value, 0.005))
                        .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int((value * 100).rounded()))%")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(value: value))
                }
                .frame(width: 56, height: 56)
                .animation(.smooth(duration: 0.6), value: value)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity)
        }
    }
}
