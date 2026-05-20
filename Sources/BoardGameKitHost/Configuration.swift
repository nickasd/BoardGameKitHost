import Foundation

public struct HostConfiguration {
    nonisolated(unsafe) public static var shared: HostConfiguration!
    
    public let minimumSupportedAppVersion: String
    public let gameCharacters: (any GameCharacter.Type)?
    public let game: any Game.Type
    
    public init(minimumSupportedAppVersion: String = "0", gameCharacters: (any GameCharacter.Type)? = nil, game: any Game.Type) {
        self.minimumSupportedAppVersion = minimumSupportedAppVersion
        self.gameCharacters = gameCharacters
        self.game = game
    }
    
    public var gameOptions: any GameOptions.Type {
        func options<MyGame: Game>(_: MyGame.Type) -> MyGame.Options.Type {
            MyGame.Options.self
        }
        return options(game)
    }
    
    public var gameStrategy: (any GameStrategy.Type)? {
        func strategy<MyGame: GameBot>(_: MyGame.Type) -> MyGame.Strategy.Type {
            MyGame.Strategy.self
        }
        return if let gameType = game as? (any GameBot.Type) {
            strategy(gameType)
        } else {
            nil
        }
    }
    
    public var botStrategies: [any GameStrategy] {
        func strategy<MyGame: GameBot>(_: MyGame.Type) -> MyGame.Strategy.Type {
            MyGame.Strategy.self
        }
        return if let gameType = game as? (any GameBot.Type) {
            strategy(gameType).allCases as! [any GameStrategy]
        } else {
            []
        }
    }
}

public protocol GameCharacter: RawRepresentable, CaseIterable where RawValue == String {
    var name: String { get }
    var icon: String? { get }
}

extension GameCharacter {
    
    public var name: String {
        return rawValue
    }
    
    public var icon: String? {
        return "\(rawValue).heic"
    }
    
}

extension Bundle {
    
    public var version: Int {
        return Int(object(forInfoDictionaryKey: kCFBundleVersionKey as String) as! String)!
    }
    
    public var name: String {
        return object(forInfoDictionaryKey: kCFBundleNameKey as String) as! String
    }
    
}
