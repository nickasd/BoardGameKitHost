import Foundation

public class Lobby {

    public private(set) var users = [User]()
    public private(set) var gameRooms = [GameRoom]()
    
    private var handles = [String: (User, Data) throws -> Void]()

    init() {
        addHandle(addGame)
        addHandle(importGame)
        addHandle(joinGame)
    }
    
    func close() {
        handles.removeAll()
        for gameRoom in gameRooms {
            gameRoom.close()
        }
    }
    
    // MARK: - Handle request

    private func addHandle<T: Request>(_ handle: @escaping (_ user: User, _ data: T) throws -> Void) {
        if handles.updateValue({
            try handle($0, RequestCoder.decode(T.self, from: $1))
        }, forKey: T.name) != nil {
            preconditionFailure("Handle for action \(T.name) is already registered.")
        }
    }

    public func handle(user: User, action: RawRequest) throws {
        if let handle = handles[action.name] {
            try handle(user, action.data)
        } else if let room = gameRooms.first(where: { $0.users.contains(user) }) {
            try room.handle(user: user, action: action)
        } else {
            throw HostError(message: "Unhandled action \(action.name).")
        }
    }
    
    func sendToAllUsers<T: Request>(_ data: T) {
        let users = users
        Task { @MainActor in
            GameHostShared.send(data, to: users)
        }
    }
    
    // MARK: - Add and remove users
    
    public struct DisconnectResponse: Request {
        public static let name = "disconnect"
        
        public let user: UUID
    }

    public func disconnected(user: User) {
        if let index = users.firstIndex(of: user) {
            users.remove(at: index)
            sendToAllUsers(DisconnectResponse(user: user.id))
        }
    }

    public struct EnterLobbyResponse: Request {
        public static let name = "enterLobby"
        
        public let user: User
    }
    
    func enter(user: User) throws {
        if user.name.isEmpty {
            throw HostError(message: "User is unregistered.")
        } else if users.contains(user) {
            throw HostError(message: "User is already inside lobby.")
        }
        sendToAllUsers(EnterLobbyResponse(user: .init(id: user.id, name: user.name)))
        addUser(user)
    }
    
    public struct GetLobbyResponse: Request {
        public static let name = "getLobby"
        
        public struct Game: Codable, Sendable {
            public let id: UUID
            public let name: String
            public let hasStarted: Bool
            public let users: [User]
        }
        
        public let users: [User]
        public let games: [Game]
    }
    
    func addUser(_ user: User) {
        users.append(user)
        let data = GetLobbyResponse(users: users.map({ .init(id: $0.id, name: $0.name) }), games: gameRooms.map({ $0.info() }))
        Task { @MainActor in
            GameHostShared.send(data, to: [user])
        }
    }
    
    // MARK: - Add and remove games
    
    public struct AddGameRequest: Request {
        public static let name = "addGame"
        
        public init() {
        }
    }
    
    public struct AddGameResponse: Request {
        public static let name = "addGame"
        
        public let game: GetLobbyResponse.Game
    }
    
    private func addGame(user: User, data: AddGameRequest) {
        let room = GameRoom()
        room.lobby = self
        gameRooms.append(room)
        sendToAllUsers(AddGameResponse(game: room.info()))
        joinGameRoom(room, user: user)
    }
    
    public func addSavedGame(_ url: URL) throws {
        do {
            Logger.shared.info("Listing game at \(url.path)")
            let room = try GameRoom(savedGameUrl: url)
            room.lobby = self
            gameRooms.append(room)
        } catch {
            throw HostError(message: "Error while loading saved game at\n\(url.path)\n\n\(error.localizedDescription)")
        }
    }
    
    public struct ImportGameRequest: Request {
        public static let name = "importGame"
        
        public let game: Data
        
        public init(game: Data) {
            self.game = game
        }
    }
    
    private func importGame(user: User, data: ImportGameRequest) throws {
        let name = Date().formatted(SavedGame.nameFormatStyle())
        try LocalGames.shared.saveGame(data.game, name: name)
        let room = try GameRoom(savedGameUrl: LocalGames.shared.saveUrl(forName: name))
        room.lobby = self
        gameRooms.append(room)
        sendToAllUsers(AddGameResponse(game: room.info()))
        joinGameRoom(room, user: user)
    }
    
    public struct JoinGameRequest: Request {
        public static let name = "joinGame"
        
        let game: UUID
        
        public init(game: UUID) {
            self.game = game
        }
    }
    
    public struct JoinGameResponse: Request {
        public static let name = "joinGame"
        
        public let user: UUID
        public let game: UUID
    }
    
    private func joinGame(user: User, data: JoinGameRequest) throws {
        guard let room = gameRooms.first(where: { $0.id == data.game }) else {
            return
        }
        joinGameRoom(room, user: user)
    }
    
    private func joinGameRoom(_ room: GameRoom, user: User) {
        if let index = users.firstIndex(of: user) {
            sendToAllUsers(JoinGameResponse(user: user.id, game: room.id))
            users.remove(at: index)
        }
        room.addUser(user: user)
    }
    
    public struct RemoveGameResponse: Request {
        public static let name = "removeGame"
        
        public let game: UUID
    }

    func removeGameRoom(_ gameRoom: GameRoom) {
        gameRooms.remove(at: gameRooms.firstIndex(where: { $0.id == gameRoom.id })!).close()
        sendToAllUsers(RemoveGameResponse(game: gameRoom.id))
    }

}
