import Darwin
import Foundation
#if canImport(IOKit)
import IOKit.ps
#endif

/// Facts the phone can show without opening a real shell.
public struct SystemProfile: Codable, Sendable, Equatable {
    public var user: String
    public var host: String
    public var model: String
    public var os: String
    public var cpu: String
    public var cores: Int
    public var memory: UInt64
    public var uptime: TimeInterval
    public var diskUsed: UInt64
    public var diskTotal: UInt64
    public var shares: Int
    public var load1: Double
    public var load5: Double
    public var load15: Double

    public init(
        user: String,
        host: String,
        model: String,
        os: String,
        cpu: String,
        cores: Int,
        memory: UInt64,
        uptime: TimeInterval,
        diskUsed: UInt64,
        diskTotal: UInt64,
        shares: Int,
        load1: Double = 0,
        load5: Double = 0,
        load15: Double = 0
    ) {
        self.user = user
        self.host = host
        self.model = model
        self.os = os
        self.cpu = cpu
        self.cores = cores
        self.memory = memory
        self.uptime = uptime
        self.diskUsed = diskUsed
        self.diskTotal = diskTotal
        self.shares = shares
        self.load1 = load1
        self.load5 = load5
        self.load15 = load15
    }
}

public struct TerminalContext: Sendable {
    public var user: String
    public var host: String
    public var device: String
    public var profile: SystemProfile

    public init(user: String, host: String, device: String, profile: SystemProfile) {
        self.user = user
        self.host = host
        self.device = device
        self.profile = profile
    }
}

/// One sample of a live Mac. CPU values are 0...100. Network counters are cumulative since boot.
public struct SystemStats: Codable, Sendable, Equatable {
    public var cores: [Double]
    public var cpuUser: Double
    public var cpuSystem: Double
    public var cpuNice: Double
    public var cpuIdle: Double
    public var load1: Double
    public var load5: Double
    public var load15: Double
    public var uptime: TimeInterval
    public var memoryUsed: UInt64
    public var memoryTotal: UInt64
    public var memoryWired: UInt64
    public var memoryActive: UInt64
    public var memoryCompressed: UInt64
    public var memoryCached: UInt64
    public var memoryFree: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var processCount: Int
    public var threadCount: Int
    /// Nil when this Mac has no battery.
    public var batteryPercent: Double?
    public var batteryCharging: Bool
    /// Maximum capacity compared with the battery’s original design, as a percent.
    public var batteryHealth: Double?
    public var batteryCondition: String?
    public var batteryCycles: Int?
    public var batteryDesignCycles: Int?
    /// Nominal, Fair, Serious, or Critical.
    public var thermalState: String
    public var temperatures: [TemperatureReading]
    public var diskUsed: UInt64
    public var diskTotal: UInt64
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public var processes: [ProcessSample]

    public init(
        cores: [Double],
        cpuUser: Double = 0,
        cpuSystem: Double = 0,
        cpuNice: Double = 0,
        cpuIdle: Double = 100,
        load1: Double = 0,
        load5: Double = 0,
        load15: Double = 0,
        uptime: TimeInterval = 0,
        memoryUsed: UInt64,
        memoryTotal: UInt64,
        memoryWired: UInt64 = 0,
        memoryActive: UInt64 = 0,
        memoryCompressed: UInt64 = 0,
        memoryCached: UInt64 = 0,
        memoryFree: UInt64 = 0,
        swapUsed: UInt64 = 0,
        swapTotal: UInt64 = 0,
        processCount: Int = 0,
        threadCount: Int = 0,
        batteryPercent: Double? = nil,
        batteryCharging: Bool = false,
        batteryHealth: Double? = nil,
        batteryCondition: String? = nil,
        batteryCycles: Int? = nil,
        batteryDesignCycles: Int? = nil,
        thermalState: String = "Nominal",
        temperatures: [TemperatureReading] = [],
        diskUsed: UInt64 = 0,
        diskTotal: UInt64 = 0,
        bytesIn: UInt64,
        bytesOut: UInt64,
        processes: [ProcessSample]
    ) {
        self.cores = cores
        self.cpuUser = cpuUser
        self.cpuSystem = cpuSystem
        self.cpuNice = cpuNice
        self.cpuIdle = cpuIdle
        self.load1 = load1
        self.load5 = load5
        self.load15 = load15
        self.uptime = uptime
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.memoryWired = memoryWired
        self.memoryActive = memoryActive
        self.memoryCompressed = memoryCompressed
        self.memoryCached = memoryCached
        self.memoryFree = memoryFree
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.processCount = processCount
        self.threadCount = threadCount
        self.batteryPercent = batteryPercent
        self.batteryCharging = batteryCharging
        self.batteryHealth = batteryHealth
        self.batteryCondition = batteryCondition
        self.batteryCycles = batteryCycles
        self.batteryDesignCycles = batteryDesignCycles
        self.thermalState = thermalState
        self.temperatures = temperatures
        self.diskUsed = diskUsed
        self.diskTotal = diskTotal
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.processes = processes
    }

    public var cpuAverage: Double {
        guard !cores.isEmpty else { return 0 }
        return cores.reduce(0, +) / Double(cores.count)
    }
}

public struct TemperatureReading: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var celsius: Double

    public var id: String { name }

    public init(name: String, celsius: Double) {
        self.name = name
        self.celsius = celsius
    }
}

public struct ProcessSample: Codable, Sendable, Equatable, Identifiable {
    public var pid: Int
    public var name: String
    public var cpu: Double
    public var memory: UInt64
    public var threads: Int

    public var id: Int { pid }

    public init(pid: Int, name: String, cpu: Double, memory: UInt64, threads: Int = 1) {
        self.pid = pid
        self.name = name
        self.cpu = cpu
        self.memory = memory
        self.threads = threads
    }
}

public struct CPUSample: Sendable, Equatable {
    public struct Core: Sendable, Equatable {
        public var user: UInt64
        public var system: UInt64
        public var idle: UInt64
        public var nice: UInt64

        public var total: UInt64 { user &+ system &+ idle &+ nice }

        public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
            self.user = user
            self.system = system
            self.idle = idle
            self.nice = nice
        }
    }

    public var cores: [Core]

    public init(cores: [Core]) {
        self.cores = cores
    }
}

public struct CPUParts: Sendable, Equatable {
    public var cores: [Double]
    public var user: Double
    public var system: Double
    public var nice: Double
    public var idle: Double
}

public enum CPUDelta {
    /// Busy time between two samples, as a percent of each core. A core with no new ticks stays at 0.
    public static func percents(previous: CPUSample, current: CPUSample) -> [Double] {
        parts(previous: previous, current: current).cores
    }

    /// Per-core busy percent, plus user, system, nice, and idle across every core.
    public static func parts(previous: CPUSample, current: CPUSample) -> CPUParts {
        let count = min(previous.cores.count, current.cores.count)
        var cores: [Double] = []
        var user: UInt64 = 0
        var system: UInt64 = 0
        var nice: UInt64 = 0
        var idle: UInt64 = 0
        for index in 0..<count {
            let before = previous.cores[index]
            let after = current.cores[index]
            let total = after.total &- before.total
            let userDelta = after.user &- before.user
            let systemDelta = after.system &- before.system
            let niceDelta = after.nice &- before.nice
            let idleDelta = after.idle &- before.idle
            user &+= userDelta
            system &+= systemDelta
            nice &+= niceDelta
            idle &+= idleDelta
            let busy = userDelta &+ systemDelta &+ niceDelta
            cores.append(total > 0 ? min(100, Double(busy) / Double(total) * 100) : 0)
        }
        let all = user &+ system &+ nice &+ idle
        func share(_ value: UInt64) -> Double {
            guard all > 0 else { return 0 }
            return Double(value) / Double(all) * 100
        }
        return CPUParts(cores: cores, user: share(user), system: share(system), nice: share(nice), idle: share(idle))
    }
}

public enum SystemText {
    public static func whoami(user: String, host: String, device: String) -> String {
        "\(user)@\(host) (via \(device))\n"
    }

    public static func status(profile: SystemProfile, folder: String, device: String) -> String {
        """
        Host     \(profile.host)
        User     \(profile.user)
        Phone    \(device)
        Folder   \(folder)
        OS       \(profile.os)
        Uptime   \(uptime(profile.uptime))
        Load     \(load(profile.load1, profile.load5, profile.load15))
        Memory   \(bytes(profile.memory))
        Shares   \(profile.shares)

        """
    }

    public static func fetch(_ profile: SystemProfile) -> String {
        let logo = [
            "  ╭────────╮",
            "  │ ╭────╮ │",
            "  │ │ ●● │ │",
            "  │ ╰────╯ │",
            "  ╰────────╯",
        ]
        let info = [
            "\(profile.user)@\(profile.host)",
            String(repeating: "─", count: min(28, max(8, profile.user.count + profile.host.count + 1))),
            row("OS", profile.os),
            row("Host", profile.model),
            row("CPU", profile.cpu),
            row("Cores", "\(profile.cores)"),
            row("Memory", bytes(profile.memory)),
            row("Uptime", uptime(profile.uptime)),
            row("Load", load(profile.load1, profile.load5, profile.load15)),
            row("Disk", profile.diskTotal > 0 ? "\(bytes(profile.diskUsed)) / \(bytes(profile.diskTotal))" : "unavailable"),
            row("Shares", "\(profile.shares)"),
        ]
        return (logo + [""] + info).joined(separator: "\n") + "\n"
    }

    public static func load(_ one: Double, _ five: Double, _ fifteen: Double) -> String {
        String(format: "%.2f  %.2f  %.2f", one, five, fifteen)
    }

    public static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        if unit == 0 { return "\(value) \(units[unit])" }
        if amount >= 100 || unit >= 3 { return String(format: "%.0f %@", amount, units[unit]) }
        return String(format: "%.1f %@", amount, units[unit])
    }

    public static func uptime(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0 B/s" }
        return bytes(UInt64(bytesPerSecond)) + "/s"
    }

    private static func row(_ label: String, _ value: String) -> String {
        label.padding(toLength: 8, withPad: " ", startingAt: 0) + value
    }
}

public enum SystemDemo {
    public static func profile(host: String, shares: Int) -> SystemProfile {
        SystemProfile(
            user: "tether",
            host: host,
            model: "Demo Mac",
            os: "macOS",
            cpu: "Apple M-series",
            cores: 8,
            memory: 24 * 1024 * 1024 * 1024,
            uptime: 3 * 3600 + 12 * 60,
            diskUsed: 180 * 1024 * 1024 * 1024,
            diskTotal: 500 * 1024 * 1024 * 1024,
            shares: shares,
            load1: 1.42,
            load5: 1.18,
            load15: 0.96
        )
    }

    public static func stats(tick: Int) -> SystemStats {
        let cores = (0..<8).map { index in
            let wave = sin(Double(tick + index) / 2) * 35 + 40
            return min(100, max(4, wave))
        }
        let processes = [
            ProcessSample(pid: 120, name: "WindowServer", cpu: cores[0] * 0.4, memory: 420 * 1024 * 1024, threads: 8),
            ProcessSample(pid: 88, name: "kernel_task", cpu: cores[1] * 0.25, memory: 1_100 * 1024 * 1024, threads: 180),
            ProcessSample(pid: 440, name: "Tether", cpu: 2.4, memory: 96 * 1024 * 1024, threads: 12),
        ]
        let average = cores.reduce(0, +) / Double(cores.count)
        return SystemStats(
            cores: cores,
            cpuUser: average * 0.62,
            cpuSystem: average * 0.30,
            cpuNice: average * 0.08,
            cpuIdle: max(0, 100 - average),
            load1: 1.4 + sin(Double(tick) / 3) * 0.3,
            load5: 1.2,
            load15: 0.9,
            uptime: 3 * 3600 + 12 * 60 + Double(tick),
            memoryUsed: 12 * 1024 * 1024 * 1024 + UInt64(tick % 5) * 80 * 1024 * 1024,
            memoryTotal: 24 * 1024 * 1024 * 1024,
            memoryWired: 3 * 1024 * 1024 * 1024,
            memoryActive: 7 * 1024 * 1024 * 1024,
            memoryCompressed: 2 * 1024 * 1024 * 1024,
            memoryCached: 4 * 1024 * 1024 * 1024,
            memoryFree: 8 * 1024 * 1024 * 1024,
            swapUsed: 512 * 1024 * 1024,
            swapTotal: 4 * 1024 * 1024 * 1024,
            processCount: 420,
            threadCount: 1860,
            batteryPercent: 76,
            batteryCharging: tick % 8 < 4,
            batteryHealth: 96,
            batteryCondition: "Good",
            batteryCycles: 109,
            batteryDesignCycles: 1000,
            thermalState: "Nominal",
            temperatures: [
                TemperatureReading(name: "tdie6", celsius: 54 + sin(Double(tick) / 2)),
                TemperatureReading(name: "tdie4", celsius: 49),
                TemperatureReading(name: "battery", celsius: 33),
            ],
            diskUsed: 180 * 1024 * 1024 * 1024,
            diskTotal: 500 * 1024 * 1024 * 1024,
            bytesIn: UInt64(tick) * 1_500_000,
            bytesOut: UInt64(tick) * 240_000,
            processes: processes
        )
    }
}

enum SystemProbe {
    static func profile(hostName: String, shareCount: Int) -> SystemProfile {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let user = NSUserName()
        let disk = diskUsage()
        let load = LoadReader.averages()
        return SystemProfile(
            user: user.isEmpty ? "user" : user,
            host: hostName,
            model: sysctlString("hw.model") ?? "Mac",
            os: os,
            cpu: cpuName(),
            cores: max(1, ProcessInfo.processInfo.processorCount),
            memory: ProcessInfo.processInfo.physicalMemory,
            uptime: ProcessInfo.processInfo.systemUptime,
            diskUsed: disk.used,
            diskTotal: disk.total,
            shares: shareCount,
            load1: load.0,
            load5: load.1,
            load15: load.2
        )
    }

    private static func cpuName() -> String {
        if let brand = sysctlString("machdep.cpu.brand_string"), !brand.isEmpty { return brand }
        return "\(ProcessInfo.processInfo.processorCount) cores"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func disk() -> (used: UInt64, total: UInt64) {
        diskUsage()
    }

    private static func diskUsage() -> (used: UInt64, total: UInt64) {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        let total = UInt64(values?.volumeTotalCapacity ?? 0)
        let available = UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0))
        let used = total > available ? total &- available : 0
        return (used, total)
    }
}

/// Remembers the last CPU and process sample so the next read can show a percent.
public actor SystemSampler {
    private var cpu: CPUSample?
    private var processes: [Int: UInt64] = [:]
    private var processWall: Date?

    public init() {}

    public func stats() async -> SystemStats {
        let first = CPUReader.sample()
        let stored = cpu
        let previousProcesses = processes
        let previousWall = processWall
        if stored == nil {
            try? await Task.sleep(for: .milliseconds(180))
        }
        let current = CPUReader.sample()
        let parts = CPUDelta.parts(previous: stored ?? first, current: current)
        let memory = MemoryReader.usage()
        let network = NetworkReader.totals()
        let swap = SwapReader.usage()
        let disk = SystemProbe.disk()
        let load = LoadReader.averages()
        let battery = BatteryReader.current()
        let procs = ProcessReader.top(previous: previousProcesses, wall: previousWall)
        cpu = current
        processes = procs.times
        processWall = Date()
        return SystemStats(
            cores: parts.cores.isEmpty ? [0] : parts.cores,
            cpuUser: parts.user,
            cpuSystem: parts.system,
            cpuNice: parts.nice,
            cpuIdle: parts.idle,
            load1: load.0,
            load5: load.1,
            load15: load.2,
            uptime: ProcessInfo.processInfo.systemUptime,
            memoryUsed: memory.used,
            memoryTotal: memory.total,
            memoryWired: memory.wired,
            memoryActive: memory.active,
            memoryCompressed: memory.compressed,
            memoryCached: memory.cached,
            memoryFree: memory.free,
            swapUsed: swap.used,
            swapTotal: swap.total,
            processCount: procs.processCount,
            threadCount: procs.threadCount,
            batteryPercent: battery?.percent,
            batteryCharging: battery?.charging ?? false,
            batteryHealth: battery?.health,
            batteryCondition: battery?.condition,
            batteryCycles: battery?.cycles,
            batteryDesignCycles: battery?.designCycles,
            thermalState: ThermalReader.state(),
            temperatures: TemperatureReader.readings(),
            diskUsed: disk.used,
            diskTotal: disk.total,
            bytesIn: network.inbound,
            bytesOut: network.outbound,
            processes: procs.samples
        )
    }
}

enum CPUReader {
    static func sample() -> CPUSample {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount)
        guard result == KERN_SUCCESS, let info, count > 0 else { return CPUSample(cores: []) }
        defer {
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        }
        let states = Int(CPU_STATE_MAX)
        var cores: [CPUSample.Core] = []
        for index in 0..<Int(count) {
            let base = index * states
            func tick(_ offset: Int32) -> UInt64 {
                UInt64(UInt32(bitPattern: info[base + Int(offset)]))
            }
            cores.append(CPUSample.Core(
                user: tick(CPU_STATE_USER),
                system: tick(CPU_STATE_SYSTEM),
                idle: tick(CPU_STATE_IDLE),
                nice: tick(CPU_STATE_NICE)
            ))
        }
        return CPUSample(cores: cores)
    }
}

enum MemoryReader {
    struct Report {
        var used: UInt64
        var total: UInt64
        var wired: UInt64
        var active: UInt64
        var compressed: UInt64
        var cached: UInt64
        var free: UInt64
    }

    static func usage() -> Report {
        let total = ProcessInfo.processInfo.physicalMemory
        let empty = Report(used: 0, total: total, wired: 0, active: 0, compressed: 0, cached: 0, free: 0)
        var statistics = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &size)
            }
        }
        guard status == KERN_SUCCESS else { return empty }
        var pageSize: vm_size_t = 16 * 1024
        _ = host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)
        func pages(_ count: UInt32) -> UInt64 { UInt64(count) * page }
        let wired = pages(UInt32(statistics.wire_count))
        let active = pages(UInt32(statistics.active_count))
        let compressed = pages(UInt32(statistics.compressor_page_count))
        let cached = pages(UInt32(statistics.inactive_count))
        let free = pages(UInt32(statistics.free_count))
        let used = min(total, active &+ wired &+ compressed)
        return Report(used: used, total: total, wired: wired, active: active, compressed: compressed, cached: cached, free: free)
    }
}

enum LoadReader {
    static func averages() -> (Double, Double, Double) {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, 3) == 3 else { return (0, 0, 0) }
        return (values[0], values[1], values[2])
    }
}

enum SwapReader {
    static func usage() -> (used: UInt64, total: UInt64) {
        #if os(macOS)
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else { return (0, 0) }
        return (swap.xsu_used, swap.xsu_total)
        #else
        return (0, 0)
        #endif
    }
}

struct BatteryStatus: Sendable {
    var percent: Double
    var charging: Bool
    var health: Double?
    var condition: String?
    var cycles: Int?
    var designCycles: Int?
}

enum BatteryMath {
    /// Charge is the percent full right now. Maximum capacity is nominal milliamp-hours over the design capacity, which is the figure System Settings shows.
    static func chargePercent(current: Int, max: Int) -> Double {
        guard max > 0 else { return 0 }
        if current <= 100, max <= 100 { return Double(current) }
        return min(100, Double(current) / Double(max) * 100)
    }

    static func maximumCapacity(nominal: Int, design: Int) -> Int? {
        guard nominal > 0, design > 0 else { return nil }
        return min(100, nominal * 100 / design)
    }

    static func condition(health: Double?) -> String? {
        guard let health else { return nil }
        if health >= 80 { return "Good" }
        if health >= 60 { return "Fair" }
        return "Service"
    }
}

enum BatteryReader {
    static func current() -> BatteryStatus? {
        #if canImport(IOKit)
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let raw = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            let current = integer(raw[kIOPSCurrentCapacityKey])
            let max = integer(raw[kIOPSMaxCapacityKey])
            guard let current, let max, max > 0 else { continue }
            let charging = (raw[kIOPSIsChargingKey] as? Bool) ?? ((raw[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? false)
            let pack = smartBattery()
            let health = pack.maximumCapacity.map(Double.init)
            return BatteryStatus(
                percent: BatteryMath.chargePercent(current: current, max: max),
                charging: charging,
                health: health,
                condition: BatteryMath.condition(health: health),
                cycles: pack.cycles,
                designCycles: pack.designCycles
            )
        }
        return nil
        #else
        return nil
        #endif
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private static func smartBattery() -> (cycles: Int?, designCycles: Int?, maximumCapacity: Int?) {
        #if canImport(IOKit)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil, nil) }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any] else { return (nil, nil, nil) }
        let cycles = integer(dict["CycleCount"])
        let designCycles = dict.keys.first { $0.hasPrefix("DesignCycleCount") }.flatMap { integer(dict[$0]) }
        let data = dictionary(dict["BatteryData"])
        let nominal = integer(data?["NominalChargeCapacity"]) ?? integer(data?["FullChargeCapacity"])
        let design = integer(data?["DesignCapacity"])
        let maximum = nominal.flatMap { nominal in design.flatMap { BatteryMath.maximumCapacity(nominal: nominal, design: $0) } }
        return (cycles, designCycles, maximum)
        #else
        return (nil, nil, nil)
        #endif
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        if let value = value as? [String: Any] { return value }
        guard let value = value as? NSDictionary else { return nil }
        var result: [String: Any] = [:]
        for (key, entry) in value {
            if let key = key as? String { result[key] = entry }
        }
        return result
    }
}

enum ThermalReader {
    static func state() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        default: "Nominal"
        }
    }
}

enum TemperatureFilter {
    /// Keeps die, device, and battery sensors in a sane Celsius range, hottest first.
    static func choose(_ samples: [(name: String, celsius: Double)]) -> [TemperatureReading] {
        var best: [String: Double] = [:]
        for sample in samples {
            let name = sample.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = name.lowercased()
            let useful = lower.contains("tdie") || lower.contains("tdev") || lower.contains("battery") || lower.contains("nand")
            guard useful, sample.celsius >= 1, sample.celsius <= 125 else { continue }
            best[name] = max(best[name] ?? 0, sample.celsius)
        }
        let readings = best.map { TemperatureReading(name: $0.key, celsius: $0.value) }
        let battery = readings.filter { $0.name.lowercased().contains("battery") }.max { $0.celsius < $1.celsius }
        let rest = readings
            .filter { !$0.name.lowercased().contains("battery") }
            .sorted { $0.celsius > $1.celsius }
        var chosen = Array(rest.prefix(battery == nil ? 6 : 5))
        if let battery { chosen.append(battery) }
        return chosen.sorted { $0.celsius > $1.celsius }
    }
}

#if os(macOS)
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> OpaquePointer?

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: OpaquePointer) -> Unmanaged<CFArray>?

@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: OpaquePointer, _ key: CFString) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: OpaquePointer, _ type: Int64, _ options: Int32, _ timeout: Int64) -> OpaquePointer?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: OpaquePointer, _ field: Int32) -> Double
#endif

enum TemperatureReader {
    static func readings() -> [TemperatureReading] {
        #if os(macOS)
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault),
              let raw = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() else { return [] }
        let count = CFArrayGetCount(raw)
        var samples: [(name: String, celsius: Double)] = []
        let field = Int32(15 << 16)
        for index in 0..<count {
            guard let pointer = CFArrayGetValueAtIndex(raw, index) else { continue }
            let service = OpaquePointer(pointer)
            let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? ""
            guard !name.isEmpty, let event = IOHIDServiceClientCopyEvent(service, 15, 0, 0) else { continue }
            samples.append((name, IOHIDEventGetFloatValue(event, field)))
        }
        return TemperatureFilter.choose(samples)
        #else
        return []
        #endif
    }
}

enum NetworkReader {
    static func totals() -> (inbound: UInt64, outbound: UInt64) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
        defer { freeifaddrs(first) }
        var inbound: UInt64 = 0
        var outbound: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            cursor = current.pointee.ifa_next
            let flags = Int32(current.pointee.ifa_flags)
            if flags & IFF_UP == 0 || flags & IFF_LOOPBACK != 0 { continue }
            guard let data = current.pointee.ifa_data else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            inbound &+= UInt64(stats.ifi_ibytes)
            outbound &+= UInt64(stats.ifi_obytes)
        }
        return (inbound, outbound)
    }
}

enum ProcessReader {
    static func top(previous: [Int: UInt64], wall: Date?) -> (samples: [ProcessSample], times: [Int: UInt64], processCount: Int, threadCount: Int) {
        #if os(macOS)
        return listed(previous: previous, wall: wall)
        #else
        _ = previous
        _ = wall
        return ([], [:], 0, 0)
        #endif
    }

    #if os(macOS)
    private static func listed(previous: [Int: UInt64], wall: Date?) -> (samples: [ProcessSample], times: [Int: UInt64], processCount: Int, threadCount: Int) {
        let elapsed = wall.map { Date().timeIntervalSince($0) } ?? 0
        let pids = processIDs()
        var times: [Int: UInt64] = [:]
        var samples: [ProcessSample] = []
        var threads = 0
        for pid in pids {
            guard let info = taskInfo(pid) else { continue }
            threads += info.threads
            let name = processName(pid)
            guard !name.isEmpty else { continue }
            times[pid] = info.time
            let cpu: Double
            if elapsed > 0.05, let before = previous[pid], info.time >= before {
                cpu = min(100 * Double(max(1, ProcessInfo.processInfo.processorCount)), Double(info.time - before) / (elapsed * 1_000_000_000) * 100)
            } else {
                cpu = 0
            }
            samples.append(ProcessSample(pid: pid, name: name, cpu: cpu, memory: info.memory, threads: info.threads))
        }
        let ranked = samples.sorted { lhs, rhs in
            if lhs.cpu != rhs.cpu { return lhs.cpu > rhs.cpu }
            return lhs.memory > rhs.memory
        }
        return (Array(ranked.prefix(12)), times, samples.count, threads)
    }

    private static func processIDs() -> [Int] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<pid_t>.stride
        var buffer = [pid_t](repeating: 0, count: count)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &buffer, bytes)
        guard written > 0 else { return [] }
        let limit = Int(written) / MemoryLayout<pid_t>.stride
        return buffer.prefix(limit).compactMap { value in
            let pid = Int(value)
            return pid > 0 ? pid : nil
        }
    }

    private static func processName(_ pid: Int) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(Int32(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func taskInfo(_ pid: Int) -> (time: UInt64, memory: UInt64, threads: Int)? {
        var info = proc_taskinfo()
        let size = proc_pidinfo(Int32(pid), PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.stride))
        guard size > 0 else { return nil }
        return (info.pti_total_user &+ info.pti_total_system, info.pti_resident_size, Int(info.pti_threadnum))
    }
    #endif
}
