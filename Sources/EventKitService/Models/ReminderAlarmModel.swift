import Foundation

/// The transport-safe representation of every alarm shape supported by EventKit.
public enum ReminderAlarmModel: Sendable, Equatable {
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

extension ReminderAlarmModel: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case minutesBefore
        case absoluteDate
        case proximity
        case structuredLocation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .relative:
            let minutes = try container.decode(Int.self, forKey: .minutesBefore)
            guard minutes >= 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .minutesBefore,
                    in: container,
                    debugDescription: "Relative alarm minutes must be non-negative"
                )
            }
            self = .relative(minutesBefore: minutes)
        case .absolute:
            self = .absolute(try container.decode(Date.self, forKey: .absoluteDate))
        case .location:
            self = .location(
                try container.decode(StructuredLocation.self, forKey: .structuredLocation),
                proximity: try container.decode(Proximity.self, forKey: .proximity)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)

        switch self {
        case .relative(let minutesBefore):
            try container.encode(minutesBefore, forKey: .minutesBefore)
        case .absolute(let date):
            try container.encode(date, forKey: .absoluteDate)
        case .location(let location, let proximity):
            try container.encode(proximity, forKey: .proximity)
            try container.encode(location, forKey: .structuredLocation)
        }
    }
}
