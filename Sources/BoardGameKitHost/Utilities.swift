import Foundation

extension CustomStringConvertible where Self: Identifiable {
    
    public var description: String {
        return "\(id)"
    }
    
}

extension Sequence where Element: Identifiable {
    
    public var ids: [Element.ID] {
        return map({ $0.id })
    }
    
    public func first(id: Element.ID) -> Element? {
        return first(where: { $0.id == id })
    }
    
}

extension Collection where Element: Identifiable {
    
    public func contains(id: Element.ID) -> Bool {
        return contains(where: { $0.id == id })
    }
    
    public func firstIndex(id: Element.ID) -> Index? {
        return firstIndex(where: { $0.id == id })
    }
    
    /// Returns the element with the given `id` or throws an error if it doesn't exist.
    public func get(id: Element.ID) throws -> (element: Element, index: Index) {
        guard let index = firstIndex(id: id) else {
            throw HostError(message: "Element with id '\(id)' doesn't exist.")
        }
        return (element: self[index], index)
    }

    /// Returns the elements with the given `ids` or throws an error if any of them doesn't exist.
    public func getAll(ids: [Element.ID]) throws -> (elements: [Element], indices: IndexSet) where Index == Int {
        let elements = try ids.map({ try get(id: $0) })
        let indices = IndexSet(elements.map({ $0.index }))
        return (elements.map({ $0.element }), indices)
    }
    
}

extension Collection {
    
    /// Returns the element at the given `index` if it exists, otherwise throws an error.
    public func get(at index: Index) throws -> Element {
        if !indices.contains(index) {
            throw HostError(message: "Index out of bounds.")
        }
        return self[index]
    }
    
}

extension Dictionary {
    
    /// Returns the value for the given `key` if it exists, otherwise throws an error.
    public func get(for key: Key) throws -> Value {
        guard let value = self[key] else {
            throw HostError(message: "The element doesn't exist.")
        }
        return value
    }
    
}

extension Optional {
    
    /// Returns the wrapped value if it is not nil, otherwise throws an error.
    public func get() throws -> Wrapped {
        guard let value = self else {
            throw HostError(message: "The element doesn't exist.")
        }
        return value
    }
    
}

extension Collection {
    
    /// Returns the collection wrapped around so that `first` is at the beginning: any elements before it are appended to the end.
    public func wrapped(first: Element) -> [Element] where Element: Equatable {
        guard let index = firstIndex(of: first) else {
            preconditionFailure("The element doesn't exist.")
        }
        return Array(self[index...]) + Array(self[..<index])
    }
    
    /// Returns the collection wrapped around so that `last` is at the end: any elements after it are inserted at the beginning.
    public func wrapped(last: Element) -> [Element] where Element: Equatable {
        guard let index = firstIndex(of: last) else {
            preconditionFailure("The element doesn't exist.")
        }
        return Array(self[self.index(after: index)...]) + Array(self[...index])
    }
    
    /// Returns the element after the given `element`, or `nil` if it is the last one.
    public func element(after element: Element) -> Element? where Element: Equatable {
        guard var index = firstIndex(of: element) else {
            preconditionFailure("The element doesn't exist.")
        }
        formIndex(after: &index)
        return index != endIndex ? self[index] : nil
    }
    
    /// Returns the first element at the given `offset` after `element`, wrapping around the collection if necessary. `offset` must be greater than 0.
    public func wrappedElement(at offset: Int = 1, after element: Element) -> Element where Element: Equatable {
        guard var index = firstIndex(of: element) else {
            preconditionFailure("The element doesn't exist.")
        }
        guard offset > 0 else {
            preconditionFailure("precondition failure: offset > 0")
        }
        for _ in 0..<offset {
            formIndex(after: &index)
            if index == endIndex {
                index = startIndex
            }
        }
        return self[index]
    }
    
    public func permutations() -> [[Element]] where Index == Int {
        return count == 0 ? [] : (1...count).flatMap({ permutations(count: $0) })
    }

    public func permutations(count: Int) -> [[Element]] where Index == Int {
        guard count <= self.count else {
            preconditionFailure("precondition failed: count >= self.count")
        }
        return switch count {
        case 0:
            []
        case 1:
            enumerated().map({ [$0.element] })
        default:
            (startIndex..<endIndex - (count - 1)).flatMap({ i in self[(i + 1)...].permutations(count: count - 1).map({ [self[i]] + $0 }) })
        }
    }
    
    public func uniquePermutations() -> [[Element]] where Element: Equatable, Index == Int {
        return count == 0 ? [] : (1...count).flatMap({ uniquePermutations(count: $0) })
    }

    public func uniquePermutations(count: Int) -> [[Element]] where Element: Equatable, Index == Int {
        guard count <= self.count else {
            preconditionFailure("precondition failed: count >= self.count")
        }
        return switch count {
        case 0:
            []
        case 1:
            enumerated().filter({ !self[..<(startIndex + $0.offset)].contains($0.element) }).map({ [$0.element] })
        default:
            (startIndex..<endIndex - (count - 1)).filter({ i in i == startIndex || self[i] != self[startIndex] }).flatMap({ i in self[(i + 1)...].uniquePermutations(count: count - 1).map({ [self[i]] + $0 }) })
        }
    }
    
}

extension BidirectionalCollection {
    
    /// Returns the first element at the given `offset` before `element`, wrapping around the collection if necessary. `offset` must be greater than 0.
    public func wrappedElement(at offset: Int = 1, before element: Element) -> Element where Element: Equatable {
        guard var index = firstIndex(of: element) else {
            preconditionFailure("The element doesn't exist.")
        }
        guard offset > 0 else {
            preconditionFailure("precondition failure: offset > 0")
        }
        for _ in 0..<offset {
            if index == startIndex {
                index = endIndex
            }
            formIndex(before: &index)
        }
        return self[index]
    }
    
    /// Returns the element at offset `i` starting from `element`, wrapping around the collection if necessary. A positive offset is equivalent to calling `wrappedElement(at:after:)`; a negative offset is equivalent to calling `wrappedElement(at:before:)` with the offset's absolute value.
    public func wrappedElement(at offset: Int = 1, startingFrom element: Element) -> Element where Element: Equatable {
        return if offset > 0 {
            wrappedElement(at: offset, after: element)
        } else if offset < 0 {
            wrappedElement(at: -offset, before: element)
        } else {
            element
        }
    }
    
}

extension RangeReplaceableCollection where Self: MutableCollection, Index == Int {
    
    public mutating func insert<S>(contentsOf elements: S, atOffsets offsets: IndexSet) where S: Sequence, S.Element == Element {
        for (element, index) in zip(elements, offsets) {
            insert(element, at: index)
        }
    }
    
    public mutating func removeAndReturn(atOffsets offsets: IndexSet) -> [Element] {
//        let elements = offsets.map({ self[$0] })
//        let _: Void = remove(atOffsets: offsets)
        var elements = [Element]()
        for offset in offsets.reversed() {
            elements.append(remove(at: offset))
        }
        elements.reverse()
        return elements
    }
    
    public mutating func removeAndReturnFirst() -> Element {
        return remove(at: 0)
    }
    
    public mutating func removeAndReturnFirst(_ k: Int) -> [Element] {
        return removeAndReturn(atOffsets: IndexSet(0..<k))
    }
    
    public mutating func removeAndReturnLast() -> Element {
        return remove(at: endIndex - 1)
    }
    
    public mutating func removeAndReturnLast(_ k: Int) -> [Element] {
        return removeAndReturn(atOffsets: IndexSet(endIndex - k..<endIndex))
    }
    
    public mutating func removeAndReturnAll() -> [Element] {
        return removeAndReturn(atOffsets: IndexSet(0..<endIndex))
    }
    
}

extension Sequence {
    
    /// Returns a mapping between each unique element in the sequence to its number of occurrences.
    public func countOccurrences() -> [Element: Int] where Element: Hashable {
        return reduce(into: [:], { $0[$1, default: 0] += 1 })
    }
    
}

extension Collection where Element: AdditiveArithmetic {
    
    public func sum() -> Element {
        return reduce(.zero, +)
    }
    
}
