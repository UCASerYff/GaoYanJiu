import AppKit
import Foundation
import SwiftUI

enum RewardAssetKind: String, Codable, CaseIterable, Identifiable {
    case building
    case decoration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .building: AppLocalization.text("房屋")
        case .decoration: AppLocalization.text("摆件")
        }
    }

    var ticketTitle: String {
        switch self {
        case .building: AppLocalization.text("房屋券")
        case .decoration: AppLocalization.text("摆件券")
        }
    }

}

struct RewardFootprint: Hashable {
    let width: Int
    let depth: Int

    func rotated(_ quarterTurns: Int) -> RewardFootprint {
        quarterTurns.isMultiple(of: 2) ? self : RewardFootprint(width: depth, depth: width)
    }

    var title: String { "\(width)×\(depth)" }
}

enum RewardRarity: String, Codable, CaseIterable, Identifiable {
    case common
    case rare
    case epic
    case legendary
    case mythic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .common: AppLocalization.text("普通")
        case .rare: AppLocalization.text("稀有")
        case .epic: AppLocalization.text("史诗")
        case .legendary: AppLocalization.text("传说")
        case .mythic: AppLocalization.text("神话")
        }
    }

    var color: Color {
        switch self {
        case .common: Color.secondary
        case .rare: AppTheme.blue
        case .epic: Color.purple
        case .legendary: Color.orange
        case .mythic: Color(red: 0.83, green: 0.12, blue: 0.32)
        }
    }

    var coinRatePerHour: Double {
        switch self {
        case .common: 0.05
        case .rare: 0.12
        case .epic: 0.30
        case .legendary: 0.80
        case .mythic: 2.00
        }
    }
}

struct RewardPoolDefinition: Identifiable, Hashable {
    let id: String
    let kind: RewardAssetKind
    let titleKey: String
    let subtitleKey: String
    let symbol: String
    let baseHue: Double

    var title: String { AppLocalization.text(titleKey) }
    var subtitle: String { AppLocalization.text(subtitleKey) }
}

struct RewardAssetDefinition: Identifiable, Hashable {
    let id: String
    let poolID: String
    let kind: RewardAssetKind
    let rarity: RewardRarity
    let prototypeIndex: Int
    let finishVariant: Int
    let sequence: Int

    var name: String {
        return "\(architecturalName) · \(rarity.title) \(String(format: "%03d", sequence))"
    }

    var hueDegrees: Double {
        let poolHue = RewardCatalog.pool(id: poolID)?.baseHue ?? 0
        let finishHue = Double(finishVariant - 3) * 9
        return poolHue + finishHue
    }

    var saturation: Double {
        [0.84, 0.92, 1.0, 1.06, 1.12, 0.96, 1.04][finishVariant % 7]
    }

    var footprint: RewardFootprint {
        if kind == .decoration {
            return prototypeIndex.isMultiple(of: 5)
                ? RewardFootprint(width: 1, depth: 2)
                : RewardFootprint(width: 1, depth: 1)
        }
        // Land requirements follow building function, never lottery tier or finish.
        switch architectureUse {
        case 8: return RewardFootprint(width: 1, depth: 2)
        case 1, 6, 7: return RewardFootprint(width: 3, depth: 2)
        case 4, 5: return RewardFootprint(width: 3, depth: 3)
        default: return RewardFootprint(width: 2, depth: 2)
        }
    }
}

struct RewardInventoryItem: Codable, Hashable, Identifiable {
    var catalogID: String
    var count: Int
    var id: String { catalogID }
}

struct RewardPlacement: Codable, Hashable, Identifiable {
    var id: String
    var catalogID: String
    var x: Double
    var y: Double
    var zIndex: Int
    var placedAt: Date
    var anchorRow: Int?
    var anchorColumn: Int?
    var rotationQuarterTurns: Int?

    init(
        id: String,
        catalogID: String,
        x: Double,
        y: Double,
        zIndex: Int,
        placedAt: Date,
        anchorRow: Int? = nil,
        anchorColumn: Int? = nil,
        rotationQuarterTurns: Int? = nil
    ) {
        self.id = id
        self.catalogID = catalogID
        self.x = x
        self.y = y
        self.zIndex = zIndex
        self.placedAt = placedAt
        self.anchorRow = anchorRow
        self.anchorColumn = anchorColumn
        self.rotationQuarterTurns = rotationQuarterTurns
    }

    private enum CodingKeys: String, CodingKey {
        case id, catalogID, x, y, zIndex, placedAt
        case anchorRow, anchorColumn, rotationQuarterTurns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        catalogID = try container.decode(String.self, forKey: .catalogID)
        x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0
        zIndex = try container.decodeIfPresent(Int.self, forKey: .zIndex) ?? 0
        placedAt = try container.decodeIfPresent(Date.self, forKey: .placedAt) ?? Date()
        anchorRow = try container.decodeIfPresent(Int.self, forKey: .anchorRow)
        anchorColumn = try container.decodeIfPresent(Int.self, forKey: .anchorColumn)
        rotationQuarterTurns = try container.decodeIfPresent(Int.self, forKey: .rotationQuarterTurns)
    }
}

enum RewardTerrainKind: String, Codable, CaseIterable, Identifiable {
    case lake
    case forest
    case desert
    case snowMountain
    case wetland
    case volcanic
    case flowerMeadow
    case crystalField

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lake: AppLocalization.text("湖泊")
        case .forest: AppLocalization.text("森林")
        case .desert: AppLocalization.text("沙漠")
        case .snowMountain: AppLocalization.text("雪山")
        case .wetland: AppLocalization.text("湿地")
        case .volcanic: AppLocalization.text("火山地")
        case .flowerMeadow: AppLocalization.text("花海")
        case .crystalField: AppLocalization.text("晶石原野")
        }
    }
}

struct RewardTerrainDefinition: Identifiable, Hashable {
    let id: String
    let kind: RewardTerrainKind
    let variant: Int

    var name: String {
        "\(kind.title) · \(String(format: "%02d", variant + 1))"
    }
}

struct RewardTerrainInventoryItem: Codable, Hashable, Identifiable {
    var terrainID: String
    var count: Int
    var id: String { terrainID }
}

struct RewardCityState: Codable, Hashable {
    var coins: Double
    var buildingTickets: Int
    var decorationTickets: Int
    var unlockedPlotIDs: Set<String>
    var inventory: [RewardInventoryItem]
    var placements: [RewardPlacement]
    var terrainInventory: [RewardTerrainInventoryItem]
    var plotTerrains: [String: String]
    var rewardedWorkIDs: Set<String>
    var rewardedCertificateIDs: Set<String>
    var buildingPity: Int
    var decorationPity: Int
    var lastCoinCollectionAt: Date
    var highestZIndex: Int

    init(
        coins: Double = 0,
        buildingTickets: Int = 0,
        decorationTickets: Int = 0,
        unlockedPlotIDs: Set<String> = RewardCityGrid.initialPlotIDs,
        inventory: [RewardInventoryItem] = [],
        placements: [RewardPlacement] = [],
        terrainInventory: [RewardTerrainInventoryItem] = [],
        plotTerrains: [String: String] = [:],
        rewardedWorkIDs: Set<String> = [],
        rewardedCertificateIDs: Set<String> = [],
        buildingPity: Int = 0,
        decorationPity: Int = 0,
        lastCoinCollectionAt: Date = Date(),
        highestZIndex: Int = 0
    ) {
        self.coins = coins
        self.buildingTickets = buildingTickets
        self.decorationTickets = decorationTickets
        self.unlockedPlotIDs = unlockedPlotIDs
        self.inventory = inventory
        self.placements = placements
        self.terrainInventory = terrainInventory
        self.plotTerrains = plotTerrains
        self.rewardedWorkIDs = rewardedWorkIDs
        self.rewardedCertificateIDs = rewardedCertificateIDs
        self.buildingPity = buildingPity
        self.decorationPity = decorationPity
        self.lastCoinCollectionAt = lastCoinCollectionAt
        self.highestZIndex = highestZIndex
    }
}

enum RewardCityGrid {
    /// The original V3.0–V3.3 board was 7×7. These constants are kept only
    /// for coordinate compatibility; V3.4 plot IDs themselves are unbounded.
    static let dimension = 7
    static let subdivisions = 3
    static let microDimension = dimension * subdivisions
    static let plotWidth: CGFloat = 174
    static let plotHeight: CGFloat = 132

    static let initialPlotIDs: Set<String> = Set(
        (2...4).flatMap { row in (2...4).map { column in id(row: row, column: column) } }
    )

    static func id(row: Int, column: Int) -> String { "\(row):\(column)" }

    static func components(of id: String) -> (row: Int, column: Int)? {
        let values = id.split(separator: ":").compactMap { Int($0) }
        guard values.count == 2 else { return nil }
        return (values[0], values[1])
    }

    static func contains(row: Int, column: Int) -> Bool {
        true
    }

    static func containsMicro(row: Int, column: Int) -> Bool {
        true
    }

    static func plotID(microRow: Int, microColumn: Int) -> String? {
        id(
            row: floorDivision(microRow, by: subdivisions),
            column: floorDivision(microColumn, by: subdivisions)
        )
    }

    static func floorDivision(_ value: Int, by divisor: Int) -> Int {
        precondition(divisor > 0)
        let quotient = value / divisor
        let remainder = value % divisor
        return remainder < 0 ? quotient - 1 : quotient
    }

    static func neighboringPlotIDs(of plotID: String, includeDiagonals: Bool = true) -> Set<String> {
        guard let components = components(of: plotID) else { return [] }
        var result = Set<String>()
        for rowOffset in -1...1 {
            for columnOffset in -1...1 {
                guard rowOffset != 0 || columnOffset != 0 else { continue }
                guard includeDiagonals || rowOffset == 0 || columnOffset == 0 else { continue }
                result.insert(id(row: components.row + rowOffset, column: components.column + columnOffset))
            }
        }
        return result
    }

    /// Keeps exactly one purchasable ring around every owned plot. As soon as
    /// a frontier plot is purchased its outward neighbors become the next ring,
    /// so expansion is effectively unlimited without prebuilding a giant board.
    static func frontierPlotIDs(for unlockedPlotIDs: Set<String>) -> Set<String> {
        unlockedPlotIDs.reduce(into: Set<String>()) { result, plotID in
            result.formUnion(neighboringPlotIDs(of: plotID))
        }
        .subtracting(unlockedPlotIDs)
    }

    static func renderedPlotIDs(for unlockedPlotIDs: Set<String>) -> Set<String> {
        unlockedPlotIDs.union(frontierPlotIDs(for: unlockedPlotIDs))
    }

    struct PlotBounds: Equatable {
        let minRow: Int
        let maxRow: Int
        let minColumn: Int
        let maxColumn: Int
    }

    static func bounds(for plotIDs: Set<String>) -> PlotBounds {
        let coordinates = plotIDs.compactMap(components)
        return PlotBounds(
            minRow: coordinates.map(\.row).min() ?? 2,
            maxRow: coordinates.map(\.row).max() ?? 4,
            minColumn: coordinates.map(\.column).min() ?? 2,
            maxColumn: coordinates.map(\.column).max() ?? 4
        )
    }

    static func legacyMicroAnchor(x: Double, y: Double) -> (row: Int, column: Int) {
        let plotColumn = max(0, min(dimension - 1, Int(x / Double(plotWidth))))
        let plotRow = max(0, min(dimension - 1, Int(y / Double(plotHeight))))
        return (plotRow * subdivisions + 1, plotColumn * subdivisions + 1)
    }

    static func plotID(at point: CGPoint) -> String? {
        guard point.x >= 0, point.y >= 0 else { return nil }
        let column = Int(point.x / plotWidth)
        let row = Int(point.y / plotHeight)
        guard contains(row: row, column: column) else { return nil }
        return id(row: row, column: column)
    }

    static func center(of plotID: String) -> CGPoint? {
        guard let components = components(of: plotID) else { return nil }
        return CGPoint(
            x: CGFloat(components.column) * plotWidth + plotWidth / 2,
            y: CGFloat(components.row) * plotHeight + plotHeight / 2
        )
    }
}

enum RewardCatalog {
    static let terrainDrawCost = 100.0
    static let buildingPools: [RewardPoolDefinition] = [
        .init(id: "building-campus", kind: .building, titleKey: "学术街区", subtitleKey: "学舍、图书馆与学院建筑", symbol: "building.columns.fill", baseHue: -8),
        .init(id: "building-garden", kind: .building, titleKey: "绿野家园", subtitleKey: "草木环绕的温暖居所", symbol: "leaf.fill", baseHue: 18),
        .init(id: "building-future", kind: .building, titleKey: "未来实验城", subtitleKey: "实验室、观测站与研究塔", symbol: "sparkles", baseHue: 150),
        .init(id: "building-royal", kind: .building, titleKey: "典藏王城", subtitleKey: "宫殿、城堡与纪念建筑", symbol: "crown.fill", baseHue: 32),
    ]

    static let decorationPools: [RewardPoolDefinition] = [
        .init(id: "decoration-campus", kind: .decoration, titleKey: "校园小景", subtitleKey: "长椅、路灯与学术陈设", symbol: "graduationcap.fill", baseHue: -4),
        .init(id: "decoration-nature", kind: .decoration, titleKey: "自然花园", subtitleKey: "花坛、绿篱、水景与树木", symbol: "tree.fill", baseHue: 28),
        .init(id: "decoration-discovery", kind: .decoration, titleKey: "发现工坊", subtitleKey: "仪器、天文与科学雕塑", symbol: "scope", baseHue: 145),
        .init(id: "decoration-ceremony", kind: .decoration, titleKey: "荣誉广场", subtitleKey: "纪念碑、华亭与典礼景观", symbol: "medal.fill", baseHue: 24),
    ]

    static let pools = buildingPools + decorationPools

    static let allAssets: [RewardAssetDefinition] = pools.flatMap(makeAssets)
    private static let assetMap = Dictionary(uniqueKeysWithValues: allAssets.map { ($0.id, $0) })

    static let terrains: [RewardTerrainDefinition] = RewardTerrainKind.allCases.flatMap { kind in
        (0..<9).map { variant in
            RewardTerrainDefinition(
                id: "terrain-\(kind.rawValue)-\(String(format: "%02d", variant + 1))",
                kind: kind,
                variant: variant
            )
        }
    }
    private static let terrainMap = Dictionary(uniqueKeysWithValues: terrains.map { ($0.id, $0) })

    static func pool(id: String) -> RewardPoolDefinition? { pools.first { $0.id == id } }
    static func asset(id: String) -> RewardAssetDefinition? { assetMap[id] }
    static func terrain(id: String) -> RewardTerrainDefinition? { terrainMap[id] }

    static func assets(poolID: String, rarity: RewardRarity? = nil) -> [RewardAssetDefinition] {
        allAssets.filter { $0.poolID == poolID && (rarity == nil || $0.rarity == rarity) }
    }

    private static func makeAssets(for pool: RewardPoolDefinition) -> [RewardAssetDefinition] {
        (0..<240).map { index in
            let rarity: RewardRarity
            let prototypeIndex: Int
            switch index {
            case 0..<120:
                rarity = .common
                prototypeIndex = index % 6
            case 120..<180:
                rarity = .rare
                prototypeIndex = 6 + (index - 120) % 6
            case 180..<216:
                rarity = .epic
                prototypeIndex = 12 + (index - 180) % 12
            case 216..<234:
                rarity = .legendary
                prototypeIndex = 24 + (index - 216) % 6
            default:
                rarity = .mythic
                prototypeIndex = 30 + (index - 234) % 6
            }
            let sequence = index + 1
            return RewardAssetDefinition(
                id: "\(pool.id)-\(String(format: "%03d", sequence))",
                poolID: pool.id,
                kind: pool.kind,
                rarity: rarity,
                prototypeIndex: prototypeIndex,
                finishVariant: index % 7,
                sequence: sequence
            )
        }
    }
}
