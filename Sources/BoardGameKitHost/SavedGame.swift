import Foundation

public class SavedGame: Codable {
    
    public static let fileExtension = "json"
    
    public static func nameFormatStyle() -> Date.ISO8601FormatStyle {
        var format = Date.ISO8601FormatStyle().year().month().day().time(includingFractionalSeconds: false).dateTimeSeparator(.space).timeZone(separator: .omitted)
        format.timeZone = .current
        return format
    }
    
    public let game: String
    public let version: Int
    public let creationDate: Date
    public let players: [SavedPlayer]
    public let options: String
    public var actions: [SavedAction]
    
    public init(game: String, version: Int, creationDate: Date, players: [SavedPlayer], options: String, actions: [SavedAction] = []) {
        self.game = game
        self.version = version
        self.creationDate = creationDate
        self.players = players
        self.options = options
        self.actions = actions
    }
    
    public convenience init<T: GameOptions>(game: String = Bundle.main.name, version: Int = Bundle.main.version, creationDate: Date = Date(), players: [SavedPlayer], options: T, actions: [SavedAction] = []) {
        let options = String(decoding: RequestCoder.encode(options), as: UTF8.self)
        self.init(game: game, version: version, creationDate: creationDate, players: players, options: options)
    }
    
}

public struct SavedPlayer: Codable, Identifiable, Sendable {
    public enum PlayerType: Codable, Sendable {
        case real(userName: String)
        case bot(strategy: String)
        case deviceClient(host: UUID)
    }
    
    public let id: UUID
    public let name: String?
    public let type: PlayerType
    
    public init(id: UUID, name: String?, type: PlayerType) {
        self.id = id
        self.name = name
        self.type = type
    }
    
    public var botStrategy: String? {
        return switch type {
        case .bot(let strategy):
            strategy
        default:
            nil
        }
    }
    
    public var host: UUID? {
        return switch type {
        case .deviceClient(let host):
            host
        default:
            nil
        }
    }
}

public struct SavedAction: Codable {
    public let id: Int
    public let date: Date
    /// If `player == nil`, this action represents a so-called *ambient action*. The first action accepted by a game is always an ambient action, and a game might accept other ambient actions generated in response to a player action, e.g. when a round terminates and a new round begins. In this case, an ambient action can be generated to start the new round and produce a game save file that's easier to read and debug, particularly if the new round involves randomness, such as dealing a random card to each player. Without an ambient action to start the new round, the replay data would be stored in the player action, even if they are not directly related.
    public let player: UUID?
    public let name: String
    public let data: String
    public let replayData: String?
    
    public init(id: Int, date: Date, player: UUID?, name: String, data: String, replayData: String?) {
        self.id = id
        self.date = date
        self.player = player
        self.name = name
        self.data = data
        self.replayData = replayData
    }
    
    public init<T: GameAction>(id: Int, date: Date, player: UUID?, action: T) {
        self.init(id: id, date: date, player: player, name: T.name, data: String(decoding: RequestCoder.encode(action), as: UTF8.self), replayData: nil)
    }
    
    public init<T: ReplayableGameAction>(id: Int, date: Date, player: UUID?, action: T, replayData: T.ReplayData) {
        self.init(id: id, date: date, player: player, name: T.name, data: String(decoding: RequestCoder.encode(action), as: UTF8.self), replayData: String(decoding: RequestCoder.encode(replayData), as: UTF8.self))
    }
}
