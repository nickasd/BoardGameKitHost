/**
 A property wrapper that adds support for undo operations. When modifying it, a `GameContext` must be active.

 To use as little memory as possible, the `@Recorded` attribute should be only used for small data. Adding the attribute to value types such as `Array` and `Dictionary` will always record the whole content instead of only the changed elements. For more efficient undo recording, use `RecordedArray` or `RecordedDictionary` if possible.
 */
@propertyWrapper public class Recorded<Value> {
    
    public var projectedValue: Recorded {
        self
    }
    
    /// Setting this property rather than `wrappedValue` allows to break any retain cycles without recording an additional undo event.
    public var _wrappedValue: Value
    /// Records an undo event on the `UndoManager` of the current `GameContext`.
    public var wrappedValue: Value {
        get {
            _wrappedValue
        }
        set {
            let oldValue = _wrappedValue
            _wrappedValue = newValue
            GameContext.current.undoManager?.addEvent(UndoManager.Event(id: "Recorded<\(Value.self)>", block: { [self] in
                wrappedValue = oldValue
            }))
        }
    }
    
    public init(wrappedValue: Value) {
        self._wrappedValue = wrappedValue
    }
    
}

/// An array with support for undo operations. When modifying it, a `GameContext` must be active.
public final class RecordedArray<Element>: RandomAccessCollection, RangeReplaceableCollection, MutableCollection, ExpressibleByArrayLiteral {

    public typealias Index = Array<Element>.Index
    
    /// Only access the setter if you need to break retain cycles at the end of a game, otherwise undo operations are not recorded.
    public var elements: [Element]

    public init() {
        self.elements = []
    }
    
    public init<S>(_ elements: S) where S: Sequence, Element == S.Element {
        self.elements = Array(elements)
    }
    
    public init(arrayLiteral elements: Element...) {
        self.elements = Array(elements)
    }

    public var startIndex: Index {
        return elements.startIndex
    }
    
    public var endIndex: Index {
        return elements.endIndex
    }
    
    public func index(before i: Index) -> Index {
        return elements.index(before: i)
    }
    
    public func index(after i: Index) -> Index {
        return elements.index(after: i)
    }
    
    public subscript(position: Index) -> Element {
        get {
            return elements[position]
        }
        set {
            let oldValue = elements[position]
            elements[position] = newValue
            
            GameContext.current.undoManager?.addEvent(UndoManager.Event(id: "RecordedArray<\(Element.self)>.subscript", block: { [self] in
                self[position] = oldValue
            }))
        }
    }
    
    public func replaceSubrange<C>(_ subrange: Range<Array<Element>.Index>, with newElements: C) where C: Collection, Element == C.Element {
        let oldElements = Array(elements[subrange])
        elements.replaceSubrange(subrange, with: newElements)
        let subrange = subrange.lowerBound..<(subrange.lowerBound + newElements.count)
        
        GameContext.current.undoManager?.addEvent(UndoManager.Event(id: "RecordedArray<\(Element.self)>.replaceSubrange", block: { [self] in
            replaceSubrange(subrange, with: oldElements)
        }))
    }
    
    public func filter(_ isIncluded: (Element) throws -> Bool) rethrows -> [Element] {
        return try elements.filter(isIncluded)
    }

}

/// A dictionary with support for undo operations. When modifying it, a `GameContext` must be active.
public class RecordedDictionary<Key: Hashable, Value>: Collection {
    
    public typealias Index = Dictionary<Key, Value>.Index
    
    /// Only access the setter if you need to break retain cycles at the end of a game, otherwise undo operations are not recorded.
    public var elements: Dictionary<Key, Value>
    
    public init(_ elements: Dictionary<Key, Value> = [:]) {
        self.elements = elements
    }
    
    public init<S>(uniqueKeysWithValues keysAndValues: S) where S: Sequence, S.Element == (Key, Value) {
        self.elements = Dictionary(uniqueKeysWithValues: keysAndValues)
    }
    
    public subscript(key: Key) -> Value? {
        get {
            return elements[key]
        }
        set {
            let oldValue = elements[key]
            elements[key] = newValue

            GameContext.current.undoManager?.addEvent(UndoManager.Event(id: "RecordedDictionary<\(Element.self)>.subscript", block: { [self] in
                self[key] = oldValue
            }))
        }
    }
    
    public subscript(position: Index) -> Dictionary<Key, Value>.Element {
        return elements[position]
    }
    
    public var startIndex: Index {
        return elements.startIndex
    }
    
    public var endIndex: Index {
        return elements.endIndex
    }
    
    public func index(after i: Index) -> Index {
        return elements.index(after: i)
    }
    
    public var keys: Dictionary<Key, Value>.Keys {
        return elements.keys
    }
    
    public var values: Dictionary<Key, Value>.Values {
        return elements.values
    }
    
    public func mapValues<T>(_ transform: (Value) throws -> T) rethrows -> Dictionary<Key, T> {
        return try elements.mapValues(transform)
    }
    
    public func updateValue(_ value: Value, forKey key: Key) -> Value? {
        let value = elements.updateValue(value, forKey: key)
        
        GameContext.current.undoManager?.addEvent(UndoManager.Event(id: "RecordedDictionary<\(Element.self)>.updateValue", block: { [self] in
            if let value = value {
                let _ = updateValue(value, forKey: key)
            } else {
                let _ = removeValue(forKey: key)
            }
        }))
        return value
    }
    
    public func removeValue(forKey key: Key) -> Value? {
        let value = elements.removeValue(forKey: key)
        
        GameContext.current.undoManager?.addEvent(UndoManager.Event(id: "RecordedDictionary<\(Element.self)>.removeValue", block: { [self] in
            self[key] = value
        }))
        return value
    }
    
    public func removeAll() {
        for key in keys {
            let _ = removeValue(forKey: key)
        }
    }
    
    public func removeAndReturnAll() -> Dictionary<Key, Value>.Values {
        let elements = self.elements
        for key in keys {
            let _ = removeValue(forKey: key)
        }
        return elements.values
    }

}
