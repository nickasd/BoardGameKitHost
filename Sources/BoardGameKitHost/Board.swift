public protocol Board {
    associatedtype Cells: BidirectionalCollection & RangeReplaceableCollection where Cells.Element: BoardCell
    typealias Cell = Cells.Element
    
    var cells: Cells { get set }
    func neighbourCells(of position: Cell.Position) -> [(cell: Cell, edge: Cell.Rotation)]
}

public protocol BoardCell: AnyObject, Hashable {
    associatedtype Transform: CellTransform
    typealias Position = Transform.Position
    typealias Rotation = Transform.Rotation

    var transform: Transform { get set }
    var cost: Int { get set }
}

public protocol CellTransform: Hashable {
    associatedtype Position: CellPosition
    associatedtype Rotation: CellRotation

    init(position: Position, rotation: Rotation)
    var position: Position { get }
    var rotation: Rotation { get }
}

public protocol CellPosition: Hashable {
    var stringValue: String { get }
}

public protocol CellRotation: Hashable {
}

extension Board {
    
    public mutating func addCell(_ cell: Cell, at transform: Cell.Transform) {
        cell.transform = transform
        addCells([cell])
    }
    
    public mutating func addCells(_ cells: [Cell]) {
        if let cell = cells.first(where: { cell(at: $0.position) != nil }) {
            preconditionFailure("Board already contains cell at \(cell.position).")
        }
        self.cells.append(contentsOf: cells)
    }
    
    public mutating func removeCell(at position: Cell.Position) {
        removeCells(at: [position])
    }
    
    public mutating func removeCells(at positions: [Cell.Position]) {
        for position in positions {
            guard let index = cells.firstIndex(where: { $0.position == position }) else {
                preconditionFailure("Cell at \(position) doesn't exist.")
            }
            cells.remove(at: index)
        }
    }
    
    public func cell(at position: Cell.Position) -> Cell? {
        return cells.first(where: { $0.position == position })
    }
    
    /**
     Returns a path that minimizes the sum of the costs needed to travel from one cell to the next given by a predicate.
     
     If the existing `path` cannot be connected to `nextCell`, `nextCellCost` should return a negative number. Otherwise, it should return a positive number. The predicate gets passed three arguments: the current path, the next cell, and the common edge between the last cell in the current path and the next cell.
     
     If there is no path with the given maximum cost, returns `nil`. Otherwise, the returned path always starts and ends with the given cells. The cost for reaching each cell in the path is stored on the cells themselves with `BoardCell.cost`.
     */
    public func shortestPath(from: Cell, to: Cell, maxCost: Int = .max, nextCellCost: (_ path: [Cell], _ nextCell: Cell, _ edge: Cell.Rotation) -> Int) -> [Cell]? {
        if from == to {
            return [from]
        }
        resetCellCosts()
        var paths = [[Cell]]()
        var newPaths = [[from]]
        from.cost = 0
        var shortestPath: (path: [Cell]?, cost: Int) = (nil, Int.max)
        while !newPaths.isEmpty {
            paths = newPaths
            newPaths.removeAll()
            for path in paths {
                for (neighbour, edge) in neighbourCells(of: path.last!.position) {
                    let cellCost = nextCellCost(path, neighbour, edge)
                    if cellCost >= 0, case let totalCost = path.last!.cost + cellCost, totalCost <= maxCost && (neighbour.cost == .unvisited || totalCost < neighbour.cost) {
                        neighbour.cost = totalCost
                        newPaths.removeAll(where: { $0.last == neighbour })
                        var newPath = path
                        newPath.append(neighbour)
                        if neighbour != to {
                            newPaths.append(newPath)
                        } else if totalCost < shortestPath.cost {
                            shortestPath = (newPath, totalCost)
                        }
                    }
                }
            }
        }
        return shortestPath.path
    }
    
    /**
     Returns a clusters of cells containing the given initial cell and which satisfy the given predicate.

     Starting from the `initialCell`, the cluster is expanded to the neighbouring cells for which `isIncluded` returns true, and so on. The predicate gets passed three arguments: a cluster cell, the outgoing edge, and the cell across the outgoing edge.
     */
    public func cluster(containing initialCell: Cell, isIncluded: (_ clusterCell: Cell, _ edge: Cell.Rotation, _ nextCell: Cell) -> Bool) -> [Cell] {
        resetCellCosts()
        return _cluster(containing: initialCell, isIncluded: isIncluded)
    }
    
    /**
     Returns an array of clusters of cells grouped by the given predicate.
     
     Clusters are expanded to the neighbouring cells for which `isIncluded` returns true. The predicate gets passed three arguments: the cell from which to expand the cluster, the outgoing edge, and the cell across the outgoing edge. A cell may get passed to the predicate multiple times: if it gets rejected for one cluster, this method tests whether it belongs to any other cluster. Each cell is added to exactly one cluster.
     */
    public func clusters(_ isIncluded: (_ clusterCell: Cell, _ edge: Cell.Rotation, _ nextCell: Cell) -> Bool) -> [[Cell]] {
        return clusters(containing: cells, isIncluded: isIncluded)
    }
    
    /**
     Returns an array of clusters of cells containing the given initial cells and which satisfy the given predicate.
     
     Starting from the given `initialCells`, the clusters are expanded to the neighbouring cells for which `isIncluded` returns true, and so on. The predicate gets passed three arguments: the cell from which to expand the cluster, the outgoing edge, and the cell across the outgoing edge. A cell may get passed to the predicate multiple times: if it gets rejected for one cluster, this method tests whether it belongs to any other cluster. A cell is added to one cluster at most.
     
     The cells in `initialCells` may already form one or more clusters.
     */
    public func clusters<S: Sequence>(containing initialCells: S, isIncluded: (_ clusterCell: Cell, _ edge: Cell.Rotation, _ nextCell: Cell) -> Bool) -> [[Cell]] where S.Element == Cell {
        resetCellCosts()
        var clusters = [[Cell]]()
        for initialCell in initialCells {
            if initialCell.cost == .unvisited, case let cluster = _cluster(containing: initialCell, isIncluded: isIncluded), !cluster.isEmpty {
                clusters.append(cluster)
            }
        }
        return clusters
    }
    
    private func _cluster(containing initialCell: Cell, isIncluded: (_ clusterCell: Cell, _ edge: Cell.Rotation, _ nextCell: Cell) -> Bool) -> [Cell] {
        var newCells = [initialCell]
        var cluster = newCells
        var discardedCells = [Cell]()
        initialCell.cost = 1
        while !newCells.isEmpty {
            var newNewCells = [Cell]()
            for cell in newCells {
                for (neighbour, edge) in neighbourCells(of: cell.position) {
                    if neighbour.cost == .unvisited {
                        if isIncluded(cell, edge, neighbour) {
                            newNewCells.append(neighbour)
                        } else {
                            discardedCells.append(neighbour)
                        }
                        neighbour.cost = 1
                    }
                }
            }
            newCells = newNewCells
            cluster.append(contentsOf: newCells)
        }
        for discardedCell in discardedCells {
            discardedCell.cost = .unvisited
        }
        return cluster
    }
    
    private func resetCellCosts() {
        for cell in cells {
            cell.cost = .unvisited
        }
    }

}

fileprivate extension Int {
    
    static let unvisited = Int.max
    
}

extension Board {
    
    public func getCell(at position: Cell.Position) throws -> Cell {
        guard let cell = cell(at: position) else {
            throw HostError.validationFailed
        }
        return cell
    }
    
    public func getCells(at positions: [Cell.Position]) throws -> [Cell] {
        return try positions.map({ try getCell(at: $0) })
    }
    
}

extension BoardCell {
    
    public static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs === rhs
    }
    
    public func hash(into hasher: inout Hasher) {
        ObjectIdentifier(self).hash(into: &hasher)
    }
    
    public var position: Position {
        return transform.position
    }
    
    public var rotation: Rotation {
        return transform.rotation
    }
    
}

extension Collection where Element: BoardCell {
    
    public var positions: [Element.Position] {
        return map({ $0.position })
    }
    
}

extension Board where Cell.Transform: EuclidianCellTransform {
    
    /**
     Returns the cells adjacent to the given `position` and the edge from which each cell was reached. The adjacent cells can have a different `z` coordinate and are the ones with the largest possible `z` coordinate (i.e. the ones visible from the top).
     */
    public func neighbourCells(of position: Cell.Position) -> [(cell: Cell, edge: Cell.Position.Rotation)] {
        return Cell.Position.Rotation.allCases.compactMap({ rotation in highestCell(at: position + rotation).map({ ($0, rotation) }) })
    }
    
    /**
     Returns the last added cell at the given `position`'s `x` and `y` coordinates (which should correspond to the cell with the largest `z` cordinate), or `nil` if no such cell has been added.
     */
    public func highestCell(at position: Cell.Position) -> Cell? {
        return cells.last(where: { $0.position.x == position.x && $0.position.y == position.y })
    }
    
    /**
     Returns the cells adjacent to the given `cell`.The adjacent cells can have a different `z` coordinate and are the ones with the largest possible `z` coordinate (i.e. the ones visible from the top)
     */
    public func neighbourCells(of cell: Cell) -> [Cell] {
        return Cell.Position.Rotation.allCases.compactMap({ highestCell(at: cell.position + $0) })
    }
    
    /**
     Returns the cells adjacent to any of the given `cells`. The adjacent cells can have a different `z` coordinate and are the ones with the largest possible `z` coordinate (i.e. the ones visible from the top)
     */
    public func neighbourCells(of cells: [Cell]) -> [Cell] {
        var neighbours = [Cell]()
        for cell in cells {
            for neighbour in neighbourCells(of: cell.position).map({ $0.cell }) {
                if !(neighbours + cells).contains(where: { $0 == neighbour }) {
                    neighbours.append(neighbour)
                }
            }
        }
        return neighbours
    }
    
    public func freeNeighbourPositions() -> [Cell.Position] {
        return cells.isEmpty ? [.zero] : Set(cells.flatMap({ $0.position.neighbourPositions() })).filter({ cell(at: $0) == nil })
    }
    
}

public protocol EuclidianCellTransform: CellTransform where Position: EuclidianCellPosition, Rotation: EuclidianCellRotation {
    static var zero: Self { get }
}

extension EuclidianCellTransform {
    
    public static var zero: Self {
        return Self(position: .zero, rotation: .zero)
    }
    
    public static func + (lhs: Self, rhs: Position) -> Self {
        return Self(position: lhs.position + rhs, rotation: lhs.rotation)
    }
    
    public static func - (lhs: Self, rhs: Position) -> Self {
        return Self(position: lhs.position - rhs, rotation: lhs.rotation)
    }
    
}

public protocol EuclidianCellPosition: CellPosition, AdditiveArithmetic {
    associatedtype Rotation: EuclidianCellRotation
    
    init(x: Int, y: Int, z: Int)
    var x: Int { get }
    var y: Int { get }
    var z: Int { get }
    func offset(ofNeighbourAt rotation: Rotation) -> (x: Int, y: Int)
}

public protocol EuclidianCellRotation: CellRotation, RawRepresentable, CaseIterable where RawValue == Int {
}

extension EuclidianCellPosition {
    
    public static var zero: Self {
        return Self(x: 0, y: 0, z: 0)
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        return Self(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }
    
    public static func - (lhs: Self, rhs: Self) -> Self {
        return Self(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }
    
    public static func += (lhs: inout Self, rhs: Self) {
        lhs = lhs + rhs
    }
    
    public static func -= (lhs: inout Self, rhs: Self) {
        lhs = lhs - rhs
    }
    
    public static func + (lhs: Self, rhs: Rotation) -> Self {
        let offset = lhs.offset(ofNeighbourAt: rhs)
        return Self(x: lhs.x + offset.x, y: lhs.y + offset.y, z: lhs.z)
    }
    
    public static func += (lhs: inout Self, rhs: Rotation) {
        lhs = lhs + rhs
    }
    
    public var stringValue: String {
        return "(\(x), \(y), \(z))"
    }
    
    public func with(z: Int) -> Self {
        return Self(x: x, y: y, z: z)
    }
    
    public func position(at rotation: Rotation, distance: Int) -> Self {
        let offset = offset(ofNeighbourAt: rotation)
        return Self(x: x + offset.x * distance, y: y + offset.y * distance, z: z)
    }
    
    public func positions(at rotation: Rotation, within range: ClosedRange<Int>) -> [Self] {
        return range.map({ position(at: rotation, distance: $0) })
    }
    
    public func neighbourPositions() -> [Self] {
        return Rotation.allCases.map({ self + $0 })
    }
    
}

extension EuclidianCellRotation {
    
    public static var zero: Self {
        return Self(rawValue: 0)!
    }
    
    public static prefix func - (rhs: Self) -> Self {
        return Self(rawValue: (Self.allCases.count - rhs.rawValue) % Self.allCases.count)!
    }
    
    public static func + (lhs: Self, rhs: Self) -> Self {
        return Self(rawValue: (((lhs.rawValue + rhs.rawValue) % Self.allCases.count) + Self.allCases.count) % Self.allCases.count)!
    }
    
    public static func - (lhs: Self, rhs: Self) -> Self {
        return Self(rawValue: (((lhs.rawValue - rhs.rawValue) % Self.allCases.count) + Self.allCases.count) % Self.allCases.count)!
    }
    
    public static func += (lhs: inout Self, rhs: Self) {
        lhs = lhs + rhs
    }
    
    public static func -= (lhs: inout Self, rhs: Self) {
        lhs = lhs - rhs
    }
    
    public var opposite: Self {
        return self + Self(rawValue: Self.allCases.count / 2)!
    }

}
