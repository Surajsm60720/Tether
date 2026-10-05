import Foundation
import TetherCore

enum Format {
    static func bytes(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(value))
    }

    static func when(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func subtitle(_ entry: FileEntry) -> String {
        if entry.kind == .dir {
            if let count = entry.childCount { return "\(count) items" }
            return Format.when(entry.modified)
        }
        return "\(Format.when(entry.modified)) · \(Format.bytes(entry.size))"
    }

    static func symbol(for entry: FileEntry) -> String {
        if entry.kind == .dir { return "folder.fill" }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "heic", "gif", "webp": return "photo"
        case "mp4", "mov", "m4v": return "film"
        case "mp3", "m4a", "wav", "aac": return "waveform"
        case "zip", "gz", "tar": return "archivebox"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }

    static func speed(bytes: UInt64, since: Date) -> String {
        let seconds = max(Date().timeIntervalSince(since), 0.1)
        let perSecond = Double(bytes) / seconds
        return Format.bytes(UInt64(perSecond)) + "/s"
    }

    static func eta(sent: UInt64, total: UInt64, since: Date) -> String {
        let seconds = max(Date().timeIntervalSince(since), 0.1)
        let rate = Double(sent) / seconds
        guard rate > 1, total > sent else { return "" }
        let left = Double(total - sent) / rate
        return "\(Int(left)) s left"
    }
}
