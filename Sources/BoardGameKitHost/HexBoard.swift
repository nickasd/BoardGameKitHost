/// A game board with hexagonal cells and support for undo operations. When instantiating this class, a `GameContext` must be active.
public struct HexBoard<Cell: HexCell>: Board {
    public var cells: RecordedArray<Cell>

    public init(cells: [Cell] = []) {
        self.cells = RecordedArray(cells)
    }
    
    public func neighbourCells(around: HexPosition, withinDistance distance: Int) -> [Cell] {
        return around.neighbourPositions(withinDistance: distance).compactMap({ cell(at: $0) })
    }
    
    public func horizontalCluster(at cell: Cell) -> [Cell] {
        return cluster(containing: cell, isIncluded: { _, _, nextCell in nextCell.position.y == cell.position.y })
    }
    
    public func rows() -> [[Cell]] {
        return Array(cells.reduce(into: [:], { $0[$1.position.y, default: []].append($1) }).values).sorted(by: { $0[0].position.y < $1[0].position.y })
    }
    
    public func neighbourCells(around: [Cell], withinDistance distance: Int = 1) -> Set<Cell> {
        return Set(around.flatMap({ neighbourCells(around: $0.position, withinDistance: distance) })).subtracting(around)
    }
}

public protocol HexCell: BoardCell where Transform == HexTransform {
}

public struct HexTransform: EuclidianCellTransform, Codable, Sendable {
    public let position: HexPosition
    public let rotation: HexRotation
    
    public init(position: HexPosition, rotation: HexRotation = .zero) {
        self.position = position
        self.rotation = rotation
    }
}

public struct HexPosition: EuclidianCellPosition, Codable, Sendable {
    public let x: Int
    public let y: Int
    public let z: Int
    
    public init(x: Int, y: Int, z: Int) {
        self.x = x
        self.y = y
        self.z = z
        if (x + y) % 2 != 0 {
            preconditionFailure("Invalid \(self).")
        }
    }
    
    public func offset(ofNeighbourAt rotation: HexRotation) -> (x: Int, y: Int) {
        return [(2, 0), (1, 1), (-1, 1), (-2, 0), (-1, -1), (1, -1)][rotation.rawValue]
    }
    
    public func positions(atEdgeDistance distance: Int) -> [HexPosition] {
        return Rotation.allCases.map({ position(at: $0, distance: distance) })
    }
    
    public func positions(atDistance distance: Int) -> [HexPosition] {
        var positions = [HexPosition]()
        let offset = offset(ofNeighbourAt: .r4)
        var position = self + HexPosition(x: offset.x * distance, y: offset.y * distance, z: z)
        for rotation in HexRotation.allCases {
            for _ in 0..<distance {
                position += rotation
                positions.append(position)
            }
        }
        return positions
    }
    
    public func neighbourPositions(withinDistance distance: Int) -> [HexPosition] {
        return (1...distance).flatMap({ positions(atDistance: $0) })
    }
    
    public func distance(to other: HexPosition) -> Int { // formula from https://ondras.github.io/rot.js/manual/#hex/indexing
        let d = self - other
        return abs(d.y) + max(0, (abs(d.x) - abs(d.y)) / 2)
    }
    
    public func angle(to other: HexPosition, atDistance distance: Int) -> HexRotation? {
        return HexRotation.allCases.first(where: { position(at: $0, distance: distance) == other })
    }
    
    public func rotation(to other: HexPosition) -> HexRotation? {
        if self == other {
            return nil
        }
        let d = self - other
        if d.y == 0 {
            return d.x < 0 ? .r0 : .r3
        } else if d.y < 0 {
            return d.x == d.y ? .r1 : -d.x == d.y ? .r2 : nil
        } else {
            return d.x == d.y ? .r4 : -d.x == d.y ? .r5 : nil
        }
    }
}

public enum HexRotation: Int, CaseIterable, EuclidianCellRotation, Codable, Sendable {
    case r0 = 0
    case r1 = 1
    case r2 = 2
    case r3 = 3
    case r4 = 4
    case r5 = 5
}
