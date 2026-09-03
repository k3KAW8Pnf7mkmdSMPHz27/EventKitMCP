import Foundation

/// The transport-safe representation of every alarm shape supported by EventKit.
public struct ReminderAlarmModel: Codable, Sendable, Equatable, ExpressibleByIntegerLiteral {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case relative
        case absolute
        case location
    }

    public enum Proximity: String, Codable, Sendable, CaseIterable {
        case none
        case enter
        case leave
    }

    public struct StructuredLocation: Codable, Sendable, Equatable {
        public let title: String
        public let latitude: Double
        public let longitude: Double
        public let radius: Double

        public init(title: String, latitude: Double, longitude: Double, radius: Double) {
            self.title = title
            self.latitude = latitude
            self.longitude = longitude
            self.radius = radius
        }
    }

    public let kind: Kind
    /// Positive minutes before the reminder's start date.
    public let minutesBefore: Int?
    public let absoluteDate: Date?
    public let proximity: Proximity?
    public let structuredLocation: StructuredLocation?

    public init(
        kind: Kind,
        minutesBefore: Int? = nil,
        absoluteDate: Date? = nil,
        proximity: Proximity? = nil,
        structuredLocation: StructuredLocation? = nil
    ) {
        self.kind = kind
        self.minutesBefore = minutesBefore
        self.absoluteDate = absoluteDate
        self.proximity = proximity
        self.structuredLocation = structuredLocation
    }

    public static func relative(minutesBefore: Int) -> Self {
        .init(kind: .relative, minutesBefore: minutesBefore)
    }

    public static func absolute(_ date: Date) -> Self {
        .init(kind: .absolute, absoluteDate: date)
    }

    public static func location(_ location: StructuredLocation, proximity: Proximity) -> Self {
        .init(kind: .location, proximity: proximity, structuredLocation: location)
    }

    public init(integerLiteral value: Int) {
        self = .relative(minutesBefore: value)
    }
}
