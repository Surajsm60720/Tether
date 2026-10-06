import SwiftUI
import TetherCore
import UIKit

struct MonitorScreen: View {
    @Bindable var store: ClientStore

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let width = max(0, geo.size.width - 32)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        summary
                        temperatureBox
                        if let message = store.monitorMessage, store.monitorStats == nil {
                            Text(message)
                                .font(.body)
                                .foregroundStyle(TerminalTheme.standard.error)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        cpuBox(width: width)
                        memoryBox
                        diskBox
                        networkBox
                        processBox(width: width)
                    }
                    .padding(16)
                    .frame(width: geo.size.width, alignment: .leading)
                }
            }
            .background(TerminalTheme.standard.bg)
            .navigationTitle("Monitor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { store.showMonitor = false }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await store.refreshMonitor()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let profile = store.monitorProfile {
                Text("\(profile.user)@\(profile.host)")
                    .font(.headline)
                    .foregroundStyle(TerminalTheme.standard.fg)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(profile.model) · \(profile.os)")
                    .font(.caption)
                    .foregroundStyle(TerminalTheme.standard.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Text(profile.cpu)
                    .font(.caption)
                    .foregroundStyle(TerminalTheme.standard.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let stats = store.monitorStats {
                Text("Up \(SystemText.uptime(stats.uptime))")
                    .font(font)
                    .foregroundStyle(TerminalTheme.standard.fg)
                Text("Load \(SystemText.load(stats.load1, stats.load5, stats.load15))")
                    .font(font)
                    .foregroundStyle(TerminalTheme.standard.prompt)
                    .monospacedDigit()
                Text("\(stats.processCount) tasks · \(stats.threadCount) threads")
                    .font(font)
                    .foregroundStyle(TerminalTheme.standard.dim)
                    .monospacedDigit()
                if let battery = stats.batteryPercent {
                    Text(batteryLine(stats, charge: battery))
                        .font(font)
                        .foregroundStyle(TerminalTheme.standard.exec)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    if let health = stats.batteryHealth {
                        let condition = stats.batteryCondition.map { " · \($0)" } ?? ""
                        Text("Maximum capacity \(percent(health))\(condition)")
                            .font(font)
                            .foregroundStyle(healthColor(health))
                            .monospacedDigit()
                    }
                    if let cycles = stats.batteryCycles {
                        let design = stats.batteryDesignCycles.map { " / \($0)" } ?? ""
                        Text("Cycles \(cycles)\(design)")
                            .font(font)
                            .foregroundStyle(TerminalTheme.standard.dim)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private var temperatureBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Temperature", trailing: store.monitorStats?.thermalState)
            if let readings = store.monitorStats?.temperatures, !readings.isEmpty {
                ForEach(readings) { reading in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(reading.name)
                                .foregroundStyle(TerminalTheme.standard.dim)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(celsius(reading.celsius))
                                .foregroundStyle(temperatureColor(reading.celsius))
                                .monospacedDigit()
                        }
                        .font(font)
                        meter(temperatureFraction(reading.celsius), tint: temperatureColor(reading.celsius))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(reading.name), \(celsius(reading.celsius))")
                }
            } else if store.monitorStats != nil {
                Text("Sensor readings aren’t available. The thermal state above is from the Mac.")
                    .font(font)
                    .foregroundStyle(TerminalTheme.standard.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func cpuBox(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("CPU", trailing: percent(store.monitorStats?.cpuAverage ?? 0))
            if let stats = store.monitorStats {
                stackedBar(parts: [
                    (stats.cpuUser, TerminalTheme.standard.prompt),
                    (stats.cpuSystem, TerminalTheme.standard.dir),
                    (stats.cpuNice, Color.tether.warning),
                    (stats.cpuIdle, TerminalTheme.standard.dim.opacity(0.45)),
                ])
                legend([
                    ("user", percent(stats.cpuUser), TerminalTheme.standard.prompt),
                    ("system", percent(stats.cpuSystem), TerminalTheme.standard.dir),
                    ("nice", percent(stats.cpuNice), Color.tether.warning),
                    ("idle", percent(stats.cpuIdle), TerminalTheme.standard.dim),
                ], width: width)
                coreGrid(stats.cores, width: width)
            } else {
                Text("Reading the Mac…")
                    .font(font)
                    .foregroundStyle(TerminalTheme.standard.dim)
            }
        }
    }

    private var memoryBox: some View {
        let stats = store.monitorStats
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Memory", trailing: memoryHeadline(stats))
            meter(fraction(used: stats?.memoryUsed ?? 0, total: stats?.memoryTotal ?? 0), tint: TerminalTheme.standard.dir)
            if let stats {
                fact("wired", SystemText.bytes(stats.memoryWired))
                fact("active", SystemText.bytes(stats.memoryActive))
                fact("compressed", SystemText.bytes(stats.memoryCompressed))
                fact("cached", SystemText.bytes(stats.memoryCached))
                fact("free", SystemText.bytes(stats.memoryFree))
                sectionTitle("Swap", trailing: pair(stats.swapUsed, stats.swapTotal))
                    .padding(.top, 4)
                meter(fraction(used: stats.swapUsed, total: stats.swapTotal), tint: Color.tether.warning)
            }
        }
    }

    private var diskBox: some View {
        let stats = store.monitorStats
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Disk", trailing: pair(stats?.diskUsed ?? 0, stats?.diskTotal ?? 0))
            meter(fraction(used: stats?.diskUsed ?? 0, total: stats?.diskTotal ?? 0), tint: TerminalTheme.standard.exec)
        }
    }

    private var networkBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Network")
            fact("down", store.monitorDown)
            fact("up", store.monitorUp)
            if let stats = store.monitorStats {
                fact("received", SystemText.bytes(stats.bytesIn))
                fact("sent", SystemText.bytes(stats.bytesOut))
            }
        }
    }

    private func processBox(width: CGFloat) -> some View {
        let processes = store.monitorStats?.processes ?? []
        let size = store.fontSize
        let pidWidth = MonoLayout.width("999999", size: size)
        let cpuWidth = MonoLayout.width("999%", size: size)
        let memWidth = MonoLayout.width("999 GB", size: size)
        let threadWidth = MonoLayout.width("9999", size: size)
        let gap: CGFloat = 8
        let nameWidth = width - pidWidth - cpuWidth - memWidth - threadWidth - gap * 4
        let showThreads = nameWidth >= MonoLayout.width("Window", size: size)
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Processes", trailing: (store.monitorStats?.processCount ?? 0) > 0 ? "\(store.monitorStats?.processCount ?? 0)" : nil)
            if processes.isEmpty {
                Text("Process list isn’t available from this Mac.")
                    .font(font)
                    .foregroundStyle(TerminalTheme.standard.dim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: gap) {
                    column("PID", width: pidWidth, color: TerminalTheme.standard.dim, align: .leading)
                    column("Name", width: showThreads ? nameWidth : max(40, width - pidWidth - cpuWidth - memWidth - gap * 3), color: TerminalTheme.standard.dim, align: .leading)
                    if showThreads {
                        column("Thr", width: threadWidth, color: TerminalTheme.standard.dim, align: .trailing)
                    }
                    column("CPU", width: cpuWidth, color: TerminalTheme.standard.dim, align: .trailing)
                    column("Mem", width: memWidth, color: TerminalTheme.standard.dim, align: .trailing)
                }
                ForEach(processes) { process in
                    HStack(spacing: gap) {
                        column("\(process.pid)", width: pidWidth, color: TerminalTheme.standard.dim, align: .leading)
                        column(process.name, width: showThreads ? nameWidth : max(40, width - pidWidth - cpuWidth - memWidth - gap * 3), color: TerminalTheme.standard.fg, align: .leading)
                        if showThreads {
                            column("\(process.threads)", width: threadWidth, color: TerminalTheme.standard.fg, align: .trailing)
                        }
                        column(percent(process.cpu, cap: false), width: cpuWidth, color: TerminalTheme.standard.prompt, align: .trailing)
                        column(SystemText.bytes(process.memory), width: memWidth, color: TerminalTheme.standard.fg, align: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func column(_ text: String, width: CGFloat, color: Color, align: Alignment) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: width, alignment: align)
            .monospacedDigit()
    }

    private func sectionTitle(_ title: String, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
                .foregroundStyle(TerminalTheme.standard.fg)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(font)
                    .foregroundStyle(TerminalTheme.standard.dim)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(TerminalTheme.standard.dim)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(TerminalTheme.standard.fg)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .font(font)
    }

    private func meter(_ fraction: Double, tint: Color) -> some View {
        GeometryReader { geo in
            let clamped = min(1, max(0, fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: max(clamped > 0 ? 4 : 0, geo.size.width * clamped))
            }
        }
        .frame(height: 10)
        .accessibilityLabel("\(Int((fraction * 100).rounded())) percent")
    }

    private func stackedBar(parts: [(Double, Color)]) -> some View {
        GeometryReader { geo in
            let total = max(parts.reduce(0) { $0 + $1.0 }, 0.001)
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    let share = max(0, part.0) / total
                    Capsule()
                        .fill(part.1)
                        .frame(width: max(part.0 > 0.5 ? 4 : 0, (geo.size.width - 4) * share))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10)
    }

    private func legend(_ items: [(String, String, Color)], width: CGFloat) -> some View {
        let cell = MonoLayout.width("system 100%", size: store.fontSize) + 16
        let columns = max(1, Int(width / max(cell, 1)))
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: min(columns, items.count)), alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 6) {
                    Circle().fill(item.2).frame(width: 8, height: 8)
                    Text("\(item.0) \(item.1)")
                        .font(font)
                        .foregroundStyle(TerminalTheme.standard.fg)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
    }

    private func coreGrid(_ cores: [Double], width: CGFloat) -> some View {
        let label = MonoLayout.width("C00 100%", size: store.fontSize) + 80
        let columns = width >= label * 2 + 12 ? 2 : 1
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), alignment: .leading, spacing: 8) {
            ForEach(Array(cores.enumerated()), id: \.offset) { index, value in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("C\(index + 1)")
                            .foregroundStyle(TerminalTheme.standard.dim)
                        Spacer(minLength: 4)
                        Text(percent(value))
                            .foregroundStyle(TerminalTheme.standard.prompt)
                            .monospacedDigit()
                    }
                    .font(font)
                    meter(value / 100, tint: TerminalTheme.standard.prompt)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Core \(index + 1), \(percent(value))")
            }
        }
    }

    private func batteryLine(_ stats: SystemStats, charge: Double) -> String {
        stats.batteryCharging ? "Battery \(percent(charge)) · charging" : "Battery \(percent(charge))"
    }

    private func celsius(_ value: Double) -> String {
        String(format: "%.1f°C", value)
    }

    private func temperatureFraction(_ celsius: Double) -> Double {
        min(1, max(0, (celsius - 20) / 70))
    }

    private func temperatureColor(_ celsius: Double) -> Color {
        if celsius >= 80 { return Color.tether.danger }
        if celsius >= 55 { return Color.tether.warning }
        return TerminalTheme.standard.exec
    }

    private func healthColor(_ health: Double) -> Color {
        if health >= 80 { return TerminalTheme.standard.exec }
        if health >= 60 { return Color.tether.warning }
        return Color.tether.danger
    }

    private func percent(_ value: Double, cap: Bool = true) -> String {
        let shown = cap ? min(100, max(0, value)) : max(0, value)
        return String(format: "%.0f%%", shown)
    }

    private func fraction(used: UInt64, total: UInt64) -> Double {
        guard total > 0 else { return 0 }
        return min(1, Double(used) / Double(total))
    }

    private func pair(_ used: UInt64, _ total: UInt64) -> String {
        guard total > 0 else { return "unavailable" }
        return "\(SystemText.bytes(used)) / \(SystemText.bytes(total))"
    }

    private func memoryHeadline(_ stats: SystemStats?) -> String {
        guard let stats else { return "" }
        return pair(stats.memoryUsed, stats.memoryTotal)
    }

    private var font: Font {
        .system(size: store.fontSize, design: .monospaced)
    }
}

enum MonoLayout {
    static func uiFont(size: CGFloat) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func width(_ text: String, size: CGFloat) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: uiFont(size: size)]).width
    }

    /// Breaks a line so each piece fits `maxWidth`, measured with the terminal font.
    static func wrap(_ text: String, maxWidth: CGFloat, size: CGFloat) -> [String] {
        let source = text.isEmpty ? " " : text
        let font = uiFont(size: size)
        if measure(source, font: font) <= maxWidth { return [source] }
        var lines: [String] = []
        var current = ""
        var token = ""
        func flushToken(force: Bool) {
            let candidate = current.isEmpty ? token : current + token
            if measure(candidate, font: font) <= maxWidth {
                current = candidate
                token = ""
                return
            }
            if !current.isEmpty {
                lines.append(current)
                current = ""
                flushToken(force: force)
                return
            }
            if !force {
                return
            }
            var piece = ""
            for character in token {
                let next = piece + String(character)
                if measure(next, font: font) > maxWidth, !piece.isEmpty {
                    lines.append(piece)
                    piece = String(character)
                } else {
                    piece = next
                }
            }
            current = piece
            token = ""
        }
        for character in source {
            if character == " " {
                token.append(character)
                flushToken(force: false)
                if !token.isEmpty {
                    flushToken(force: true)
                }
            } else {
                token.append(character)
            }
        }
        if !token.isEmpty { flushToken(force: true) }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [" "] : lines
    }

    private static func measure(_ text: String, font: UIFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}
