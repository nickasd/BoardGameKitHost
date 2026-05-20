import Foundation

public class GameRoom {
    
    class Player: Identifiable {
        
        fileprivate(set) var user: User
        fileprivate(set) var status: Status
        let savedPlayer: SavedPlayer
        fileprivate(set) var optionsVersion = 0
        
        init(user: User, status: Status, savedPlayer: SavedPlayer) {
            self.user = user
            self.status = status
            self.savedPlayer = savedPlayer
        }
        
        var id: UUID {
            return user.id
        }
        
    }
    
    public enum Status: String, Codable, Sendable {
        case notReady
        case ready
        case dropped
        case connecting
    }
    
    public let id = UUID()
    let name: String
    let savedGameUrl: URL?
    weak var lobby: Lobby?
    private(set) var gameManager: GameManager?
    private var realPlayers = [Player]()
    private var bots = [SavedPlayer]()
    private var deviceClients = [SavedPlayer]()
    private var observers = [User]()
    
    private let creationDate = Date()
    private var optionsVersion = 0
    private var options: any GameOptions
    private var handles = [String: (User, Data) throws -> Void]()
    private var gameCharacters = [String]()
    
    private var requiredPlayerCount: ClosedRange<Int> {
        return HostConfiguration.shared.game.requiredPlayerCount
    }
    
    init() {
        name = creationDate.formatted(date: .long, time: .shortened)
        savedGameUrl = nil
        options = HostConfiguration.shared.gameOptions.init()
        addHandles()
    }
    
    init(savedGameUrl: URL) throws {
        let savedGame = try RequestCoder.decode(SavedGame.self, from: Data(contentsOf: savedGameUrl))
        name = savedGame.creationDate.formatted(date: .long, time: .shortened)
        options = try HostConfiguration.shared.gameOptions.init(data: savedGame.options)
        self.savedGameUrl = savedGameUrl
        gameManager = try GameContext(undoManager: UndoManager()).makeCurrent {
            let gameManager = try GameManager(savedGame: savedGame, saveName: savedGameUrl.deletingPathExtension().lastPathComponent)
            try gameManager.start()
            return gameManager
        }
        gameManager!.logger = Logger.shared
        addHandles()
    }
    
    private func addHandles() {
        addHandle(leaveGameRoom)
        addHandle(setReady)
        addHandle(setNotReady)
        addHandle(addBot)
        addHandle(removeBot)
        addHandle(setBotStrategy)
        addHandle(addDeviceClient)
        addHandle(removeDeviceClient)
        addHandle(setObserver)
        addHandle(reconnect)
        addHandle(connected)
        addHandle(removeGame)
        addHandle(getGameArchive)
        addHandle(setOptions)
        addHandle(playAgain)
    }
    
    func close() {
        handles.removeAll()
        gameManager?.close()
    }
    
    func info() -> Lobby.GetLobbyResponse.Game {
        return Lobby.GetLobbyResponse.Game(id: id, name: name, hasStarted: gameManager != nil, users: users)
    }
    
    var users: [User] {
        realPlayers.map({ $0.user }) + observers
    }
    
    // MARK: - Handle request
    
    private func addHandle<T: Request>(_ handle: @escaping (_ user: User, _ data: T) throws -> Void) {
        if handles.updateValue({ user, data in
            let data = try RequestCoder.decode(T.self, from: data)
            try handle(user, data)
        }, forKey: T.name) != nil {
            preconditionFailure("Handle \(T.name) is already registered.")
        }
    }
    
    private func addHandle<T: Request>(_ handle: @escaping (_ player: Player, _ data: T) throws -> Void) {
        if handles.updateValue({ [self] user, data in
            guard let player = realPlayers.first(where: { $0.user === user }) else {
                throw HostError(message: "Unknown player \(user).")
            }
            let data = try RequestCoder.decode(T.self, from: data)
            try handle(player, data)
        }, forKey: T.name) != nil {
            preconditionFailure("Handle \(T.name) is already registered.")
        }
    }
    
    func handle(user: User, action: RawRequest) throws {
        if let handle = handles[action.name] {
            try handle(user, action.data)
        } else if let gameManager = gameManager {
            try gameManager.handle(user: user, action: action)
        } else {
            throw HostError(message: "Unhandled \(action.name).")
        }
    }
    
    private func send<T: Request>(_ data: T, to user: User) {
        Task { @MainActor in
            GameHostShared.send(data, to: [user])
        }
    }

    private func sendToAllUsers<T: Request>(_ data: T) {
        let users = users
        Task { @MainActor in
            GameHostShared.send(data, to: users)
        }
    }
    
    // MARK: - Users
    
    public struct StatusChangeResponse: Request {
        public static let name = "statusChange"
        
        public let player: UUID
        public let status: Status
    }
    
    private func setStatus(_ player: Player, _ status: Status) {
        player.status = status
        sendToAllUsers(StatusChangeResponse(player: player.savedPlayer.id, status: status))
    }
    
    private func gameDidChange() {
        optionsVersion += 1
        sendToAllUsers(SetOptionsRequestResponse(version: optionsVersion, options: options.encoded()))
        for player in realPlayers {
            if player.status == .ready && player.optionsVersion < optionsVersion {
                setStatus(player, .notReady)
            }
        }
    }
    
    public struct GetGameRoomResponse: Request {
        public static let name = "getGameRoom"
        
        public struct GameRoom: Codable, Sendable {
            public let id: UUID
            public let name: String
            public let hasStarted: Bool
            public let isRemovable: Bool
            public let hasEnded: Bool
            public let players: [Player]
            public let observers: [User]
        }
        
        public struct Player: Codable, Sendable {
            public let user: User?
            public let status: Status?
            public let savedPlayer: SavedPlayer
        }
        
        public let gameRoom: GameRoom
        public let version: Int
        public let options: String
    }
    
    public struct JoinGameRoomResponse: Request {
        public static let name = "joinGameRoom"
        
        public let player: GetGameRoomResponse.Player?
        public let observer: User?
    }
    
    func addUser(user: User) {
        if let player = gameManager?.players.first(id: user.id) {
            let player = Player(user: user, status: .notReady, savedPlayer: player.savedPlayer)
            sendToAllUsers(JoinGameRoomResponse(player: .init(user: player.user, status: player.status, savedPlayer: player.savedPlayer), observer: nil))
            realPlayers.append(player)
        } else if gameManager == nil && playerCount < requiredPlayerCount.upperBound {
            let player = Player(user: user, status: .notReady, savedPlayer: SavedPlayer(id: user.id, name: drawGameCharacter(), type: .real(userName: GameHostShared is WebSocketGameHost && user != User.local ? "" : user.name)))
            sendToAllUsers(JoinGameRoomResponse(player: .init(user: player.user, status: player.status, savedPlayer: player.savedPlayer), observer: nil))
            realPlayers.append(player)
            gameDidChange()
        } else {
            sendToAllUsers(JoinGameRoomResponse(player: nil, observer: user))
            observers.append(user)
        }
        
        let players: [GetGameRoomResponse.Player]
        if let gameManager = gameManager {
            players = gameManager.players.map { player in
                let status: Status? = switch player.savedPlayer.type {
                case .real:
                    player.user != nil ? .ready : realPlayers.first(id: player.id)?.status ?? .dropped
                case .bot:
                    nil
                case .deviceClient(let host):
                    gameManager.players.first(id: host)!.user != nil ? .ready : realPlayers.first(id: host)?.status ?? .dropped
                }
                return GetGameRoomResponse.Player(user: player.user, status: status, savedPlayer: player.savedPlayer)
            }
        } else {
            let realPlayers = realPlayers.map({ GetGameRoomResponse.Player(user: $0.user, status: $0.status, savedPlayer: $0.savedPlayer) })
            let deviceClients = deviceClients.map({ client in GetGameRoomResponse.Player(user: nil, status: self.realPlayers.first(id: client.host!)!.status, savedPlayer: client) })
            let bots = bots.map({ GetGameRoomResponse.Player(user: nil, status: nil, savedPlayer: $0) })
            players = realPlayers + deviceClients + bots
        }
        send(GetGameRoomResponse(gameRoom: .init(id: id, name: name, hasStarted: gameManager != nil, isRemovable: savedGameUrl != nil && user == .local, hasEnded: gameManager?.hasEnded == true, players: players, observers: observers), version: optionsVersion, options: options.encoded()), to: user)
    }
    
    private func drawGameCharacter() -> String? {
        if gameCharacters.isEmpty {
            gameCharacters = (HostConfiguration.shared.gameCharacters?.allCases as? [any GameCharacter])?.map({ $0.rawValue }) ?? []
        }
        return gameCharacters.indices.randomElement().map({ gameCharacters.remove(at: $0) }) ?? String((0..<9).map({ _ in "abcdefghijklmnopqrstuvwxyz".randomElement()! }))
    }
    
    private var playerCount: Int {
        return realPlayers.count + deviceClients.count + bots.count
    }
    
    public struct LeaveGameRoomRequest: Request {
        public static let name = "leaveGameRoom"
        
        public init() {
        }
    }
    
    public struct LeaveGameRoomResponse: Request {
        public static let name = "leaveGameRoom"
        
        public let user: UUID
    }
    
    private func leaveGameRoom(user: User, data: LeaveGameRoomRequest) {
        leaveGameRoom(user: user, disconnected: false)
    }
    
    func disconnected(user: User) {
        leaveGameRoom(user: user, disconnected: true)
    }
    
    private func leaveGameRoom(user: User, disconnected: Bool) {
        if let index = realPlayers.firstIndex(id: user.id) {
            let player = realPlayers.remove(at: index)
            if let gameManager = gameManager {
                try? gameManager.disconnectUser(user)
                setStatus(player, .dropped)
            } else {
                deviceClients.removeAll(where: { $0.host == player.savedPlayer.id })
                if let gameCharacter = player.savedPlayer.name {
                    gameCharacters.append(gameCharacter)
                }
                gameDidChange()
            }
        } else if let index = observers.firstIndex(of: user) {
            observers.remove(at: index)
        }
        sendToAllUsers(LeaveGameRoomResponse(user: user.id))
        if let lobby = lobby {
            lobby.sendToAllUsers(LeaveGameRoomResponse(user: user.id))
            if !disconnected {
                lobby.addUser(user)
            }
            if gameManager == nil && realPlayers.isEmpty && observers.isEmpty {
                lobby.removeGameRoom(self)
            }
        }
    }
    
    public struct SetReadyRequest: Request {
        public static let name = "setReady"
        
        let optionsVersion: Int

        public init(optionsVersion: Int) {
            self.optionsVersion = optionsVersion
        }
    }
    
    private func setReady(player: Player, data: SetReadyRequest) throws {
        guard gameManager == nil else {
            return
        }
        if data.optionsVersion < optionsVersion {
            setStatus(player, .notReady)
        } else {
            player.optionsVersion = data.optionsVersion
            setStatus(player, .ready)
            try tryToStartGame()
        }
    }
    
    public struct SetNotReadyRequest: Request {
        public static let name = "setNotReady"
        
        public init() {
        }
    }
    
    private func setNotReady(player: Player, data: SetNotReadyRequest) throws {
        guard gameManager == nil else {
            return
        }
        setStatus(player, .notReady)
    }
    
    public struct AddBotRequest: Request {
        public static let name = "addBot"
        
        public init() {
        }
    }

    private func addBot(player: Player, data: AddBotRequest) throws {
        guard gameManager == nil && playerCount < requiredPlayerCount.upperBound, let strategy = bots.first?.botStrategy ?? HostConfiguration.shared.botStrategies.first?.rawValue else {
            return
        }
        let bot = SavedPlayer(id: UUID(), name: drawGameCharacter(), type: .bot(strategy: strategy))
        bots.append(bot)
        gameDidChange()
        sendToAllUsers(JoinGameRoomResponse(player: .init(user: nil, status: nil, savedPlayer: bot), observer: nil))
    }
    
    public struct RemoveBotRequest: Request {
        public static let name = "removeBot"
        
        public let player: UUID

        public init(player: UUID) {
            self.player = player
        }
    }

    private func removeBot(player: Player, data: RemoveBotRequest) throws {
        guard gameManager == nil, let index = bots.firstIndex(id: data.player) else {
            return
        }
        let bot = bots.remove(at: index)
        if let gameCharacter = bot.name {
            gameCharacters.append(gameCharacter)
        }
        gameDidChange()
        sendToAllUsers(LeaveGameRoomResponse(user: data.player))
    }
    
    public struct SetBotStrategyRequestResponse: Request {
        public static let name = "setBotStrategy"
        
        public let strategy: String
        
        public init(strategy: String) {
            self.strategy = strategy
        }
    }

    private func setBotStrategy(player: Player, data: SetBotStrategyRequestResponse) throws {
        guard gameManager == nil, let strategy = try HostConfiguration.shared.gameStrategy?.from(data.strategy) else {
            return
        }
        bots = bots.map({ SavedPlayer(id: $0.id, name: $0.name, type: .bot(strategy: strategy.rawValue)) })
        gameDidChange()
        sendToAllUsers(data)
    }
    
    public struct AddDeviceClientRequest: Request {
        public static let name = "addDeviceClient"
        
        public init() {
        }
    }

    private func addDeviceClient(player: Player, data: AddDeviceClientRequest) throws {
        guard gameManager == nil && playerCount < requiredPlayerCount.upperBound else {
            return
        }
        let client = SavedPlayer(id: UUID(), name: drawGameCharacter(), type: .deviceClient(host: player.id))
        deviceClients.append(client)
        gameDidChange()
        sendToAllUsers(JoinGameRoomResponse(player: .init(user: nil, status: .notReady, savedPlayer: client), observer: nil))
    }
    
    public struct RemoveDeviceClientRequest: Request {
        public static let name = "removeDeviceClient"
        
        public let player: UUID

        public init(player: UUID) {
            self.player = player
        }
    }

    private func removeDeviceClient(player: Player, data: RemoveDeviceClientRequest) throws {
        guard gameManager == nil, let index = deviceClients.firstIndex(where: { $0.id == data.player && $0.host == player.id }) else {
            return
        }
        let client = deviceClients.remove(at: index)
        if let gameCharacter = client.name {
            gameCharacters.append(gameCharacter)
        }
        gameDidChange()
        sendToAllUsers(LeaveGameRoomResponse(user: data.player))
    }
    
    public struct SetObserverRequestResponse: Request {
        public static let name = "setObserver"
        
        public let observer: Bool
        
        public init(observer: Bool) {
            self.observer = observer
        }
    }

    private func setObserver(player: Player, data: SetObserverRequestResponse) throws {
        guard gameManager == nil else {
            return
        }
        if data.observer {
            if requiredPlayerCount.contains(playerCount - 1), let index = realPlayers.firstIndex(id: player.id) {
                realPlayers.remove(at: index)
                observers.append(player.user)
                try tryToStartGame()
            }
        }
    }
    
    public struct ReconnectRequest: Request {
        public static let name = "reconnect"
        
        public let player: UUID?
        public let eventGroupId: Int?
        
        public init(player: UUID?, eventGroupId: Int?) {
            self.player = player
            self.eventGroupId = eventGroupId
        }
    }
    
    private func reconnect(user: User, data: ReconnectRequest) throws {
        guard let gameManager = gameManager else {
            throw HostError.validationFailed
        }
        let player: Player?
        if let _player = data.player {
            if let index = realPlayers.firstIndex(id: user.id) {
                realPlayers.remove(at: index)
            } else if let index = observers.firstIndex(id: user.id) {
                observers.remove(at: index)
            }
            player = if GameHostShared is LocalGameHost, let player = gameManager.players.first(id: _player), case .real = player.savedPlayer.type {
                Player(user: user, status: .notReady, savedPlayer: player.savedPlayer)
            } else {
                throw HostError.validationFailed
            }
            realPlayers.append(player!)
        } else {
            player = realPlayers.first(id: user.id)
        }
        if data.eventGroupId == nil {
            send(StartGameResponse(id: id, players: gameManager.savedGame.players, options: gameManager.savedGame.options, lastReplayEventGroup: gameManager.eventGroups.last?.id, hasEnded: gameManager.hasEnded), to: user)
        }
        gameManager.reconnect(user: user, player: player?.savedPlayer.id, lastEventId: data.eventGroupId)
        if let player = player {
            if let eventGroupId = data.eventGroupId, let lastEventGroup = gameManager.eventGroups.last, eventGroupId == lastEventGroup.id {
                setStatus(player, .ready)
            } else {
                setStatus(player, .connecting)
            }
        }
        for otherPlayer in realPlayers {
            if otherPlayer !== player {
                send(StatusChangeResponse(player: otherPlayer.savedPlayer.id, status: otherPlayer.status), to: user)
            }
        }
    }
    
    public struct ConnectedRequest: Request {
        public static let name = "connected"
        
        public init() {
        }
    }
    
    private func connected(player: Player, data: ConnectedRequest) throws {
        guard gameManager != nil else {
            throw HostError.validationFailed
        }
        setStatus(player, .ready)
    }
    
    public struct RemoveGameRequest: Request {
        public static let name = "removeGame"
        
        public init() {
        }
    }
    
    private func removeGame(user: User, data: RemoveGameRequest) throws {
        guard user == .local, let name = gameManager?.saveName else {
            throw HostError.validationFailed
        }
        Task { @MainActor in // declaring GameRoom.handles as an array of async functions causes a crash before iOS 26
            do {
                try await GameHostShared.removeSavedGame(name: name)
            } catch {
                GameHostShared.send(ErrorResponse(data: error.localizedDescription), to: [user])
            }
        }
        for user in users {
            leaveGameRoom(user: user, disconnected: false)
        }
        lobby?.removeGameRoom(self)
    }
    
    public struct GetGameArchiveRequest: Request {
        public static let name = "getGameArchive"
        
        public init() {
        }
    }
    
    private func getGameArchive(user: User, data: GetGameArchiveRequest) throws {
        guard let gameManager = gameManager, gameManager.hasEnded else {
            throw HostError.validationFailed
        }
        send(GameManager.ArchiveGameResponse(name: gameManager.saveName, game: RequestCoder.encode(gameManager.savedGame, prettyPrinted: true)), to: user)
    }
    
    public struct SetOptionsRequestResponse: Request {
        public static let name = "setOptions"
        
        public let version: Int
        public let options: String
        
        public init(version: Int, options: String) {
            self.version = version
            self.options = options
        }
    }
    
    private func setOptions(player: Player, data: SetOptionsRequestResponse) throws {
        guard gameManager == nil && data.version == optionsVersion else {
            return
        }
        let options = try HostConfiguration.shared.gameOptions.init(data: data.options)
        try options.validate()
        self.options = options
        gameDidChange()
    }
    
    public struct StartGameResponse: Request {
        public static let name = "startGame"
        
        public let id: UUID
        public let players: [SavedPlayer]
        public let options: String
        public let lastReplayEventGroup: Int?
        public let hasEnded: Bool
    }

    private func tryToStartGame() throws {
        if !requiredPlayerCount.contains(playerCount) || realPlayers.contains(where: { $0.status == .notReady }) {
            return
        }
        let savedGame = SavedGame(creationDate: creationDate, players: (realPlayers.map({ $0.savedPlayer }) + bots + deviceClients).shuffled(), options: options)
        sendToAllUsers(StartGameResponse(id: id, players: savedGame.players, options: savedGame.options, lastReplayEventGroup: nil, hasEnded: false))
        
        gameManager = try GameContext(undoManager: UndoManager()).makeCurrent {
            let gameManager = try GameManager(savedGame: savedGame, saveName: savedGame.creationDate.formatted(SavedGame.nameFormatStyle()))
            gameManager.logger = Logger.shared
            try gameManager.connect(players: realPlayers.map({ ($0.user, $0.id) }), observers: observers)
            try gameManager.start()
            return gameManager
        }
        for player in realPlayers {
            sendToAllUsers(StatusChangeResponse(player: player.savedPlayer.id, status: player.status))
        }
    }
    
    public struct PlayAgainRequest: Request {
        public static let name = "playAgain"
        
        public init() {
        }
    }
    
    private func playAgain(player: Player, data: PlayAgainRequest) throws {
        guard gameManager != nil && GameHostShared is LocalGameHost else {
            throw HostError.validationFailed
        }
        
        let savedGame = SavedGame(creationDate: Date(), players: gameManager!.savedGame.players.shuffled(), options: options)
        sendToAllUsers(StartGameResponse(id: id, players: savedGame.players, options: savedGame.options, lastReplayEventGroup: nil, hasEnded: false))
        
        gameManager = try GameContext(undoManager: UndoManager()).makeCurrent {
            let gameManager = try GameManager(savedGame: savedGame, saveName: savedGame.creationDate.formatted(SavedGame.nameFormatStyle()))
            gameManager.logger = Logger.shared
            try gameManager.connect(players: realPlayers.map({ ($0.user, $0.id) }), observers: [])
            try gameManager.start()
            return gameManager
        }
        for player in realPlayers {
            sendToAllUsers(StatusChangeResponse(player: player.savedPlayer.id, status: player.status))
        }
    }
    
}
