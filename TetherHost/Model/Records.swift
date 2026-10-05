import Foundation
import SwiftData

@Model
final class ShareRecord {
    var id: UUID
    var displayName: String
    var bookmark: Data
    var writable: Bool
    var createdAt: Date

    init(id: UUID = UUID(), displayName: String, bookmark: Data, writable: Bool, createdAt: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.bookmark = bookmark
        self.writable = writable
        self.createdAt = createdAt
    }
}

@Model
final class DeviceRecord {
    var deviceId: String
    var name: String
    var pairedAt: Date
    var lastSeenAt: Date?

    init(deviceId: String, name: String, pairedAt: Date = Date(), lastSeenAt: Date? = nil) {
        self.deviceId = deviceId
        self.name = name
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
    }
}
