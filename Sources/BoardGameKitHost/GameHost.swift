import Foundation

nonisolated(unsafe) public var GameHostShared: GameHost!

@MainActor public protocol GameHost {
    func send<T: Collection>(_ data: RawRequest, to users: T) where T.Element == User
    func receive(_ data: RawRequest, from user: User) async throws
    nonisolated func saveGame(_ data: Data, name: String) async throws
    nonisolated func removeSavedGame(name: String) async throws
    func close()
}

extension GameHost {
    
    func send<T: Collection, U: Request>(_ data: U, to users: T) where T.Element == User {
        send(RawRequest(data), to: users)
    }
    
    public func receive(_ data: Data, from user: User) {
        Task {
            do {
                let data = try RequestCoder.decode(RawRequest.self, from: data)
                try await receive(data, from: user)
            } catch {
                send(ErrorResponse(data: error.localizedDescription), to: [user])
            }
        }
    }
    
}

@MainActor public protocol Server {
    var delegate: ServerDelegate? { get set }
    func connect()
    func disconnect()
    func send<T: Request>(_ data: T)
    func receive(_ data: Data)
}

public protocol ServerDelegate: AnyObject {
    func server(_ server: Server, handleError error: Error)
    func serverDidConnect(_ server: Server)
    func serverDidDisconnect(_ server: Server)
    func server(_ server: Server, didReceiveRequest request: RawRequest)
    func serverShouldReinvitePlayer(_ server: Server) -> Bool
}

final public class User: Identifiable, Equatable, Hashable, Codable, @unchecked Sendable, CustomStringConvertible {
    
    public static func == (lhs: User, rhs: User) -> Bool {
        return lhs === rhs
    }
    
    public func hash(into hasher: inout Hasher) {
        ObjectIdentifier(self).hash(into: &hasher)
    }
    
    nonisolated(unsafe) public static var local: User?
    
    public private(set) var id: UUID
    public private(set) var name: String
    
    public init(id: UUID, name: String?) {
        self.id = id
        self.name = name ?? id.uuidString
    }
    
    public var description: String {
        return id.uuidString
    }
    
    func rename(id: UUID, name: String?) {
        self.id = id
        self.name = name ?? id.uuidString
    }
    
}

public struct ErrorResponse: Request {
    public static let name = "error"
    
    public let data: String
    
    init(data: String) {
        self.data = data
    }
}

extension String.StringInterpolation {
    
    mutating func appendInterpolation(_ value: User) {
        appendInterpolation("\(value.id)")
    }
    
}
