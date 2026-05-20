import Foundation

/// A game manager runs a game and acts as a communication layer between the game and the outside world. It observes player state changes, tracks player statistics such as the action count and active time, manages the undo stack and undoes the changes in the current request if an error occurs, determines bot actions when appropriate, saves the game after a valid action and loads a saved game validating the input.
public class GameManager: AsyncGameActionHandler {

    class Player: Hashable, Identifiable, CustomStringConvertible {
        
        static func == (lhs: Player, rhs: Player) -> Bool {
            return lhs === rhs
        }
        
        func hash(into hasher: inout Hasher) {
            ObjectIdentifier(self).hash(into: &hasher)
        }
        
        let savedPlayer: SavedPlayer
        fileprivate(set) var user: User?
        
        fileprivate(set) var activeTimeStart: Date?
        fileprivate(set) var activeTime = TimeInterval(0)
        @Recorded fileprivate(set) var actionCount = 0
        
        init(savedPlayer: SavedPlayer) {
            self.savedPlayer = savedPlayer
        }
        
        var id: UUID {
            return savedPlayer.id
        }
        
        var description: String {
            return id.uuidString
        }

    }
    
    public struct EventGroup {
        public struct PlayerState: Codable, Sendable {
            public let id: UUID
            public let state: String?
            public let activeTime: TimeInterval
            public let activeTimeStart: Date?
            public let actionCount: Int
        }
        
        let id: Int
        /// Indicates whether the event group was triggered by a live human action, as opposed to a bot action or an automatically queued action. Live actions should be run immediately by a client, whereas all other actions (which can be more or less instantaneous) should run when the previous actions have completed.
        let isLiveAction: Bool
        let events: [GameActionContext.Event]
        let playerStateChanges: [PlayerState]?
        let hasEnded: Bool?
        
        /// Returns the events with all private data involving at least one of the given `players`.
        func events(for players: [UUID]) -> [PlayerEvent] {
            return events.compactMap({ $0.apply(for: players) })
        }
    }
    
    let savedGame: SavedGame
    let game: (any Game)
    let players: [Player]
    private(set) var observers = [User]()
    let saveName: String
    var logger: Logger?
    
    private var handles = [String: (Player, Data) throws -> Void]()
    private let gameContext = GameContext.current
    private var currentDevicePlayer = [Player: Player]()
    private var actions = RecordedArray<SavedAction>()
    private(set) var eventGroups = [EventGroup]()
    private var isRunningQueue = false
    private var queue = [GameActionContext.QueueElement]()
    
    private var undoManager: UndoManager {
        return gameContext.undoManager!
    }
    
    public init(savedGame: SavedGame, saveName: String) throws {
        self.savedGame = savedGame
        self.game = try HostConfiguration.shared.game.from(savedGame: savedGame)
        for player in savedGame.players {
            switch player.type {
            case .bot(let strategy):
                if let gameStrategy = HostConfiguration.shared.gameStrategy {
                    let _ = try gameStrategy.from(strategy)
                } else {
                    throw HostError(message: "The game doesn't support bots. It must implement the GameBot protocol.")
                }
            case .deviceClient(let host):
                if host == player.id || savedGame.players.first(id: host) == nil {
                    throw HostError(message: "Invalid player host \(host).")
                }
            default:
                break
            }
        }
        self.players = savedGame.players.map({ Player(savedPlayer: $0) })
        self.saveName = saveName
        
        addHandle(gameAction)
        addHandle(undo)
        addHandle(changeLocalPlayer)
    }
    
    func close() {
        handles.removeAll()
        game.close()
        undoManager.removeAllActions()
    }
    
    func connect(players: [(user: User, player: UUID)], observers: [User]) throws {
        for (user, player) in players {
            try self.players.first(id: player).get().user = user
        }
        self.observers = observers
    }
    
    var hasEnded: Bool {
        return eventGroups.last?.hasEnded == true
    }
    
    // MARK: - Save and load
    
    public struct ArchiveGameResponse: Request {
        public static let name = "archiveGame"
        
        public let name: String
        public let game: Data
    }
    
    private func save() {
        let saveName = saveName
        savedGame.actions = actions.elements
        let data = RequestCoder.encode(savedGame, prettyPrinted: true)
        Task { [logger] in
            do {
                try await GameHostShared.saveGame(data, name: saveName)
            } catch {
                logger?.error(error.localizedDescription)
            }
        }
        if hasEnded {
            (game as? any AsyncGame)?.asyncActionHandler = nil
            send(ArchiveGameResponse(name: saveName, game: data), to: players.compactMap({ $0.user }) + observers)
            Task { [logger] in
                do {
                    try LocalGames.shared.archiveGame(data, name: saveName)
                    try await GameHostShared.removeSavedGame(name: saveName)
                } catch {
                    logger?.error(error.localizedDescription)
                }
            }
        }
    }
    
    func start() throws {
        queue.append(.init(player: nil, action: game.initialAction()))
        if !savedGame.actions.isEmpty {
            isRunningQueue = true
            try replay()
            isRunningQueue = false
        }
        if !hasEnded {
            runQueueAndBots()
            (game as? any AsyncGame)?.asyncActionHandler = self
        }
    }
    
    private func replay() throws {
        logger?.info("Starting replay of \(savedGame.creationDate)...")
        let replayLogger = Logger(writeToFile: .staticFile(name: "replay.log"), writeToConsole: false)
        try? FileManager.default.removeItem(at: replayLogger.url!)
        
        for action in savedGame.actions {
            replayLogger.timestamp = action.date
            if let player = action.player {
                replayLogger.info("Server received message from \(player): \(action.name) \(action.id) \(action.data)")
            } else {
                replayLogger.info("Created ambient action: \(action.name) \(action.id) \(action.data)")
            }
            
            do {
                if let expectedAction = queue.first {
                    queue.removeFirst()
                    let expectedName = type(of: expectedAction.action).name
                    if expectedName != action.name || expectedAction.player != action.player {
                        if let expectedPlayer = expectedAction.player {
                            throw HostError(message: "Expected action \(expectedName) from player \(expectedPlayer).")
                        } else {
                            throw HostError(message: "Expected ambient action \(expectedName).")
                        }
                    }
                }
                
                try handleGameAction(context: GameActionContext(action: action, isReplay: true))
            } catch {
                throw HostError(message: "Replay action \(action.id) (\(action.name)) failed. \(error.localizedDescription)")
            }
            
            if let eventGroup = eventGroups.last {
                for playerSet in playerPartitions(for: eventGroup, limitedTo: players) {
                    let data = RawRequest(EventGroupResponse(id: eventGroup.id, isLiveAction: eventGroup.isLiveAction, events: eventGroup.events(for: playerSet.ids), playerStateChanges: eventGroup.playerStateChanges, hasEnded: eventGroup.hasEnded))
                    replayLogger.info("Server will send message: \(data.prettyPrinted) to \(playerSet)")
                }
            }
        }
        
        logger?.info("Ended replaying \(actions.count) actions.")
    }
    
    // MARK: - Handle request
    
    private func addHandle<T: Request>(_ handle: @escaping (_ player: Player, _ data: T) throws -> Void) {
        if handles.updateValue({ player, data in
            let data = try RequestCoder.decode(T.self, from: data)
            try handle(player, data)
        }, forKey: T.name) != nil {
            preconditionFailure("Handle \(T.name) is already registered.")
        }
    }
    
    func handle(user: User, action: RawRequest) throws {
        if let handle = handles[action.name] {
            let player = try players.first(where: { $0.user == user }).get()
            try handle(player, action.data)
        } else {
            throw HostError(message: "Unhandled \(action.name).")
        }
    }
    
    public struct GameActionRequest: Request {
        public static let name = "gameAction"
        
        public let name: String
        public let data: String
        
        public init<T: GameAction>(_ data: T) {
            self.name = T.name
            self.data = String(decoding: RequestCoder.encode(data), as: UTF8.self)
        }
        
        public var prettyPrinted: String {
            let string = (try? String(decoding: JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: Data(data.utf8)), options: .prettyPrinted), as: UTF8.self)) ?? "Invalid JSON."
            return "\(name) \(string)"
        }
    }
    
    public struct GameErrorResponse: Request {
        public static let name = "gameError"
        
        /// The name of the action that triggered the error.
        public let action: String
        /// The error message.
        public let error: String
    }
    
    private func gameAction(hostPlayer: Player, data: GameActionRequest) throws {
        let player = currentDevicePlayer[hostPlayer] ?? hostPlayer
        do {
            try gameContext.makeCurrent {
                try handleGameAction(player: player.id, action: data)
            }
        } catch let error as GameEventFailure {
            if let user = hostPlayer.user {
                send(GameErrorResponse(action: data.name, error: String(decoding: try JSONEncoder().encode(error), as: UTF8.self)), to: [user])
            }
        } catch {
            throw error
        }
    }
    
    public struct UndoRequestResponse: Request {
        public static let name = "undo"
        
        public let eventGroup: Int
        
        public init(eventGroup: Int) {
            self.eventGroup = eventGroup
        }
    }
    
    private func undo(player: Player, data: UndoRequestResponse) throws {
        if !undoManager.canUndo(to: data.eventGroup) {
            throw HostError(message: "Invalid event group.")
        } else if undoManager.currentEventGroup == data.eventGroup {
            return
        }
        gameContext.makeCurrent {
            undoManager.undo(to: data.eventGroup)
        }
        
        let eventGroupId = eventGroups.count
        eventGroups.append(EventGroup(id: eventGroups.count, isLiveAction: false, events: [GameActionContext.Event(player: nil, request: data, playerPartitions: [], privateData: nil)], playerStateChanges: nil, hasEnded: nil)) // we have to keep a linear event group history, since players can request to be reconnected starting from any event group
        sendEventGroupHistory(eventGroupId: eventGroupId, toPlayers: players.filter({ $0.savedPlayer.botStrategy == nil }))
        sendEventGroupHistory(eventGroupId: eventGroupId, toObservers: observers)
        
        if !undoManager.canRedo {
            runQueueAndBots()
        }
    }
    
    public struct ChangeLocalPlayerRequest: Request {
        public static let name = "changeLocalPlayer"
        
        public let player: UUID?
        
        public init(player: UUID?) {
            self.player = player
        }
    }
    
    private func changeLocalPlayer(hostPlayer: Player, data: ChangeLocalPlayerRequest) throws {
        if let player = data.player {
            if let player = players.first(id: player), player == hostPlayer || player.savedPlayer.host == hostPlayer.id {
                currentDevicePlayer[hostPlayer] = player
            } else {
                throw HostError(message: "Invalid device player.")
            }
        } else {
            currentDevicePlayer.removeValue(forKey: hostPlayer)
        }
    }
    
    // MARK: - Game action
    
    private func handleGameAction(player: UUID?, action: GameActionRequest) throws {
        let action = SavedAction(id: actions.count + 1, date: Date(), player: player, name: action.name, data: action.data, replayData: nil)
        try handleGameAction(context: GameActionContext(action: action, isReplay: false))
        save()
        runQueueAndBots()
    }
    
    public func handleAsyncGameAction(player: UUID?, action: any GameAction) {
        let action = GameActionRequest(action)
        do {
            try handleGameAction(player: player, action: action)
        } catch {
            preconditionFailure("Error during handling of async action: \(action.prettyPrinted)\n\(error.localizedDescription)")
        }
    }
    
    private func handleGameAction(context: GameActionContext) throws {
        undoManager.beginUndoGrouping()
        do {
            try game.handle(context: context)
        } catch {
            undoManager.undo()
            throw error
        }
        let action = if let replayData = context.replayData, case let action = context.action {
            SavedAction(id: action.id, date: action.date, player: action.player, name: action.name, data: action.data, replayData: String(decoding: RequestCoder.encode(replayData), as: UTF8.self))
        } else {
            context.action
        }
        actions.append(action)
        if let player = action.player {
            try players.first(id: player).get().actionCount += 1
        }
        undoManager.endUndoGrouping()
        
        queue.append(contentsOf: context.queue)
        try updatePlayersActiveTime(context: context)
        try addEventGroup(context: context)
    }
    
    private func updatePlayersActiveTime(context: GameActionContext) throws {
        for (player, state) in context.playerStateChanges {
            let player = try players.first(id: player).get()
            if let activeTimeStart = player.activeTimeStart {
                if state == nil {
                    player.activeTime += context.action.date.timeIntervalSince(activeTimeStart)
                    player.activeTimeStart = nil
                }
            } else {
                if state != nil {
                    player.activeTimeStart = context.action.date
                }
            }
        }
    }
    
    private func addEventGroup(context: GameActionContext) throws {
        let playerStateChanges = try context.playerStateChanges.map { player, state in
            let player = try players.first(id: player).get()
            return EventGroup.PlayerState(id: player.id, state: state, activeTime: player.activeTime, activeTimeStart: player.activeTimeStart, actionCount: player.actionCount)
        }
        let eventGroup = EventGroup(id: eventGroups.count, isLiveAction: !isRunningQueue, events: context.generatedEvents, playerStateChanges: playerStateChanges.isEmpty ? nil : playerStateChanges, hasEnded: context.hasEnded ? true : nil)
        eventGroups.append(eventGroup)
        sendEventGroupHistory(eventGroupId: eventGroup.id, toPlayers: players.filter({ $0.savedPlayer.botStrategy == nil }))
        sendEventGroupHistory(eventGroupId: eventGroup.id, toObservers: observers)
    }
    
    private func runQueueAndBots() {
        if isRunningQueue {
            return
        }
        isRunningQueue = true
        while true {
            if let queuedAction = queue.first {
                queue.removeFirst()
                let action = GameActionRequest(queuedAction.action)
                do {
                    try handleGameAction(player: queuedAction.player, action: action)
                } catch {
                    preconditionFailure("Error during handling of queued action: \(action.prettyPrinted)\n\(error.localizedDescription)")
                }
                save()
            } else if let player = players.first(where: { $0.savedPlayer.botStrategy != nil && $0.activeTimeStart != nil }) {
                let game = game as! any GameBot
                logger?.info("Determining action \(actions.count + 1) for bot \(player)...")
                do {
                    if let action = try game.action(for: player.id, strategy: player.savedPlayer.botStrategy!) {
                        queue.append(.init(player: player.id, action: action))
                    }
                } catch {
                    preconditionFailure("Error while determining action for bot \(player).\n\(error.localizedDescription)")
                }
            } else {
                break
            }
        }
        isRunningQueue = false
    }
    
    // MARK: - Send
    
    private func send<T: Request>(_ request: T, to users: [User]) {
        Task { @MainActor in
            GameHostShared?.send(request, to: users)
        }
    }
    
    func disconnectUser(_ user: User) throws {
        try players.first(where: { $0.user == user }).get().user = nil
    }
    
    public struct EventGroupResponse: Request {
        public static let name = "eventGroup"
        
        public let id: Int
        public let isLiveAction: Bool
        public let events: [PlayerEvent]
        public let playerStateChanges: [EventGroup.PlayerState]?
        public let hasEnded: Bool?
        
        public init(id: Int, isLiveAction: Bool, events: [PlayerEvent], playerStateChanges: [EventGroup.PlayerState]?, hasEnded: Bool?) {
            self.id = id
            self.isLiveAction = isLiveAction
            self.events = events
            self.playerStateChanges = playerStateChanges
            self.hasEnded = hasEnded
        }
    }
    
    func reconnect(user: User, player: UUID?, lastEventId: Int?) {
        logger?.info("Starting replay to \(user).")
        let eventGroupId = lastEventId.map({ $0 + 1 }) ?? 0
        if hasEnded {
            for eventGroup in eventGroups[eventGroupId...] {
                send(EventGroupResponse(id: eventGroup.id, isLiveAction: eventGroup.isLiveAction, events: eventGroup.events(for: players.ids), playerStateChanges: eventGroup.playerStateChanges, hasEnded: eventGroup.hasEnded), to: [user])
            }
        } else if let player = player.flatMap({ players.first(id: $0) }) {
            player.user = user
            sendEventGroupHistory(eventGroupId: eventGroupId, toPlayers: players.filter({ $0.id == player.id || $0.savedPlayer.host == player.id }))
        } else {
            observers.append(user)
            sendEventGroupHistory(eventGroupId: eventGroupId, toObservers: [user])
        }
        logger?.info("Finished replay of \(eventGroups.count - eventGroupId) event groups.")
    }
    
    private func sendEventGroupHistory(eventGroupId: Int, toPlayers players: [Player]) {
        for eventGroup in eventGroups[eventGroupId...] {
            let playerPartitions = playerPartitions(for: eventGroup, limitedTo: players)
            for players in playerPartitions {
                let users = Set(players.map({ $0.savedPlayer.host.map({ self.players.first(id: $0)! }) ?? $0 })).compactMap({ $0.user })
                send(EventGroupResponse(id: eventGroup.id, isLiveAction: eventGroup.isLiveAction, events: eventGroup.events(for: players.ids), playerStateChanges: eventGroup.playerStateChanges, hasEnded: eventGroup.hasEnded), to: users)
            }
        }
    }
    
    /// Players who are to receive the same data usually belong to the same partition. Players sharing a device also belong to the same partition. Calling `eventGroup.events(for:)` with each partition will include private data relevant to at least one of the players in the partition.
    private func playerPartitions(for eventGroup: EventGroup, limitedTo players: [Player]) -> [[Player]] {
        var partitions = Set(eventGroup.events.flatMap({ Set($0.playerPartitions.map({ Set($0.compactMap({ self.players.first(id: $0) })).intersection(players) }).filter({ !$0.isEmpty })) })).map({ $0.sorted(by: { $0.id.uuidString < $1.id.uuidString }) })
        let partitionPlayers = partitions.flatMap({ $0 })
        // move all players that belong to multiple partitions to a new one
        for player in partitionPlayers {
            if partitions.filter({ $0.contains(player) }).count > 1 {
                partitions = partitions.map({ $0.filter({ $0 != player }) }).filter({ !$0.isEmpty }) + [[player]]
            }
        }
        let remainingPlayers = Set(players).subtracting(partitionPlayers)
        if !remainingPlayers.isEmpty {
            partitions.append(remainingPlayers.sorted(by: { $0.id.uuidString < $1.id.uuidString }))
        }
        // for each device whose clients are not contained in a single partition, the clients are moved to a new partition
        if players.count > 1 {
            let deviceHosts = Set(players.compactMap({ $0.savedPlayer.host }).map({ players.first(id: $0)! }))
            for deviceHost in deviceHosts {
                let hostPartition = partitions.first(where: { $0.contains(deviceHost) })!
                let deviceClients = players.filter({ $0 == deviceHost || $0.savedPlayer.host == deviceHost.id })
                if deviceClients.contains(where: { !hostPartition.contains($0) }) {
                    for i in (0..<partitions.count).reversed() {
                        for deviceClient in deviceClients {
                            if let index = partitions[i].firstIndex(of: deviceClient) {
                                partitions[i].remove(at: index)
                            }
                        }
                        if partitions[i].isEmpty {
                            partitions.remove(at: i)
                        }
                    }
                    partitions.append(deviceClients)
                }
            }
        }
        return partitions.sorted(by: { $0[0].id.uuidString < $1[0].id.uuidString })
    }
    
    private func sendEventGroupHistory(eventGroupId: Int, toObservers observers: [User]) {
        if observers.isEmpty {
            return
        }
        for eventGroup in eventGroups[eventGroupId...] {
            let events = eventGroup.events(for: [])
            send(EventGroupResponse(id: eventGroup.id, isLiveAction: eventGroup.isLiveAction, events: events, playerStateChanges: eventGroup.playerStateChanges, hasEnded: eventGroup.hasEnded), to: observers)
        }
    }
    
}

extension GameState {
    
    public static func from(_ string: String?) throws -> [Self] {
        return try string.map({ try JSONDecoder().decode([Self].self, from: Data($0.utf8)) }) ?? []
    }
    
    public static func encode(_ state: [Self]) -> String? {
        return state.isEmpty ? nil : String(decoding: try! JSONEncoder().encode(state), as: UTF8.self)
    }
    
}

extension GameStrategy {
    
    public static func from(_ string: String) throws -> Self {
        if let strategy = Self(rawValue: string) {
            return strategy
        } else {
            throw HostError(message: "Invalid strategy '\(string)'.")
        }
    }
    
}

extension GameBot {
    
    func action(for player: UUID, strategy: String) throws -> (any GameAction)? {
        return try action(for: player, strategy: Strategy(rawValue: strategy)!)
    }
    
}
