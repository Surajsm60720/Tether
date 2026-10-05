import Foundation
import TetherCore

enum Format {
    static func bytes(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(value))
    }

    static func kind(_ entry: FileEntry) -> String {
        if entry.kind == .dir { return "Folder" }
        if entry.kind == .link { return "Alias" }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "PDF document"
        case "jpg", "jpeg": return "JPEG image"
        case "png": return "PNG image"
        case "heic": return "HEIC image"
        case "gif": return "GIF image"
        case "mp4", "mov", "m4v": return "Movie"
        case "mp3", "m4a", "wav", "aac": return "Audio"
        case "zip", "gz", "tar": return "Archive"
        case "txt", "md", "log": return "Text"
        case "doc", "docx": return "Word document"
        case "pages": return "Pages document"
        case "xls", "xlsx": return "Spreadsheet"
        case "ppt", "pptx", "key": return "Presentation"
        default: return ext.isEmpty ? "File" : "\(ext.uppercased()) file"
        }
    }

    static func when(_ date: Date, includeTime: Bool) -> String {
        if includeTime {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func subtitle(_ entry: FileEntry) -> String {
        if entry.kind == .dir {
            if let count = entry.childCount { return "Folder · \(count) items" }
            return "Folder · \(Format.when(entry.modified, includeTime: false))"
        }
        return "\(kind(entry)) · \(Format.bytes(entry.size)) · \(Format.when(entry.modified, includeTime: false))"
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
