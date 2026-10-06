import AppKit
import Foundation

// MARK: - RewardCityStore：研究城状态与全部奖励规则
//
// 拥有 RewardCityState（金币/券/抽奖保底/地皮/摆放/旋转/地形）与全部规则表。
// PaperStore 通过计算属性 rewardCity 转发读写，并注入 persist/errorHandler 两个
// 单向回调：规则引擎不反向持有 PaperStore。迁移链（V3.0/V3.1/V3.9）以 inout 静态
// 函数形式实现，供 LibraryRepository 调度时对尚未装配到 store 的状态直接改写。

@MainActor
final class RewardCityStore: ObservableObject {
    @Published var state: RewardCityState

    /// 规则改动落盘回调（PaperStore.save）。
    var persist: () -> Void = {}
    /// 规则拒绝时的用户可见错误回调（PaperStore.lastError）。
    var errorHandler: (String) -> Void = { _ in }

    init(state: RewardCityState = RewardCityState()) {
        self.state = state
    }

    private func reportError(_ message: String) {
        errorHandler(message)
    }

    // MARK: 奖励发放（成果 → 房屋券，证书 → 摆件券）

    nonisolated static func buildingTicketReward(for type: ExistingWorkType) -> Int {
        switch type {
        case .graduationThesis: 10
        case .journalArticle: 5
        case .conferencePaper: 3
        default: 1
        }
    }

    nonisolated static func grantRewardForWorkIfNeeded(id: String, type: ExistingWorkType, in state: inout RewardCityState) {
        guard state.rewardedWorkIDs.insert(id).inserted else { return }
        state.buildingTickets += buildingTicketReward(for: type)
    }

    nonisolated static func grantRewardForCertificateIfNeeded(id: String, in state: inout RewardCityState) {
        guard state.rewardedCertificateIDs.insert(id).inserted else { return }
        state.decorationTickets += 1
    }

    func grantRewardForWorkIfNeeded(id: String, type: ExistingWorkType) {
        Self.grantRewardForWorkIfNeeded(id: id, type: type, in: &state)
    }

    func grantRewardForCertificateIfNeeded(id: String) {
        Self.grantRewardForCertificateIfNeeded(id: id, in: &state)
    }

    nonisolated static func reconcileTickets(
        in state: inout RewardCityState,
        works: [(id: String, type: ExistingWorkType)],
        certificateIDs: [String]
    ) {
        for work in works {
            grantRewardForWorkIfNeeded(id: work.id, type: work.type, in: &state)
        }
        for id in certificateIDs {
            grantRewardForCertificateIfNeeded(id: id, in: &state)
        }
    }

    /// 本机测试金币发放钩子（GAO_RESEARCH_TEST_COIN_GRANT）；返回发放数额，未触发为 nil。
    @discardableResult
    func applyTestingCoinGrantIfRequested() -> Double? {
        guard let rawValue = ProcessInfo.processInfo.environment["GAO_RESEARCH_TEST_COIN_GRANT"],
              let amount = Double(rawValue), amount > 0 else { return nil }
        state.coins += amount
        return amount
    }

    // MARK: 金币产出与收取

    var rewardCoinRatePerHour: Double {
        state.placements.reduce(0) { partial, placement in
            guard let asset = RewardCatalog.asset(id: placement.catalogID), asset.kind == .building else {
                return partial
            }
            return partial + asset.rarity.coinRatePerHour
        }
    }

    func pendingRewardCoins(at date: Date = Date()) -> Double {
        let elapsed = min(max(0, date.timeIntervalSince(state.lastCoinCollectionAt)), 72 * 3_600)
        return rewardCoinRatePerHour * elapsed / 3_600
    }

    func collectRewardCoins() {
        let now = Date()
        state.coins += pendingRewardCoins(at: now)
        state.lastCoinCollectionAt = now
        persist()
    }

    private func bankPendingRewardCoins() {
        let now = Date()
        state.coins += pendingRewardCoins(at: now)
        state.lastCoinCollectionAt = now
    }

    // MARK: 地皮购买

    func rewardPlotCost(for plotID: String) -> Int {
        guard !state.unlockedPlotIDs.contains(plotID) else { return 0 }
        return 100
    }

    func canUnlockRewardPlot(_ plotID: String) -> Bool {
        guard !state.unlockedPlotIDs.contains(plotID),
              RewardCityGrid.components(of: plotID) != nil else { return false }
        let neighbors = RewardCityGrid.neighboringPlotIDs(of: plotID)
        return neighbors.contains(where: state.unlockedPlotIDs.contains)
    }

    func purchaseRewardPlot(_ plotID: String) {
        guard canUnlockRewardPlot(plotID) else {
            reportError(AppLocalization.text("只能购买与已拥有地皮相邻的地皮。"))
            return
        }
        let cost = rewardPlotCost(for: plotID)
        guard state.coins >= Double(cost) else {
            reportError(AppLocalization.format("金币不足，还需要 %d 金币。", cost - Int(state.coins)))
            return
        }
        state.coins -= Double(cost)
        state.unlockedPlotIDs.insert(plotID)
        persist()
    }

    // MARK: 库存与抽奖

    func availableRewardAssetCount(catalogID: String) -> Int {
        let acquired = state.inventory.first(where: { $0.catalogID == catalogID })?.count ?? 0
        let placed = state.placements.filter { $0.catalogID == catalogID }.count
        return max(0, acquired - placed)
    }

    func drawRewards(poolID: String, count: Int) -> [RewardAssetDefinition] {
        guard let pool = RewardCatalog.pool(id: poolID), count > 0 else { return [] }
        let tickets = pool.kind == .building ? state.buildingTickets : state.decorationTickets
        guard tickets >= count else {
            reportError(AppLocalization.format("%@不足。", pool.kind.ticketTitle))
            return []
        }

        if pool.kind == .building {
            state.buildingTickets -= count
        } else {
            state.decorationTickets -= count
        }

        var results: [RewardAssetDefinition] = []
        for _ in 0..<count {
            let rarity = drawRarity(for: pool.kind)
            let candidates = RewardCatalog.assets(poolID: poolID, rarity: rarity)
            guard let asset = candidates.randomElement() else { continue }
            addRewardAssetToInventory(asset.id)
            results.append(asset)
        }
        persist()
        return results
    }

    private func addRewardAssetToInventory(_ catalogID: String) {
        if let index = state.inventory.firstIndex(where: { $0.catalogID == catalogID }) {
            state.inventory[index].count += 1
        } else {
            state.inventory.append(RewardInventoryItem(catalogID: catalogID, count: 1))
        }
    }

    private func drawRarity(for kind: RewardAssetKind) -> RewardRarity {
        let pity = kind == .building ? state.buildingPity : state.decorationPity
        let rarity: RewardRarity
        if pity >= 79 {
            rarity = .legendary
        } else {
            let roll = Int.random(in: 0..<10_000)
            switch roll {
            case 0..<20: rarity = .mythic
            case 20..<170: rarity = .legendary
            case 170..<800: rarity = .epic
            case 800..<2_600: rarity = .rare
            default: rarity = pity >= 9 ? .rare : .common
            }
        }
        let nextPity = rarity == .legendary || rarity == .mythic ? 0 : pity + 1
        if kind == .building { state.buildingPity = nextPity }
        else { state.decorationPity = nextPity }
        return rarity
    }

    // MARK: 特殊地形

    func drawSpecialTerrain() -> RewardTerrainDefinition? {
        guard state.coins >= RewardCatalog.terrainDrawCost else {
            reportError(AppLocalization.text("金币不足，特殊地皮祈愿需要 100 金币。"))
            return nil
        }
        guard let terrain = RewardCatalog.terrains.randomElement() else { return nil }
        state.coins -= RewardCatalog.terrainDrawCost
        if let index = state.terrainInventory.firstIndex(where: { $0.terrainID == terrain.id }) {
            state.terrainInventory[index].count += 1
        } else {
            state.terrainInventory.append(RewardTerrainInventoryItem(terrainID: terrain.id, count: 1))
        }
        persist()
        return terrain
    }

    func availableTerrainCount(terrainID: String) -> Int {
        let acquired = state.terrainInventory.first(where: { $0.terrainID == terrainID })?.count ?? 0
        let applied = state.plotTerrains.values.filter { $0 == terrainID }.count
        return max(0, acquired - applied)
    }

    func applyTerrain(_ terrainID: String, to plotID: String) {
        guard state.unlockedPlotIDs.contains(plotID), RewardCatalog.terrain(id: terrainID) != nil else { return }
        let oldTerrain = state.plotTerrains[plotID]
        guard oldTerrain != terrainID else { return }
        guard availableTerrainCount(terrainID: terrainID) > 0 else {
            reportError(AppLocalization.text("该特殊地皮已经全部使用。"))
            return
        }
        let containsBuilding = state.placements.contains { placement in
            let anchor = Self.anchor(of: placement)
            guard RewardCityGrid.plotID(microRow: anchor.row, microColumn: anchor.column) == plotID,
                  let asset = RewardCatalog.asset(id: placement.catalogID) else { return false }
            return asset.kind == .building
        }
        guard !containsBuilding else {
            reportError(AppLocalization.text("请先移走该地皮上的房屋，再更换为特殊地皮。"))
            return
        }
        state.plotTerrains[plotID] = terrainID
        persist()
    }

    func removeTerrain(from plotID: String) {
        guard state.plotTerrains.removeValue(forKey: plotID) != nil else { return }
        persist()
    }

    func moveTerrain(from sourcePlotID: String, to destinationPlotID: String) {
        guard sourcePlotID != destinationPlotID,
              state.unlockedPlotIDs.contains(sourcePlotID),
              state.unlockedPlotIDs.contains(destinationPlotID),
              let sourceTerrain = state.plotTerrains[sourcePlotID]
        else { return }

        let containsBuilding = state.placements.contains { placement in
            let anchor = Self.anchor(of: placement)
            guard RewardCityGrid.plotID(microRow: anchor.row, microColumn: anchor.column) == destinationPlotID,
                  let asset = RewardCatalog.asset(id: placement.catalogID) else { return false }
            return asset.kind == .building
        }
        guard !containsBuilding else {
            reportError(AppLocalization.text("特殊地皮不能移到已有房屋的地块，请先收回或移动房屋。"))
            return
        }

        let destinationTerrain = state.plotTerrains[destinationPlotID]
        state.plotTerrains[destinationPlotID] = sourceTerrain
        if let destinationTerrain {
            state.plotTerrains[sourcePlotID] = destinationTerrain
        } else {
            state.plotTerrains.removeValue(forKey: sourcePlotID)
        }
        persist()
    }

    // MARK: 摆放 / 移动 / 旋转 / 收回

    func placeRewardAsset(
        catalogID: String,
        anchorRow: Int,
        anchorColumn: Int,
        rotationQuarterTurns: Int
    ) {
        guard let asset = RewardCatalog.asset(id: catalogID) else { return }
        let rotation = Self.normalizedRotation(rotationQuarterTurns)
        let anchor = Self.normalizedAnchor(asset: asset, targetRow: anchorRow, targetColumn: anchorColumn, rotation: rotation)
        guard Self.validatePlacement(
            state: state, asset: asset, anchorRow: anchor.row, anchorColumn: anchor.column,
            rotation: rotation, excluding: nil, reportError: true, onError: errorHandler
        ) else { return }
        guard availableRewardAssetCount(catalogID: catalogID) > 0 else {
            reportError(AppLocalization.text("库存中没有可放置的该物品。"))
            return
        }
        bankPendingRewardCoins()
        state.highestZIndex += 1
        let legacyPoint = Self.legacyPoint(row: anchor.row, column: anchor.column)
        state.placements.append(RewardPlacement(
            id: UUID().uuidString, catalogID: catalogID,
            x: legacyPoint.x, y: legacyPoint.y,
            zIndex: state.highestZIndex, placedAt: Date(),
            anchorRow: anchor.row, anchorColumn: anchor.column,
            rotationQuarterTurns: rotation
        ))
        persist()
    }

    func moveRewardPlacement(id: String, anchorRow: Int, anchorColumn: Int) {
        guard let index = state.placements.firstIndex(where: { $0.id == id }),
              let asset = RewardCatalog.asset(id: state.placements[index].catalogID) else { return }
        let rotation = Self.normalizedRotation(state.placements[index].rotationQuarterTurns ?? 0)
        let anchor = Self.normalizedAnchor(asset: asset, targetRow: anchorRow, targetColumn: anchorColumn, rotation: rotation)
        guard Self.validatePlacement(
            state: state, asset: asset, anchorRow: anchor.row, anchorColumn: anchor.column,
            rotation: rotation, excluding: id, reportError: true, onError: errorHandler
        ) else { return }
        bankPendingRewardCoins()
        let legacyPoint = Self.legacyPoint(row: anchor.row, column: anchor.column)
        state.highestZIndex += 1
        state.placements[index].anchorRow = anchor.row
        state.placements[index].anchorColumn = anchor.column
        state.placements[index].rotationQuarterTurns = rotation
        state.placements[index].x = legacyPoint.x
        state.placements[index].y = legacyPoint.y
        state.placements[index].zIndex = state.highestZIndex
        persist()
    }

    func rotateRewardPlacement(id: String) {
        guard let index = state.placements.firstIndex(where: { $0.id == id }),
              let asset = RewardCatalog.asset(id: state.placements[index].catalogID) else { return }
        let current = Self.anchor(of: state.placements[index])
        let rotation = Self.normalizedRotation((state.placements[index].rotationQuarterTurns ?? 0) + 1)
        let anchor = Self.normalizedAnchor(asset: asset, targetRow: current.row, targetColumn: current.column, rotation: rotation)
        guard Self.validatePlacement(
            state: state, asset: asset, anchorRow: anchor.row, anchorColumn: anchor.column,
            rotation: rotation, excluding: id, reportError: true, onError: errorHandler
        ) else { return }
        let legacyPoint = Self.legacyPoint(row: anchor.row, column: anchor.column)
        state.placements[index].anchorRow = anchor.row
        state.placements[index].anchorColumn = anchor.column
        state.placements[index].rotationQuarterTurns = rotation
        state.placements[index].x = legacyPoint.x
        state.placements[index].y = legacyPoint.y
        persist()
    }

    func canPlaceRewardAsset(
        catalogID: String,
        anchorRow: Int,
        anchorColumn: Int,
        rotationQuarterTurns: Int,
        excludingPlacementID: String? = nil
    ) -> Bool {
        guard let asset = RewardCatalog.asset(id: catalogID) else { return false }
        let rotation = Self.normalizedRotation(rotationQuarterTurns)
        let anchor = Self.normalizedAnchor(asset: asset, targetRow: anchorRow, targetColumn: anchorColumn, rotation: rotation)
        return Self.validatePlacement(
            state: state, asset: asset, anchorRow: anchor.row, anchorColumn: anchor.column,
            rotation: rotation, excluding: excludingPlacementID, reportError: false, onError: nil
        )
    }

    func removeRewardPlacement(id: String) {
        guard state.placements.contains(where: { $0.id == id }) else { return }
        bankPendingRewardCoins()
        state.placements.removeAll { $0.id == id }
        persist()
    }

    // MARK: 摆放几何（静态纯函数，迁移链直接复用）

    nonisolated static func anchor(of placement: RewardPlacement) -> (row: Int, column: Int) {
        if let row = placement.anchorRow, let column = placement.anchorColumn { return (row, column) }
        return RewardCityGrid.legacyMicroAnchor(x: placement.x, y: placement.y)
    }

    func rewardPlacementAnchor(_ placement: RewardPlacement) -> (row: Int, column: Int) {
        Self.anchor(of: placement)
    }

    nonisolated static func occupiedCells(in state: RewardCityState, excluding placementID: String? = nil) -> Set<String> {
        var result = Set<String>()
        for placement in state.placements where placement.id != placementID {
            guard let asset = RewardCatalog.asset(id: placement.catalogID) else { continue }
            let anchor = anchor(of: placement)
            let footprint = asset.footprint.rotated(placement.rotationQuarterTurns ?? 0)
            for row in anchor.row..<(anchor.row + footprint.depth) {
                for column in anchor.column..<(anchor.column + footprint.width) {
                    result.insert("\(row):\(column)")
                }
            }
        }
        return result
    }

    func occupiedRewardCells(excluding placementID: String? = nil) -> Set<String> {
        Self.occupiedCells(in: state, excluding: placementID)
    }

    nonisolated static func normalizedRotation(_ value: Int) -> Int { ((value % 4) + 4) % 4 }

    nonisolated static func normalizedAnchor(
        asset: RewardAssetDefinition,
        targetRow: Int,
        targetColumn: Int,
        rotation: Int
    ) -> (row: Int, column: Int) {
        let footprint = asset.footprint.rotated(rotation)
        let plotRow = RewardCityGrid.floorDivision(targetRow, by: RewardCityGrid.subdivisions)
        let plotColumn = RewardCityGrid.floorDivision(targetColumn, by: RewardCityGrid.subdivisions)
        let rowStart = plotRow * RewardCityGrid.subdivisions
        let columnStart = plotColumn * RewardCityGrid.subdivisions
        return (
            max(rowStart, min(rowStart + RewardCityGrid.subdivisions - footprint.depth, targetRow)),
            max(columnStart, min(columnStart + RewardCityGrid.subdivisions - footprint.width, targetColumn))
        )
    }

    nonisolated static func validatePlacement(
        state: RewardCityState,
        asset: RewardAssetDefinition,
        anchorRow: Int,
        anchorColumn: Int,
        rotation: Int,
        excluding placementID: String?,
        reportError: Bool,
        onError: ((String) -> Void)?
    ) -> Bool {
        let footprint = asset.footprint.rotated(rotation)
        guard footprint.width <= RewardCityGrid.subdivisions,
              footprint.depth <= RewardCityGrid.subdivisions,
              RewardCityGrid.containsMicro(row: anchorRow, column: anchorColumn),
              RewardCityGrid.containsMicro(row: anchorRow + footprint.depth - 1, column: anchorColumn + footprint.width - 1),
              let plotID = RewardCityGrid.plotID(microRow: anchorRow, microColumn: anchorColumn),
              RewardCityGrid.plotID(microRow: anchorRow + footprint.depth - 1, microColumn: anchorColumn + footprint.width - 1) == plotID,
              state.unlockedPlotIDs.contains(plotID) else {
            if reportError { onError?(AppLocalization.text("建筑必须完整放在一块 3×3 地皮内。")) }
            return false
        }
        if asset.kind == .building, state.plotTerrains[plotID] != nil {
            if reportError { onError?(AppLocalization.text("特殊地皮上不能放置房屋。")) }
            return false
        }
        let occupied = occupiedCells(in: state, excluding: placementID)
        for row in anchorRow..<(anchorRow + footprint.depth) {
            for column in anchorColumn..<(anchorColumn + footprint.width) where occupied.contains("\(row):\(column)") {
                if reportError { onError?(AppLocalization.text("这里已有建筑或摆件，请换一个小格。")) }
                return false
            }
        }
        return true
    }

    nonisolated static func legacyPoint(row: Int, column: Int) -> CGPoint {
        CGPoint(
            x: (Double(column) + 0.5) / Double(RewardCityGrid.subdivisions) * Double(RewardCityGrid.plotWidth),
            y: (Double(row) + 0.5) / Double(RewardCityGrid.subdivisions) * Double(RewardCityGrid.plotHeight)
        )
    }

    // MARK: 迁移（V3.0 / V3.1 / V3.9，由 LibraryRepository 迁移链调度）

    nonisolated static func migrateToV30(
        state: inout RewardCityState,
        works: [(id: String, type: ExistingWorkType)],
        certificateIDs: [String]
    ) {
        state.unlockedPlotIDs.formUnion(RewardCityGrid.initialPlotIDs)
        reconcileTickets(in: &state, works: works, certificateIDs: certificateIDs)
    }

    nonisolated static func migrateToV31(state: inout RewardCityState) {
        state.unlockedPlotIDs.formUnion(RewardCityGrid.initialPlotIDs)
        for index in state.placements.indices {
            guard state.placements[index].anchorRow == nil || state.placements[index].anchorColumn == nil else {
                state.placements[index].rotationQuarterTurns = state.placements[index].rotationQuarterTurns ?? 0
                continue
            }
            let legacy = RewardCityGrid.legacyMicroAnchor(
                x: state.placements[index].x,
                y: state.placements[index].y
            )
            state.placements[index].anchorRow = legacy.row
            state.placements[index].anchorColumn = legacy.column
            state.placements[index].rotationQuarterTurns = 0
        }
    }

    nonisolated static func migrateToV39(state: inout RewardCityState) {
        // Inventory stores total ownership, including placed copies. Removing
        // a placement returns it to the backpack without altering ownership.
        let original = state.placements
        state.placements = []
        var pending: [RewardPlacement] = []
        for placement in original {
            guard let asset = RewardCatalog.asset(id: placement.catalogID) else {
                state.placements.append(placement)
                continue
            }
            let anchor = anchor(of: placement)
            if validatePlacement(state: state, asset: asset, anchorRow: anchor.row, anchorColumn: anchor.column,
                                 rotation: placement.rotationQuarterTurns ?? 0, excluding: nil,
                                 reportError: false, onError: nil) {
                state.placements.append(placement)
            } else { pending.append(placement) }
        }
        let cells = state.unlockedPlotIDs.compactMap(RewardCityGrid.components).flatMap { plot in
            (0..<3).flatMap { r in (0..<3).map { c in (row: plot.row*3+r, column: plot.column*3+c) } }
        }
        for var placement in pending {
            guard let asset = RewardCatalog.asset(id: placement.catalogID) else { continue }
            let old = anchor(of: placement)
            let nearest = cells.sorted {
                let a = abs($0.row-old.row)+abs($0.column-old.column)
                let b = abs($1.row-old.row)+abs($1.column-old.column)
                return a == b ? ($0.row == $1.row ? $0.column < $1.column : $0.row < $1.row) : a < b
            }.first {
                validatePlacement(state: state, asset: asset, anchorRow: $0.row, anchorColumn: $0.column,
                                  rotation: placement.rotationQuarterTurns ?? 0, excluding: nil,
                                  reportError: false, onError: nil)
            }
            guard let anchor = nearest else { continue }
            placement.anchorRow = anchor.row; placement.anchorColumn = anchor.column
            let point = legacyPoint(row: anchor.row, column: anchor.column)
            placement.x = point.x; placement.y = point.y
            state.placements.append(placement)
        }
        let order = Dictionary(uniqueKeysWithValues: original.enumerated().map { ($0.element.id, $0.offset) })
        state.placements.sort { order[$0.id, default: 0] < order[$1.id, default: 0] }
    }
}


// MARK: - PaperStore 门面转发（视图层与回归测试原样可用）

@MainActor
extension PaperStore {
    /// 研究城状态由 RewardCityStore 持有；读写经此转发，语义与原 @Published 存储一致。
    var rewardCity: RewardCityState {
        get { rewardStore.state }
        set { rewardStore.state = newValue }
    }

    static func buildingTicketReward(for type: ExistingWorkType) -> Int {
        RewardCityStore.buildingTicketReward(for: type)
    }

    var rewardCoinRatePerHour: Double {
        rewardStore.rewardCoinRatePerHour
    }

    func pendingRewardCoins(at date: Date = Date()) -> Double {
        rewardStore.pendingRewardCoins(at: date)
    }

    func collectRewardCoins() {
        rewardStore.collectRewardCoins()
    }

    func rewardPlotCost(for plotID: String) -> Int {
        rewardStore.rewardPlotCost(for: plotID)
    }

    func canUnlockRewardPlot(_ plotID: String) -> Bool {
        rewardStore.canUnlockRewardPlot(plotID)
    }

    func purchaseRewardPlot(_ plotID: String) {
        rewardStore.purchaseRewardPlot(plotID)
    }

    func availableRewardAssetCount(catalogID: String) -> Int {
        rewardStore.availableRewardAssetCount(catalogID: catalogID)
    }

    func drawRewards(poolID: String, count: Int) -> [RewardAssetDefinition] {
        rewardStore.drawRewards(poolID: poolID, count: count)
    }

    func drawSpecialTerrain() -> RewardTerrainDefinition? {
        rewardStore.drawSpecialTerrain()
    }

    func availableTerrainCount(terrainID: String) -> Int {
        rewardStore.availableTerrainCount(terrainID: terrainID)
    }

    func applyTerrain(_ terrainID: String, to plotID: String) {
        rewardStore.applyTerrain(terrainID, to: plotID)
    }

    func removeTerrain(from plotID: String) {
        rewardStore.removeTerrain(from: plotID)
    }

    func moveTerrain(from sourcePlotID: String, to destinationPlotID: String) {
        rewardStore.moveTerrain(from: sourcePlotID, to: destinationPlotID)
    }

    func placeRewardAsset(
        catalogID: String,
        anchorRow: Int,
        anchorColumn: Int,
        rotationQuarterTurns: Int
    ) {
        rewardStore.placeRewardAsset(
            catalogID: catalogID,
            anchorRow: anchorRow,
            anchorColumn: anchorColumn,
            rotationQuarterTurns: rotationQuarterTurns
        )
    }

    func moveRewardPlacement(id: String, anchorRow: Int, anchorColumn: Int) {
        rewardStore.moveRewardPlacement(id: id, anchorRow: anchorRow, anchorColumn: anchorColumn)
    }

    func rotateRewardPlacement(id: String) {
        rewardStore.rotateRewardPlacement(id: id)
    }

    func canPlaceRewardAsset(
        catalogID: String,
        anchorRow: Int,
        anchorColumn: Int,
        rotationQuarterTurns: Int,
        excludingPlacementID: String? = nil
    ) -> Bool {
        rewardStore.canPlaceRewardAsset(
            catalogID: catalogID,
            anchorRow: anchorRow,
            anchorColumn: anchorColumn,
            rotationQuarterTurns: rotationQuarterTurns,
            excludingPlacementID: excludingPlacementID
        )
    }

    func rewardPlacementAnchor(_ placement: RewardPlacement) -> (row: Int, column: Int) {
        rewardStore.rewardPlacementAnchor(placement)
    }

    func occupiedRewardCells(excluding placementID: String? = nil) -> Set<String> {
        rewardStore.occupiedRewardCells(excluding: placementID)
    }

    func removeRewardPlacement(id: String) {
        rewardStore.removeRewardPlacement(id: id)
    }
}
