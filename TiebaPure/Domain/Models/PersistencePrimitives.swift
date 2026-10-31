import Foundation
import OSLog

enum PersistenceAvailability: Equatable, Sendable {
    case available
    case unavailable

    var canPersist: Bool {
        self == .available
    }
}

enum PersistenceFaultPoint: Equatable {
    case legacyMigration
    case repair
    case clearAll
}

struct PersistenceFaultInjector {
    static let none = PersistenceFaultInjector { _ in }

    private let handler: (PersistenceFaultPoint) throws -> Void

    init(_ handler: @escaping (PersistenceFaultPoint) throws -> Void) {
        self.handler = handler
    }

    func check(_ point: PersistenceFaultPoint) throws {
        try handler(point)
    }
}

struct PersistenceLoadResult<Value> {
    let value: Value
    let repairError: Error?
}

enum PersistenceDiagnostics {
    private static let logger = Logger(
        subsystem: "dev.infinityf4p.tiebapure",
        category: "Persistence"
    )
    private static let recentLock = NSLock()
    private static var recentReportsValue: [String] = []

    static func report(_ error: Error, operation: String) {
        appendRecent("\(operation): \(String(describing: error))")
        logger.error("\(operation, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }

    static func recentReports() -> [String] {
        recentLock.lock()
        defer { recentLock.unlock() }
        return recentReportsValue
    }

    private static func appendRecent(_ report: String) {
        recentLock.lock()
        defer { recentLock.unlock() }
        recentReportsValue.append(report)
        if recentReportsValue.count > 30 {
            recentReportsValue.removeFirst(recentReportsValue.count - 30)
        }
    }
}

enum LegacyStorageMigration {
    enum DecodeError: Error {
        case invalidTopLevelArray
    }

    static func persistThenRemoveLegacyValue(
        defaults: UserDefaults,
        key: String,
        destinationIsDurable: Bool,
        persist: () throws -> Void
    ) throws {
        try persist()
        guard destinationIsDurable else { return }
        defaults.removeObject(forKey: key)
    }
}

struct FailableDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) {
        value = try? Value(from: decoder)
    }
}

enum PersistedArrayDecoder {
    static func decode<Element: Decodable>(_ type: Element.Type, from data: Data) -> [Element]? {
        guard let boxes = try? JSONDecoder().decode(
            [FailableDecodable<Element>].self,
            from: data
        ) else {
            return nil
        }
        return boxes.compactMap(\.value)
    }
}
