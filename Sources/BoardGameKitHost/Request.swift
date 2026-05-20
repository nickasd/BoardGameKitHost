import Foundation

public protocol Request: Codable, Sendable {
    static var name: String { get }
}

public struct RawRequest: Codable, Sendable {
    public let name: String
    public let data: Data
    
    public init<T: Request>(_ data: T) {
        self.name = T.name
        self.data = RequestCoder.encode(data)
    }
    
    public var prettyPrinted: String {
        let string = (try? String(decoding: JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: .prettyPrinted), as: UTF8.self)) ?? "Invalid JSON."
        return "\(name) \(string)"
    }
}

public class RequestCoder {
    
    public static func encode<T: Encodable>(_ data: T, prettyPrinted: Bool = false) -> Data {
        do {
            let encoder = JSONEncoder()
            let dateFormat = {
                var format = Date.ISO8601FormatStyle().year().month().day().time(includingFractionalSeconds: true).dateTimeSeparator(.space).timeZone(separator: .omitted)
                format.timeZone = .current
                return format
            }()
            encoder.dateEncodingStrategy = .custom({ date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(date.formatted(dateFormat))
            })
            encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
            return try encoder.encode(data)
        } catch {
            fatalError("Error during encoding of \(T.self): \(error.localizedDescription)")
        }
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            let decoder = JSONDecoder()
            let dateFormat = Date.ISO8601FormatStyle().year().month().day().time(includingFractionalSeconds: true).dateTimeSeparator(.space).timeZone(separator: .omitted)
            decoder.dateDecodingStrategy = .custom({ decoder in
                return try dateFormat.parse(decoder.singleValueContainer().decode(String.self))
            })
            return try decoder.decode(type, from: data)
        } catch {
            print(error)
            throw HostError(message: "Error during decoding of \(T.self): \(error.localizedDescription)")
        }
    }
    
}

public struct HostError: Error, LocalizedError {
    public static let validationFailed = HostError(message: "Validation failed.")
    
    public let message: String
    
    public init(message: String) {
        self.message = message
    }
    
    public var errorDescription: String? {
        return message
    }
}
