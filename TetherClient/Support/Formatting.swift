import Foundation
import TetherCore

enum Format {
    static func bytes(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(value))
    }

    static func kind(_ entry: FileEntry) -> String {
        if entry.kind == .dir, !isPackage(entry) { return "Folder" }
        if entry.kind == .link { return "Alias" }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "PDF document"
        case "jpg", "jpeg": return "JPEG image"
        case "png": return "PNG image"
        case "heic": return "HEIC image"
        case "gif": return "GIF image"
        case "webp": return "WebP image"
        case "mp4", "mov", "m4v": return "Movie"
        case "mp3", "m4a", "wav", "aac": return "Audio"
        case "zip", "gz", "tar": return "Archive"
        case "txt", "md", "log": return "Text"
        case "doc", "docx": return "Word document"
        case "pages": return "Pages document"
        case "xls", "xlsx", "numbers": return "Spreadsheet"
        case "ppt", "pptx", "key": return "Presentation"
        case "app": return "Application"
        case "photoslibrary": return "Photo library"
        case "dmg": return "Disk image"
        default: return ext.isEmpty ? "File" : "\(ext.uppercased()) file"
        }
    }

    static func isPackage(_ entry: FileEntry) -> Bool {
        guard entry.kind == .dir else { return false }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        return ["app", "pages", "numbers", "key", "rtfd", "bundle", "framework", "photoslibrary", "sparsebundle", "xcodeproj", "playground", "band"].contains(ext)
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
        let when = Format.when(entry.modified, includeTime: false)
        if entry.kind == .dir, !isPackage(entry) {
            var parts: [String] = []
            if let count = entry.childCount {
                parts.append("\(count) \(count == 1 ? "item" : "items")")
            } else {
                parts.append("Folder")
            }
            if entry.size > 0 { parts.append(bytes(entry.size)) }
            parts.append(when)
            return parts.joined(separator: " · ")
        }
        return "\(kind(entry)) · \(bytes(entry.size)) · \(when)"
    }

    static func exactBytes(_ value: UInt64) -> String {
        "\(value.formatted()) bytes"
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
