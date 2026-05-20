@preconcurrency import GameKit

public class GameCenterGameHost: GameHost {
    
    public let match: GKMatch
    public let localServer: Server
    public let gameRoom = GameRoom()
    
    private let logger = Logger.shared
    private var connections = [UUID: GKPlayer]()
    private var disconnectedPlayers = [String: UUID]()
    
    public init(match: GKMatch, localServer: Server) {
        self.match = match
        self.localServer = localServer
//        Task { @MainActor in
//            let games = (try? await GameCenterGameHost.loadGames().sorted(by: { $0.creationDate < $1.creationDate })) ?? []
//            try lobby.addSavedGames(games)
//        }
    }
    
    public func close() {
        gameRoom.close()
    }
    
    public struct RegisterResponse: Request {
        public static let name = "register"
        
        public let user: User
    }
    
    public func addUser(_ user: User, for player: GKPlayer) {
        if player != GKLocalPlayer.local {
            connections[user.id] = player
            send(RegisterResponse(user: user), to: [user])
        }
        gameRoom.addUser(user: user)
    }
    
    public func reconnectUser(for player: GKPlayer) {
        guard let id = disconnectedPlayers[player.gamePlayerID] else {
            return
        }
        addUser(User(id: id, name: player.displayName), for: player)
    }
    
    public func removeUser(_ user: User) {
        guard let player = connections.removeValue(forKey: user.id) else {
            return
        }
        disconnectedPlayers[player.gamePlayerID] = user.id
        gameRoom.disconnected(user: user)
    }
    
    public func user(for player: GKPlayer) -> User? {
        return connections.first(where: { $0.value == player }).flatMap({ gameRoom.users.first(id: $0.key) })
    }
    
    public func send<T: Collection>(_ data: RawRequest, to users: T) where T.Element == User {
        logger.debug("Server will send message: \(data.prettyPrinted) to \(users)")
        let data = RequestCoder.encode(data)
        if let localUser = User.local, users.contains(localUser) {
            Task { @MainActor in
                localServer.receive(data)
            }
        }
        let connections = users.compactMap({ self.connections[$0.id] })
        if connections.isEmpty {
            return
        }
        do {
            try match.send(data, to: connections, dataMode: .reliable)
        } catch {
            logger.error(error.localizedDescription)
        }
    }
    
    public func receive(_ data: RawRequest, from user: User) async throws {
        logger.info("Server received message: \(data.prettyPrinted) from \(user)")
        try gameRoom.handle(user: user, action: data)
    }
    
    public func saveGame(_ data: Data, name: String) async throws {
        let _ = try await GKLocalPlayer.local.saveGameData(data, withName: name)
    }
    
    public func removeSavedGame(name: String) async throws {
        try await GKLocalPlayer.local.deleteSavedGames(withName: name)
    }
    
    private static func loadGames() async throws -> sending [SavedGame] {
        let gameCenterGames = try await GKLocalPlayer.local.fetchSavedGames()
        Logger.shared.info("Found Game Center saved games \(gameCenterGames.map({ $0.name }))")
        var games = [SavedGame]()
        for game in gameCenterGames {
            let data = try await game.loadData()
            Logger.shared.info("Reading saved game from Game Center \(game.name ?? "nil")) with modification date \(game.modificationDate?.description ?? "nil"))")
            games.append(try RequestCoder.decode(SavedGame.self, from: data))
        }
        return games
    }
    
}
