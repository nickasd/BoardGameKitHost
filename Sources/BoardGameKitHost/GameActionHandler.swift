import Foundation

public class GameActionHandler<State: GameState, Player: GamePlayer, PlayerState: GameState> {
    
    private var handles = [String: (GameActionContext) throws -> Void]()
    private var playerStateChanges = [Player: [PlayerState]]()
    @Recorded private var gameState: [State]
    private var playerStates = RecordedDictionary<Player, [PlayerState]>()
    
    public init(_ state: State...) {
        gameState = state
    }
    
    /// Registers an ambient action. If the game receives an ambient action when the intersection between its `state` property and the provided `state` argument is empty, `handle(context:)` throws an error.
    public func register<T: GameAction>(_ handle: @escaping (_ data: T, _ context: GameActionContext) throws -> Void, state: State...) {
        register(handle, state: state)
    }
    
    private func register<T: GameAction>(_ handle: @escaping (_ data: T, _ context: GameActionContext) throws -> Void, state: [State]) {
        let state = Set(state)
        register { [weak self] data, context in
            guard context.action.player == nil else {
                throw HostError(message: "Player cannot be passed to ambient action \(T.name).")
            }
            if let gameState = self?.gameState, state.intersection(gameState).isEmpty {
                throw HostError(message: "Invalid ambient action \(T.name) (current state is \(gameState), allowed states are \(state)).")
            }
            try handle(data, context)
        }
    }
    
    /// Registers an ambient action that has associated replay data. The provided replay data is `nil` during a live game, and it must be set afterwards regardless whether it was `nil` or not. If the game receives an ambient action when the intersection between its `state` property and the provided `state` argument is empty, `handle(context:)` throws an error.
    public func register<T: ReplayableGameAction>(_ handle: @escaping (_ data: T, _ replay: inout T.ReplayData?, _ context: GameActionContext) throws -> Void, state: State...) {
        register({ data, context in
            var replay: T.ReplayData?
            if let replayData = context.action.replayData {
                replay = try RequestCoder.decode(T.ReplayData.self, from: Data(replayData.utf8))
            } else if context.isReplay {
                throw HostError(message: "Action \(T.name) expected replay data but none was found.")
            }
            try handle(data, &replay, context)
            if replay == nil {
                preconditionFailure("Action \(T.name) didn't set the replay data.")
            }
            context.replayData = replay
        }, state: state)
    }
    
    /// Registers a player action. If the player sends an action when the intersection between their `state` property and the provided `state` argument is empty, `handle(context:)` throws an error.
    public func register<T: GameAction>(_ handle: @escaping (_ player: Player, _ data: T, _ context: GameActionContext) throws -> Void, state: PlayerState...) {
        register(handle, state: state)
    }
    
    private func register<T: GameAction>(_ handle: @escaping (_ player: Player, _ data: T, _ context: GameActionContext) throws -> Void, state: [PlayerState]) {
        let state = Set(state)
        register { [weak self] data, context in
            guard let player = context.action.player else {
                throw HostError(message: "Player must be passed to action \(T.name).")
            }
            guard let (player, playerState) = self?.playerStates.first(where: { $0.key.id == context.action.player }) else {
                throw HostError(message: "Invalid action \(T.name) for player \(player) (current state is [], allowed states are \(state)).")
            }
            if state.intersection(playerState).isEmpty {
                throw HostError(message: "Invalid action \(T.name) for player \(player.id) (current state is \(playerState), allowed states are \(state)).")
            }
            try handle(player, data, context)
        }
    }
    
    /// Registers a player action that has associated replay data. The provided replay data is `nil` during a live game, and it must be set afterwards regardless whether it was `nil` or not. If the player sends an action when the intersection between their `state` property and the provided `state` argument is empty, `handle(context:)` throws an error.
    public func register<T: ReplayableGameAction>(_ handle: @escaping (_ player: Player, _ data: T, _ replay: inout T.ReplayData?, _ context: GameActionContext) throws -> Void, state: PlayerState...) {
        register({ player, data, context in
            var replay: T.ReplayData?
            if let replayData = context.action.replayData {
                replay = try RequestCoder.decode(T.ReplayData.self, from: Data(replayData.utf8))
            } else if context.isReplay {
                throw HostError(message: "Action \(T.name) expected replay data but none was found.")
            }
            try handle(player, data, &replay, context)
            if replay == nil {
                preconditionFailure("Action \(T.name) didn't set the replay data.")
            }
            context.replayData = replay
        }, state: state)
    }
    
    private func register<T: GameAction>(_ handle: @escaping (_ data: T, _ context: GameActionContext) throws -> Void) {
        if handles.updateValue({ context in
            let data = try RequestCoder.decode(T.self, from: Data(context.action.data.utf8))
            try handle(data, context)
        }, forKey: T.name) != nil {
            preconditionFailure("Action \(T.name) is already registered.")
        }
    }
    
    public func handle(context: GameActionContext) throws {
        guard let handle = handles[context.action.name] else {
            throw HostError(message: "Action \(context.action.name) is not registered.")
        }
        playerStateChanges.removeAll()
        try handle(context)
        context.playerStateChanges = Dictionary(uniqueKeysWithValues: playerStateChanges.map({ ($0.key.id, PlayerState.encode($0.value)) }))
        context.hasEnded = hasEnded
    }
    
    /// Handling an action that is not registered with the player's state throws an error.
    public func setState(_ state: PlayerState..., for player: Player) {
        playerStates[player] = state
        playerStateChanges[player] = state
    }
    
    /// Resets the player's state. Handling any action from that player throws an error.
    public func setWaiting(_ player: Player) {
        setState(for: player)
    }
    
    /// Handling an action that is not registered with the game's state throws an error.
    public func setGameState(_ state: State...) {
        self.gameState = state
    }
    
    /// Resets the game's state. Handling any ambient action throws an error.
    public func setGameWaiting() {
        gameState.removeAll()
    }
    
    public func state(for player: Player) -> [PlayerState] {
        return playerStates[player] ?? []
    }
    
    public func state(for player: UUID) throws -> (Player, [PlayerState]) {
        return try playerStates.first(where: { $0.key.id == player }).get()
    }
    
    /// This property returns `true` when `state == []`.
    public func isWaiting(_ player: Player) -> Bool {
        return state(for: player).isEmpty
    }
    
    public var allPlayersAreWaiting: Bool {
        return playerStates.allSatisfy({ $0.value.isEmpty })
    }
    
    /// The game ends when the game and all players have an empty state (they are all waiting).
    public var hasEnded: Bool {
        return gameState.isEmpty && allPlayersAreWaiting
    }
    
}

public protocol GameState: Hashable, Codable, CustomStringConvertible {
}

extension GameState where Self: RawRepresentable {
    
    public var description: String {
        return "\(rawValue)"
    }
    
}

/// A protocol implemented by game actions that get and set replay data to the game request context.
public protocol ReplayableGameAction: GameAction {
    associatedtype ReplayData: Codable
}
