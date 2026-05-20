extension Collection {
    
    /// Returns the element with the given `id` if it's not `nil`, otherwise returns a random element. If `id` doesn't appear in the collection, throws an exception.
    public func sampleOne(id: Element.ID?) throws -> Element where Element: Identifiable {
        return try sample(count: 1, ids: id.map({ [$0] }))[0]
    }
    
    /// Returns the given `replay` element if it's not `nil`, otherwise returns a random element. If `replay` doesn't appear in the collection, throws an exception.
    public func sampleOne(replay: Element?) throws -> Element where Element: Equatable {
        return try sample(count: 1, replay: replay.map({ [$0] }))[0]
    }
    
    /// Returns the elements with the given `ids` if it's not `nil`, otherwise returns `count` random elements. If `count` is greater than the number of elements in the collection, or if any of the ids doesn't appear in the collection, or if `count` is different than the number of ids, throws an exception.
    public func sample(count: Int, ids: [Element.ID]?) throws -> [Element] where Element: Identifiable {
        return try self.ids.sample(count: count, replay: ids).map({ first(id: $0)! })
    }
    
    /// Returns the given `replay` elements if it's not `nil`, otherwise returns `count` random elements. If `count` is greater than the number of elements in the collection, or if any of the replay elements doesn't appear in the collection, or if `count` is different than the number of replay elements, throws an exception.
    public func sample(count: Int, replay: [Element]?) throws -> [Element] where Element: Equatable {
        var elements = Array(self)
        return try elements.draw(count: count, replay: replay)
    }
    
}

extension RangeReplaceableCollection {
    
    /// Shuffles the collection by using  the order given by `ids` if it's not `nil`, otherwise shuffles the collection randomly. If any of the ids doesn't appear in the collection, or if the number of ids is different than the number of elements in the collection, throws an exception.
    public mutating func shuffle(ids: [Element.ID]?) throws where Element: Identifiable {
        var elements = self.ids
        try elements.shuffle(replay: ids)
        replaceSubrange(startIndex..<endIndex, with: elements.map({ first(id: $0)! }))
    }
    
    /// Shuffles the collection by using  the order given by `replay` if it's not `nil`, otherwise shuffles the collection randomly. If any of the replay elements doesn't appear in the collection, or if the number of replay elements is different than the number of elements in the collection, throws an exception.
    public mutating func shuffle(replay: [Element]?) throws where Element: Equatable {
        let elements = try draw(count: count, replay: replay)
        replaceSubrange(startIndex..<endIndex, with: elements)
    }
    
    /// Removes the element with the given `id` if it's not `nil`, otherwise removes a random element. If `id` doesn't appear in the collection, throws an exception.
    public mutating func drawOne(id: Element.ID?) throws -> Element where Element: Identifiable {
        return try draw(count: 1, ids: id.map({ [$0] }))[0]
    }
    
    /// Removes the given `replay` element if it's not `nil`, otherwise removes a random element. If `replay` doesn't appear in the collection, throws an exception.
    public mutating func drawOne(replay: Element?) throws -> Element where Element: Equatable {
        return try draw(count: 1, replay: replay.map({ [$0] }))[0]
    }
    
    /// Removes the elements with the given `ids` if it's not `nil`, otherwise removes `count` random elements. If `count` is greater than the number of elements in the collection, or if any of the ids doesn't appear in the collection, or if `count` is different than the number of ids, throws an exception.
    public mutating func draw(count: Int, ids: [Element.ID]?) throws -> [Element] where Element: Identifiable {
        var allIds = self.ids
        let ids = try allIds.draw(count: count, replay: ids)
        var elements = [Element]()
        for id in ids {
            elements.append(remove(at: firstIndex(id: id)!))
        }
        return elements
    }
    
    /// Removes the given `replay` elements if it's not `nil`, otherwise removes `count` random elements. If `count` is greater than the number of elements in the collection, or if any of the replay elements doesn't appear in the collection, or if `count` is different than the number of replay elements, throws an exception.
    public mutating func draw(count: Int, replay: [Element]?) throws -> [Element] where Element: Equatable {
        var elements = [Element]()
        if let replay = replay {
            if replay.count != count {
                throw HostError(message: "Cannot draw a number of elements different from the given number of replay elements.")
            }
            for replay in replay {
                guard let index = firstIndex(of: replay) else {
                    throw HostError(message: "Replay element \(replay) doesn't exist.")
                }
                elements.append(remove(at: index))
            }
        } else {
            for _ in 0..<count {
                guard let index = indices.randomElement() else {
                    throw HostError(message: "Cannot draw a number of elements greater than the collection count.")
                }
                elements.append(remove(at: index))
            }
        }
        return elements
    }
    
    /// Removes and returns the element with the given `id`, or removes a random element if `id` is `nil`. It also returns after how many elements `emptying` has been appended to the collection (`nil` if the collection contained enough elements, 0 if it happened before drawing, or 1 if it happened after drawing).
    public mutating func drawOne<T: RangeReplaceableCollection & MutableCollection>(id: Element.ID?, shuffle: ShuffleMode, emptying: inout T) throws -> (element: Element, shuffleAfter: Int?) where Element: Identifiable, T.Element == Element, T.Index == Int {
        let result = try draw(count: 1, ids: id.map({ [$0] }), shuffle: shuffle, emptying: &emptying)
        return (element: result.elements[0], shuffleAfter: result.shuffleAfter)
    }
    
    /// Removes and returns the elements with the given `ids`, or removes `count` random elements if `ids` is `nil`. It also returns after how many elements `emptying` has been appended to the collection (`nil` if the collection contained enough elements, 0 if it happened before drawing, or a positive number if it happened during or after drawing).
    public mutating func draw<T: RangeReplaceableCollection & MutableCollection>(count: Int, ids: [Element.ID]?, shuffle: ShuffleMode, emptying: inout T) throws -> (elements: [Element], shuffleAfter: Int?) where Element: Identifiable, T.Element == Element, T.Index == Int {
        var ids = ids
        var elements = [Element]()
        var shuffleAfter: Int?
        let shouldShuffle = switch shuffle {
        case .afterDraw:
            count >= self.count
        case .beforeDraw:
            count > self.count
        }
        if shouldShuffle {
            let firstIds = ids?.removeAndReturnFirst(self.count)
            elements.append(contentsOf: try draw(count: self.count, ids: firstIds))
            append(contentsOf: emptying.removeAndReturnAll())
            shuffleAfter = elements.count
        }
        let remaining = Swift.min(count - elements.count, self.count)
        if remaining > 0 {
            elements.append(contentsOf: try draw(count: remaining, ids: ids))
        }
        return (elements, shuffleAfter)
    }

}

public enum ShuffleMode {
    /// Shuffle the elements immediately after the deck is emptied.
    case afterDraw
    /// Shuffle the elements when trying to draw a new one but the deck is empty.
    case beforeDraw
}
