import Foundation

/// A game context holds a reference to the undo manager that is shared between the game and the related classes. While a game action is being handled, you can get a reference to the game context via `GameContext.current`.
public class GameContext {
    
    private enum Keys {
        static let gameContext = "gameContext"
    }
    
    public static var current: GameContext {
        guard let current = Thread.current.threadDictionary[Keys.gameContext] as? GameContext else {
            preconditionFailure("There is no current GameContext set.")
        }
        return current
    }
    
    public let undoManager: UndoManager?
    
    public init(undoManager: UndoManager?) {
        self.undoManager = undoManager
    }
    
    public func makeCurrent<T>(_ block: () throws -> T) rethrows -> T {
        if Thread.current.threadDictionary[Keys.gameContext] as? GameContext != nil {
            preconditionFailure("A current GameContext is already set.")
        }
        Thread.current.threadDictionary[Keys.gameContext] = self
        defer {
            Thread.current.threadDictionary[Keys.gameContext] = nil
        }
        return try block()
    }
    
}
