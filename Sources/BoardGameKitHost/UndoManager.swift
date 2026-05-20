public class UndoManager {
    
    public class Event {
        
        public typealias Block = () -> Void
        
        let id: String
        let block: Block
        
        /// `block` is expected to call `UndoManager.addEvent(_:)` with a redo block that performs the reverse operation, which will be pushed onto the redo stack. Similarly, the redo block should call `UndoManager.addEvent(_:)` with an undo block that will be pushed onto the undo stack.
        public init(id: String, block: @escaping Block) {
            self.id = id
            self.block = block
        }
        
    }
    
    private struct EventGroup {
        var events = [Event]()
    }
    
    /// The current undo/redo group, or the event group that will be started when calling `beginUndoGrouping()`.
    public private(set) var currentEventGroup = 0
    /// When the `groupingLevel > 0`, undo manager events can be added. To increase the grouping level, call `beginUndoGrouping()`; to decrease it, call `endUndoGrouping()`.
    public private(set) var groupingLevel = 0
    
    private var eventGroups = [EventGroup]()
    private var undoOperation: (event: Int, eventWasReplaced: Bool)?
    
    public init() {
    }
    
    // MARK: - Events
    
    public func addEvent(_ event: Event) {
        if groupingLevel == 0 {
            preconditionFailure("precondition failure: groupingLevel > 0")
        }
        if let undoOperation = undoOperation {
            if undoOperation.eventWasReplaced {
                preconditionFailure("Undo manager event \(undoOperation.event) \(eventGroups[currentEventGroup].events[undoOperation.event].id) may only be replaced once during undo/redo.")
            }
            eventGroups[currentEventGroup].events[undoOperation.event] = event
            self.undoOperation!.eventWasReplaced = true
        } else {
            eventGroups[currentEventGroup].events.append(event)
        }
    }
    
    // MARK: - Undo
    
    public func removeAllRedoActions() {
        eventGroups.removeLast(eventGroups.count - currentEventGroup)
    }
    
    /// Begins a new undo group and increases `groupingLevel` by 1.
    public func beginUndoGrouping() {
        if groupingLevel > 0 {
            preconditionFailure("precondition failure: groupingLevel == 0")
        }
        removeAllRedoActions()
        groupingLevel += 1
        eventGroups.append(EventGroup(events: []))
    }
    
    /// End the current undo group by decreasing the `groupingLevel` by 1.
    public func endUndoGrouping() {
        if groupingLevel == 0 {
            preconditionFailure("precondition failure: groupingLevel > 0")
        }
        groupingLevel -= 1
        currentEventGroup += 1
    }
    
    public func removeAllActions() {
        groupingLevel = 0
        currentEventGroup = 0
        eventGroups.removeAll()
    }
    
    public var canUndo: Bool {
        return currentEventGroup > 0 || groupingLevel > 0
    }
    
    public func undo() {
        if !canUndo {
            preconditionFailure("precondition failure: canUndo")
        }
        if groupingLevel > 0 {
            endUndoGrouping()
        }
        currentEventGroup -= 1
        groupingLevel += 1
        for (i, event) in eventGroups[currentEventGroup].events.enumerated().reversed() {
            undoOperation = (event: i, eventWasReplaced: false)
            event.block()
            if !undoOperation!.eventWasReplaced {
                preconditionFailure("Undo manager event \(i) \(event.id) must be replaced during the undo operation.")
            }
        }
        undoOperation = nil
        groupingLevel -= 1
    }
    
    public var canRedo: Bool {
        return currentEventGroup < eventGroups.count && groupingLevel == 0
    }
    
    public func redo() {
        if !canRedo {
            preconditionFailure("precondition failure: canRedo")
        }
        groupingLevel += 1
        for (i, event) in eventGroups[currentEventGroup].events.enumerated() {
            undoOperation = (event: i, eventWasReplaced: false)
            event.block()
            if !undoOperation!.eventWasReplaced {
                preconditionFailure("Undo manager event \(i) \(event.id) must be replaced during the redo operation.")
            }
        }
        undoOperation = nil
        groupingLevel -= 1
        currentEventGroup += 1
    }
    
    public func canUndo(to eventGroup: Int) -> Bool {
        return (0...eventGroups.count).contains(eventGroup)
    }
    
    /// Calls `undo()` or `redo()` until the given `eventGroup` is reached.
    public func undo(to eventGroup: Int) {
        if !canUndo(to: eventGroup) {
            preconditionFailure("precondition failure: 0 <= eventGroup <= eventGroups.count")
        }
        if eventGroup < currentEventGroup {
            while eventGroup < currentEventGroup {
                undo()
            }
        } else if eventGroup > currentEventGroup {
            while eventGroup > currentEventGroup {
                redo()
            }
        }
    }
    
}
