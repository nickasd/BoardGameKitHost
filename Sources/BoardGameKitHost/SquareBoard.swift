/// A game board with square cells and support for undo operations. When instantiating this class, a `GameContext` must be active.
public struct SquareBoard<Cell: SquareCell>: Board {
    public var cells: RecordedArray<Cell>
    
    public init(cells: [Cell] = []) {
        self.cells = RecordedArray(cells)
    }
    
    public func rows() -> [[Cell]] {
        return Array(cells.reduce(into: [:], { $0[$1.position.y, default: []].append($1) }).values).sorted(by: { $0[0].position.y < $1[0].position.y })
    }
    
    public func columns() -> [[Cell]] {
        return Array(cells.reduce(into: [:], { $0[$1.position.x, default: []].append($1) }).values).sorted(by: { $0[0].position.x < $1[0].position.x })
    }
    
    public func row(at cell: Cell) -> [Cell] {
        return cluster(containing: cell, isIncluded: { _, _, nextCell in nextCell.position.y == cell.position.y })
    }
    
    public func column(at cell: Cell) -> [Cell] {
        return cluster(containing: cell, isIncluded: { _, _, nextCell in nextCell.position.x == cell.position.x })
    }
    
    public func enclosingSquare(at cell: Cell) -> [Cell] {
        return cell.position.enclosingSquarePositions().compactMap({ self.cell(at: $0) })
    }
}

public protocol SquareCell: BoardCell where Transform == SquareTransform {
}

public struct SquareTransform: EuclidianCellTransform, Codable, Sendable {
    public let position: SquarePosition
    public let rotation: SquareRotation
    
    public init(position: SquarePosition, rotation: SquareRotation = .zero) {
        self.position = position
        self.rotation = rotation
    }
}

public struct SquarePosition: EuclidianCellPosition, Codable, Sendable {
    public let x: Int
    public let y: Int
    public let z: Int
    
    public init(x: Int, y: Int, z: Int = 0) {
        self.x = x
        self.y = y
        self.z = z
    }
    
    public func offset(ofNeighbourAt rotation: SquareRotation) -> (x: Int, y: Int) {
        return [(1, 0), (0, -1), (-1, 0), (0, 1)][rotation.rawValue]
    }
    
    public func enclosingSquarePositions() -> [SquarePosition] {
        return (-1...1).flatMap({ x in (-1...1).map({ y in self + SquarePosition(x: x, y: y, z: 0) }) })
    }
}

public enum SquareRotation: Int, CaseIterable, EuclidianCellRotation, Codable, Sendable {
    case r0 = 0
    case r1 = 1
    case r2 = 2
    case r3 = 3
}
