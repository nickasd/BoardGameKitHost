import Foundation

/// The game request context allows to pass data in and out of the game while an action is handled.
public class GameActionContext {
    
    public struct Event {
        public let player: UUID?
        public let request: any Request
        public let playerPartitions: [[UUID]]
        public let privateData: ((_ players: [UUID]) -> any Codable)?
        
        /// Returns the event with the private data involving at least one of the given `players`, or `nil` if the event was only sent to a specific player who is not included in `players`..
        public func apply(for players: [UUID]) -> PlayerEvent? {
            return if let player = player {
                if players.contains(player) {
                    PlayerEvent(name: type(of: request).name, data: RequestCoder.encode(request), privateData: nil)
                } else {
                    nil
                }
            } else {
                PlayerEvent(name: type(of: request).name, data: RequestCoder.encode(request), privateData: privateData.map({ RequestCoder.encode($0(players)) }))
            }
        }
    }
    
    public struct QueueElement {
        public let player: UUID?
        public let action: any GameAction
        
        public init(player: UUID?, action: any GameAction) {
            self.player = player
            self.action = action
        }
    }
    
    public struct PrivatePlayerData<Data: Codable & Sendable> {
        let data: [PrivateDataElement<Data>]
        
        public init<Player: GamePlayer>(_ mapper: (_ player: Player) -> Data, for players: [Player]) {
            self.data = players.map({ PrivateDataElement(data: mapper($0), players: [$0.id]) })
        }
        
        public init<Player: GamePlayer>(_ data: Data, for player: Player) {
            self.data = [PrivateDataElement(data: data, players: [player.id])]
        }
        
        public init<Player: GamePlayer>(_ data: Data, for players: [Player]) {
            self.data = [PrivateDataElement(data: data, players: players.map({ $0.id }))]
        }
        
        public init<Player: GamePlayer>(_ data: [Player: Data]) {
            self.data = data.map({ PrivateDataElement(data: $0.value, players: [$0.key.id]) })
        }
    }
    
    public let action: SavedAction
    public let isReplay: Bool
    public var replayData: (any Codable)?
    public var playerStateChanges = [UUID: String?]()
    public var hasEnded = false
    public private(set) var generatedEvents = [Event]()
    public private(set) var queue = [QueueElement]()
    
    public init(action: SavedAction, isReplay: Bool) {
        self.action = action
        self.isReplay = isReplay
    }
    
    public func generatedEvents(for players: [UUID]) -> [PlayerEvent] {
        return generatedEvents.compactMap({ $0.apply(for: players) })
    }
    
    // MARK: - Send
    
    public func send<T: GameEvent>(_ data: T, to player: UUID) {
        generatedEvents.append(Event(player: player, request: data, playerPartitions: [[player]], privateData: nil))
    }
    
    public func send<T: GameEvent, U: GamePlayer>(_ data: T, to player: U) {
        send(data, to: player.id)
    }
    
    public func sendToAllPlayers<T: GameEvent>(_ data: T) {
        generatedEvents.append(Event(player: nil, request: data, playerPartitions: [], privateData: nil))
    }
    
    public func sendToAllPlayers<T: PrivateGameEvent>(_ data: T, privateData: PrivatePlayerData<T.PrivateData>) {
        generatedEvents.append(Event(player: nil, request: data, playerPartitions: privateData.data.map({ $0.players }), privateData: { players in privateData.data.filter({ $0.players.contains(where: { players.contains($0) }) }) }))
    }
    
    /// Queues the given ambient action to be run after the current request has completed.
    public func queue<T: GameAction>(action: T) {
        queue.append(QueueElement(player: nil, action: action))
    }
    
    /// Queues the given player action to be run after the current request has completed.
    public func queue<T: GameAction>(player: UUID, action: T) {
        queue.append(QueueElement(player: player, action: action))
    }
    
    /// Queues the given player action to be run after the current request has completed.
    public func queue<T: GameAction, U: GamePlayer>(player: U, action: T) {
        queue(player: player.id, action: action)
    }
    
}

public struct PlayerEvent: Codable, Sendable {
    public let name: String
    public let data: String
    public let privateData: String?
    
    public init(name: String, data: Data, privateData: Data?) {
        self.name = name
        self.data = String(decoding: data, as: UTF8.self)
        self.privateData = privateData.map({ String(decoding: $0, as: UTF8.self) })
    }
}

/// A request type that represents a game event, generated in response to a game action.
public protocol GameEvent: Request {
}

/// A request type that represents a game event that can potentially fail, generated in response to a game action.
public protocol FailableGameEvent: GameEvent {
    associatedtype Failure: GameEventFailure
}

public typealias GameEventFailure = Error & Codable

/// A protocol implemented by events generated in response to a game action that have associated private data for one or more players.
public protocol PrivateGameEvent: GameEvent {
    associatedtype PrivateData: Codable
    typealias PrivateDataList = [PrivateDataElement<PrivateData>]
}

public struct PrivateDataElement<PrivateData: Codable & Sendable>: Codable & Sendable {
    public let data: PrivateData
    public let players: [UUID]
}

extension Array {
    
    public func get<T>(for player: UUID) -> T? where Element == PrivateDataElement<T> {
        return first(where: { $0.players.contains(player) })?.data
    }
    
}
