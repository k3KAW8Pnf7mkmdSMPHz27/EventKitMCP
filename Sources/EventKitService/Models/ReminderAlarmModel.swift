import Foundation

/// The transport-safe representation of every alarm shape supported by EventKit.
public enum ReminderAlarmModel: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case relative
        case absolute
        case location
    }

    public enum Proximity: String, Sendable, CaseIterable {
        case none
        case enter
        case leave
    }

    public struct StructuredLocation: Sendable, Equatable {
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

    case relative(minutesBefore: Int)
    case absolute(Date)
    case location(StructuredLocation, proximity: Proximity)

    public var kind: Kind {
        switch self {
        case .relative: .relative
        case .absolute: .absolute
        case .location: .location
        }
    }
}
