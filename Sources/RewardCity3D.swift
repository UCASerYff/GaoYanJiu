import AppKit
import SceneKit
import SwiftUI

struct RewardCityScenePanel: View {
    @EnvironmentObject private var store: PaperStore
    @Binding var selectedAssetID: String?
    @Binding var selectedTerrainID: String?
    @Binding var selectedRotation: Int
    @State private var selectedPlacementID: String?
    @State private var selectedTerrainPlotID: String?
    @State private var cameraYaw = 45.0
    @SceneStorage("gqns.research.cameraScale") private var cameraScale = 20.0
    @SceneStorage("gqns.research.cameraX") private var cameraPanX = 0.0
    @SceneStorage("gqns.research.cameraZ") private var cameraPanZ = 0.0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLocalization.text("三维研究城")).font(.headline)
                    Text(selectionHint).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()

                if selectedAssetID != nil {
                    Button {
                        selectedRotation = (selectedRotation + 1) % 4
                    } label: {
                        Label(AppLocalization.text("旋转待放物"), systemImage: "rotate.right")
                    }
                    .buttonStyle(.bordered)
                }
                if let selectedPlacementID {
                    HStack(spacing: 2) {
                        Button {
                            store.rotateRewardPlacement(id: selectedPlacementID)
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .accessibilityLabel(AppLocalization.text("旋转建筑或摆件"))
                        Button {
                            store.removeRewardPlacement(id: selectedPlacementID)
                            self.selectedPlacementID = nil
                        } label: {
                            Image(systemName: "shippingbox.and.arrow.backward")
                        }
                        .accessibilityLabel(AppLocalization.text("收回建筑或摆件"))
                    }
                    .buttonStyle(.bordered)
                    .help(AppLocalization.text("旋转或收回背包"))
                }
                if let selectedTerrainPlotID {
                    Button {
                        store.removeTerrain(from: selectedTerrainPlotID)
                        self.selectedTerrainPlotID = nil
                    } label: {
                        Label(AppLocalization.text("收回地皮"), systemImage: "shippingbox.and.arrow.backward")
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 2) {
                    Button { cameraYaw -= 45 } label: { Image(systemName: "rotate.left") }
                        .accessibilityLabel(AppLocalization.text("向左旋转视角"))
                    Button { cameraYaw += 45 } label: { Image(systemName: "rotate.right") }
                        .accessibilityLabel(AppLocalization.text("向右旋转视角"))
                }
                .buttonStyle(.bordered)
                .help(AppLocalization.text("旋转三维视角"))

                HStack(spacing: 2) {
                    Button { cameraScale = min(120, cameraScale + 2) } label: { Image(systemName: "minus.magnifyingglass") }
                        .accessibilityLabel(AppLocalization.text("缩小"))
                    Button {
                        frameWholeIsland()
                    } label: { Image(systemName: "scope") }
                        .accessibilityLabel(AppLocalization.text("回到中心"))
                    Button { cameraScale = max(8, cameraScale - 2) } label: { Image(systemName: "plus.magnifyingglass") }
                        .accessibilityLabel(AppLocalization.text("放大"))
                }
                .buttonStyle(.bordered)
                .help(AppLocalization.text("缩小、回到中心、放大"))

                VStack(alignment: .trailing, spacing: 3) {
                    Text(AppLocalization.format("每小时产出 %.2f 金币", store.rewardCoinRatePerHour))
                        .font(.caption.monospacedDigit())
                    Button {
                        store.collectRewardCoins()
                    } label: {
                        Label(AppLocalization.format("收取 %.2f", store.pendingRewardCoins()), systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.pendingRewardCoins() < 0.01)
                }
            }
            .padding(13)
            Divider()

            RewardCitySceneView(
                state: store.rewardCity,
                selectedAssetID: selectedAssetID,
                selectedTerrainID: selectedTerrainID,
                selectedRotation: selectedRotation,
                selectedPlacementID: selectedPlacementID,
                selectedTerrainPlotID: selectedTerrainPlotID,
                cameraYaw: cameraYaw,
                cameraScale: cameraScale,
                cameraPanX: cameraPanX,
                cameraPanZ: cameraPanZ,
                plotCost: { store.rewardPlotCost(for: $0) },
                canUnlockPlot: { store.canUnlockRewardPlot($0) },
                onCellClick: handleCellClick,
                onMovePlacement: { id, row, column in
                    store.moveRewardPlacement(id: id, anchorRow: row, anchorColumn: column)
                },
                onSelectPlacement: { selectedPlacementID = $0 },
                onSelectTerrain: { selectedTerrainPlotID = $0 },
                onRotatePlacement: { id in
                    store.rotateRewardPlacement(id: id)
                },
                onRemovePlacement: { id in
                    store.removeRewardPlacement(id: id)
                    if selectedPlacementID == id { selectedPlacementID = nil }
                },
                onMoveTerrain: { source, destination in
                    store.moveTerrain(from: source, to: destination)
                    selectedTerrainPlotID = store.rewardCity.plotTerrains[destination] != nil ? destination : source
                },
                onRemoveTerrain: { plotID in
                    store.removeTerrain(from: plotID)
                    if selectedTerrainPlotID == plotID { selectedTerrainPlotID = nil }
                },
                onPan: { deltaX, deltaZ in
                    cameraPanX += deltaX
                    cameraPanZ += deltaZ
                },
                onZoom: { cameraScale = $0 }
            )
            .frame(minHeight: 520)
            // V4.6 batch-S：SceneKit 场景整体作为一个读屏元素，朗读城市概况；
            // 放置/收回/视角操作的等价入口在库存面板与上方工具栏按钮。
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(sceneAccessibilitySummary)
            .accessibilityHint(AppLocalization.text("使用库存面板和工具栏按钮操作"))
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
        .clipped()
        .onAppear { if cameraScale == 20 {
            let layout=observationLayout(store.rewardCity)
            cameraScale=max(10,min(60,layout.overviewScale));cameraPanX=Double(layout.centerX);cameraPanZ=Double(layout.centerZ)
        } }
        .onChange(of: selectedAssetID) { _ in
            selectedPlacementID = nil
            selectedTerrainPlotID = nil
        }
        .onChange(of: selectedTerrainID) { _ in
            selectedPlacementID = nil
            selectedTerrainPlotID = nil
        }
    }

    private func frameWholeIsland() {
        let bounds = RewardCityGrid.bounds(for: RewardCityGrid.renderedPlotIDs(for: store.rewardCity.unlockedPlotIDs))
        let layout = RewardIslandLayout(minRow:bounds.minRow,maxRow:bounds.maxRow,minColumn:bounds.minColumn,maxColumn:bounds.maxColumn)
        cameraScale = min(120, layout.overviewScale)
        cameraPanX = Double(layout.centerX)
        cameraPanZ = Double(layout.centerZ)
    }

    private var sceneAccessibilitySummary: String {
        AppLocalization.format(
            "三维研究城：已解锁 %d 块地皮，已放置 %d 个物品，金币 %.1f",
            store.rewardCity.unlockedPlotIDs.count,
            store.rewardCity.placements.count,
            store.rewardCity.coins + store.pendingRewardCoins()
        )
    }

    private var selectionHint: String {
        if let selectedAssetID, let asset = RewardCatalog.asset(id: selectedAssetID) {
            let footprint = asset.footprint.rotated(selectedRotation)
            return AppLocalization.format("已选择“%@” · 占地 %@，点击小格放置", asset.name, footprint.title)
        }
        if let selectedTerrainID, let terrain = RewardCatalog.terrain(id: selectedTerrainID) {
            return AppLocalization.format("已选择“%@”，点击整块 3×3 地皮应用", terrain.name)
        }
        if selectedPlacementID != nil {
            return AppLocalization.text("拖动建筑或摆件可换位；上方按钮或右键可收回背包")
        }
        if selectedTerrainPlotID != nil {
            return AppLocalization.text("拖动特殊地皮可换位；上方按钮或右键可收回背包")
        }
        return AppLocalization.text("按住城市空白处拖动可平移视图；滚轮或按钮缩放；扩建后浮空岛随地皮向外生长，回到中心可查看全岛")
    }

    private func handleCellClick(row: Int, column: Int) {
        guard let plotID = RewardCityGrid.plotID(microRow: row, microColumn: column) else { return }
        guard store.rewardCity.unlockedPlotIDs.contains(plotID) else {
            if store.canUnlockRewardPlot(plotID) { store.purchaseRewardPlot(plotID) }
            return
        }
        if let selectedTerrainID {
            store.applyTerrain(selectedTerrainID, to: plotID)
            return
        }
        guard let selectedAssetID else { return }
        store.placeRewardAsset(
            catalogID: selectedAssetID,
            anchorRow: row,
            anchorColumn: column,
            rotationQuarterTurns: selectedRotation
        )
    }
}

private struct RewardCitySceneView: NSViewRepresentable {
    let state: RewardCityState
    let selectedAssetID: String?
    let selectedTerrainID: String?
    let selectedRotation: Int
    let selectedPlacementID: String?
    let selectedTerrainPlotID: String?
    let cameraYaw: Double
    let cameraScale: Double
    let cameraPanX: Double
    let cameraPanZ: Double
    let plotCost: (String) -> Int
    let canUnlockPlot: (String) -> Bool
    let onCellClick: (Int, Int) -> Void
    let onMovePlacement: (String, Int, Int) -> Void
    let onSelectPlacement: (String?) -> Void
    let onSelectTerrain: (String?) -> Void
    let onRotatePlacement: (String) -> Void
    let onRemovePlacement: (String) -> Void
    let onMoveTerrain: (String, String) -> Void
    let onRemoveTerrain: (String) -> Void
    let onPan: (Double, Double) -> Void
    let onZoom: (Double) -> Void
    var observationOnly = false

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> RewardInteractiveSCNView {
        let view = RewardInteractiveSCNView(frame: .zero)
        view.observationOnly = observationOnly
        view.scene = SCNScene()
        view.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.09, green: 0.13, blue: 0.19, alpha: 1)
                : NSColor(calibratedRed: 0.79, green: 0.91, blue: 0.93, alpha: 1)
        }
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.rendersContinuously = false
        view.isPlaying = false
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = false
        view.onCellClick = { context.coordinator.parent.onCellClick($0, $1) }
        view.onMovePlacement = { context.coordinator.parent.onMovePlacement($0, $1, $2) }
        view.onSelectPlacement = { context.coordinator.parent.onSelectPlacement($0) }
        view.onSelectTerrain = { context.coordinator.parent.onSelectTerrain($0) }
        view.onRotatePlacement = { context.coordinator.parent.onRotatePlacement($0) }
        view.onRemovePlacement = { context.coordinator.parent.onRemovePlacement($0) }
        view.onMoveTerrain = { context.coordinator.parent.onMoveTerrain($0, $1) }
        view.onRemoveTerrain = { context.coordinator.parent.onRemoveTerrain($0) }
        view.onPan = { context.coordinator.parent.onPan($0, $1) }
        view.onZoom = { context.coordinator.parent.onZoom($0) }
        view.specialTerrainPlotIDs = Set(state.plotTerrains.keys)
        view.isPlacingItem = selectedAssetID != nil || selectedTerrainID != nil
        view.cameraYaw = cameraYaw
        RewardSceneBuilder.rebuild(view: view, parent: self)
        context.coordinator.sceneSignature = sceneSignature
        return view
    }

    func updateNSView(_ view: RewardInteractiveSCNView, context: Context) {
        context.coordinator.parent = self
        view.onCellClick = { context.coordinator.parent.onCellClick($0, $1) }
        view.onMovePlacement = { context.coordinator.parent.onMovePlacement($0, $1, $2) }
        view.onSelectPlacement = { context.coordinator.parent.onSelectPlacement($0) }
        view.onSelectTerrain = { context.coordinator.parent.onSelectTerrain($0) }
        view.onRotatePlacement = { context.coordinator.parent.onRotatePlacement($0) }
        view.onRemovePlacement = { context.coordinator.parent.onRemovePlacement($0) }
        view.onMoveTerrain = { context.coordinator.parent.onMoveTerrain($0, $1) }
        view.onRemoveTerrain = { context.coordinator.parent.onRemoveTerrain($0) }
        view.onPan = { context.coordinator.parent.onPan($0, $1) }
        view.onZoom = { context.coordinator.parent.onZoom($0) }
        view.specialTerrainPlotIDs = Set(state.plotTerrains.keys)
        view.isPlacingItem = selectedAssetID != nil || selectedTerrainID != nil
        view.cameraYaw = cameraYaw
        let signature = sceneSignature
        if signature != context.coordinator.sceneSignature {
            context.coordinator.sceneSignature = signature
            RewardSceneBuilder.rebuild(view: view, parent: self)
        } else {
            RewardSceneBuilder.updateCamera(view: view, parent: self)
        }
    }

    private var sceneSignature: String {
        let unlocked = state.unlockedPlotIDs.sorted().joined(separator: ",")
        let terrains = state.plotTerrains.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let placements = state.placements.sorted(by: { $0.id < $1.id }).map { placement in
            let legacy = RewardCityGrid.legacyMicroAnchor(x: placement.x, y: placement.y)
            return [
                placement.id, placement.catalogID,
                String(placement.anchorRow ?? legacy.row),
                String(placement.anchorColumn ?? legacy.column),
                String(placement.rotationQuarterTurns ?? 0),
                String(placement.zIndex),
            ].joined(separator: ":")
        }.joined(separator: ",")
        return "\(unlocked)|\(terrains)|\(placements)|\(selectedPlacementID ?? "-")|\(selectedTerrainPlotID ?? "-")"
    }

    final class Coordinator {
        var parent: RewardCitySceneView
        var sceneSignature = ""
        init(parent: RewardCitySceneView) { self.parent = parent }
    }
}

private final class RewardInteractiveSCNView: SCNView {
    var observationOnly = false
    override func hitTest(_ point: NSPoint) -> NSView? { observationOnly ? nil : super.hitTest(point) }
    var onCellClick: ((Int, Int) -> Void)?
    var onMovePlacement: ((String, Int, Int) -> Void)?
    var onSelectPlacement: ((String?) -> Void)?
    var onSelectTerrain: ((String?) -> Void)?
    var onRotatePlacement: ((String) -> Void)?
    var onRemovePlacement: ((String) -> Void)?
    var onMoveTerrain: ((String, String) -> Void)?
    var onRemoveTerrain: ((String) -> Void)?
    var onPan: ((Double, Double) -> Void)?
    var onZoom: ((Double) -> Void)?
    var specialTerrainPlotIDs: Set<String> = []
    var isPlacingItem = false
    var cameraYaw = 45.0
    private var draggingPlacementID: String?
    private var draggingTerrainPlotID: String?
    private var terrainDestinationPlotID: String?
    private var dragCell: (row: Int, column: Int)?
    private var mouseDownPoint: CGPoint?
    private var pendingCell: (row: Int, column: Int)?
    private var initialCameraPosition: SCNVector3?
    private var initialTargetPosition: SCNVector3?
    private var panWorldDelta = (x: 0.0, z: 0.0)
    private var isPanning = false

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let placementID = placementID(at: point) {
            draggingPlacementID = placementID
            onSelectPlacement?(placementID)
            onSelectTerrain?(nil)
            return
        }
        if let cell = cell(at: point) {
            onSelectPlacement?(nil)
            let plotID = RewardCityGrid.plotID(microRow: cell.row, microColumn: cell.column)
            if isPlacingItem {
                onSelectTerrain?(nil)
                onCellClick?(cell.row, cell.column)
                return
            }
            if let plotID, specialTerrainPlotIDs.contains(plotID) {
                draggingTerrainPlotID = plotID
                terrainDestinationPlotID = plotID
                onSelectTerrain?(plotID)
                return
            }
            onSelectTerrain?(nil)
            beginPan(at: point, pendingCell: cell)
            return
        }
        onSelectPlacement?(nil)
        onSelectTerrain?(nil)
        beginPan(at: point, pendingCell: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let placementID = draggingPlacementID {
            guard let cell = cell(at: point) else { return }
            dragCell = cell
            if let node = scene?.rootNode.childNode(withName: "placement-root:\(placementID)", recursively: true) {
                node.position.x = CGFloat(cell.column) - CGFloat(RewardCityGrid.microDimension - 1) / 2
                node.position.z = CGFloat(cell.row) - CGFloat(RewardCityGrid.microDimension - 1) / 2
                node.opacity = 0.72
            }
            return
        }
        if let sourcePlotID = draggingTerrainPlotID {
            guard let cell = cell(at: point),
                  let destination = RewardCityGrid.plotID(microRow: cell.row, microColumn: cell.column)
            else { return }
            terrainDestinationPlotID = destination
            setTerrainOpacity(plotID: sourcePlotID, opacity: 0.62)
            return
        }
        guard let mouseDownPoint, let initialCameraPosition, let initialTargetPosition else { return }
        let dx = point.x - mouseDownPoint.x
        let dy = point.y - mouseDownPoint.y
        guard isPanning || hypot(dx, dy) > 3 else { return }
        isPanning = true
        pendingCell = nil
        let scale = cameraNode?.camera?.orthographicScale ?? 20
        let factor = scale / Double(max(bounds.height, 1))
        let radians = cameraYaw * .pi / 180
        let right = (x: sin(radians), z: -cos(radians))
        let forward = (x: cos(radians), z: sin(radians))
        let worldX = (-Double(dx) * right.x + Double(dy) * forward.x * 0.72) * factor
        let worldZ = (-Double(dx) * right.z + Double(dy) * forward.z * 0.72) * factor
        panWorldDelta = (worldX, worldZ)
        let cameraX = initialCameraPosition.x + CGFloat(worldX)
        let cameraZ = initialCameraPosition.z + CGFloat(worldZ)
        cameraNode?.position = SCNVector3(cameraX, initialCameraPosition.y, cameraZ)
        let targetX = initialTargetPosition.x + CGFloat(worldX)
        let targetZ = initialTargetPosition.z + CGFloat(worldZ)
        targetNode?.position = SCNVector3(targetX, initialTargetPosition.y, targetZ)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let placementID = draggingPlacementID {
            if let node = scene?.rootNode.childNode(withName: "placement-root:\(placementID)", recursively: true) {
                node.opacity = 1
            }
            if let dragCell { onMovePlacement?(placementID, dragCell.row, dragCell.column) }
        } else if let source = draggingTerrainPlotID {
            setTerrainOpacity(plotID: source, opacity: 1)
            if let destination = terrainDestinationPlotID, destination != source {
                onMoveTerrain?(source, destination)
            }
        } else if isPanning {
            onPan?(panWorldDelta.x, panWorldDelta.z)
        } else if let pendingCell {
            onCellClick?(pendingCell.row, pendingCell.column)
        }
        resetInteraction()
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let placementID = placementID(at: point) {
            onSelectPlacement?(placementID)
            onSelectTerrain?(nil)
            let menu = NSMenu()
            menu.addItem(makeContextItem(
                title: AppLocalization.text("收回背包"),
                systemImage: "shippingbox.and.arrow.backward",
                action: #selector(removePlacementMenuAction(_:)),
                representedObject: placementID
            ))
            menu.addItem(makeContextItem(
                title: AppLocalization.text("旋转"),
                systemImage: "arrow.triangle.2.circlepath",
                action: #selector(rotatePlacementMenuAction(_:)),
                representedObject: placementID
            ))
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        if let plotID = plotID(at: point), specialTerrainPlotIDs.contains(plotID) {
            onSelectPlacement?(nil)
            onSelectTerrain?(plotID)
            let menu = NSMenu()
            menu.addItem(makeContextItem(
                title: AppLocalization.text("收回地皮"),
                systemImage: "shippingbox.and.arrow.backward",
                action: #selector(removeTerrainMenuAction(_:)),
                representedObject: plotID
            ))
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    private func makeContextItem(
        title: String,
        systemImage: String,
        action: Selector,
        representedObject: Any
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
        return item
    }

    @objc private func rotatePlacementMenuAction(_ sender: NSMenuItem) {
        guard let placementID = sender.representedObject as? String else { return }
        onRotatePlacement?(placementID)
    }

    @objc private func removePlacementMenuAction(_ sender: NSMenuItem) {
        guard let placementID = sender.representedObject as? String else { return }
        onRemovePlacement?(placementID)
    }

    @objc private func removeTerrainMenuAction(_ sender: NSMenuItem) {
        guard let plotID = sender.representedObject as? String else { return }
        onRemoveTerrain?(plotID)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let camera = scene?.rootNode.childNode(withName: "reward-camera", recursively: false)?.camera else { return }
        let newScale = max(8, min(120, camera.orthographicScale + Double(event.scrollingDeltaY) * 0.08))
        camera.orthographicScale = newScale
        onZoom?(newScale)
        needsDisplay = true
    }

    // V4.6 batch-Q2：触控板捏合缩放手势，映射到与滚轮完全相同的 orthographicScale 路径。
    // magnification > 0 为张开（放大画面 = 减小正交尺度），行为与滚轮缩放一致。
    override func magnify(with event: NSEvent) {
        guard let camera = scene?.rootNode.childNode(withName: "reward-camera", recursively: false)?.camera else { return }
        let newScale = max(8, min(120, camera.orthographicScale / (1.0 + Double(event.magnification))))
        camera.orthographicScale = newScale
        onZoom?(newScale)
        needsDisplay = true
    }

    private func hits(at point: CGPoint) -> [SCNHitTestResult] {
        hitTest(point, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue])
    }

    private func placementID(at point: CGPoint) -> String? {
        for hit in hits(at: point) {
            var node: SCNNode? = hit.node
            while let current = node {
                if let name = current.name, name.hasPrefix("placement-root:") {
                    return String(name.dropFirst("placement-root:".count))
                }
                node = current.parent
            }
        }
        return nil
    }

    private func plotID(at point: CGPoint) -> String? {
        guard let cell = cell(at: point) else { return nil }
        return RewardCityGrid.plotID(microRow: cell.row, microColumn: cell.column)
    }

    private func cell(at point: CGPoint) -> (row: Int, column: Int)? {
        for hit in hits(at: point) {
            var node: SCNNode? = hit.node
            while let current = node {
                if current.name?.hasPrefix("reward-ground:") == true {
                    let offset = CGFloat(RewardCityGrid.microDimension) / 2
                    let row = Int(floor(hit.worldCoordinates.z + offset))
                    let column = Int(floor(hit.worldCoordinates.x + offset))
                    if RewardCityGrid.containsMicro(row: row, column: column) {
                        return (row, column)
                    }
                }
                node = current.parent
            }
        }
        return nil
    }

    private var cameraNode: SCNNode? {
        scene?.rootNode.childNode(withName: "reward-camera", recursively: false)
    }

    private var targetNode: SCNNode? {
        scene?.rootNode.childNode(withName: "reward-camera-target", recursively: false)
    }

    private func setTerrainOpacity(plotID: String, opacity: CGFloat) {
        scene?.rootNode.childNode(withName: "reward-ground:\(plotID)", recursively: true)?.opacity = opacity
        scene?.rootNode.childNode(withName: "terrain-detail:\(plotID)", recursively: true)?.opacity = opacity
    }

    private func beginPan(at point: CGPoint, pendingCell: (row: Int, column: Int)?) {
        mouseDownPoint = point
        self.pendingCell = pendingCell
        initialCameraPosition = cameraNode?.position
        initialTargetPosition = targetNode?.position
    }

    private func resetInteraction() {
        draggingPlacementID = nil
        draggingTerrainPlotID = nil
        terrainDestinationPlotID = nil
        dragCell = nil
        mouseDownPoint = nil
        pendingCell = nil
        initialCameraPosition = nil
        initialTargetPosition = nil
        panWorldDelta = (0, 0)
        isPanning = false
    }
}

private enum RewardSceneBuilder {
    static func rebuild(view: SCNView, parent: RewardCitySceneView) {
        guard let scene = view.scene else { return }
        scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }
        scene.background.contents = cachedFloatingSky ?? NSImage(size:NSSize(width:1,height:1))
        addLighting(to: scene)
        addCamera(
            to: scene,
            yaw: parent.cameraYaw,
            scale: parent.cameraScale,
            panX: parent.cameraPanX,
            panZ: parent.cameraPanZ
        )
        addBoard(to: scene, parent: parent)
        addPlacements(to: scene, parent: parent)
        view.pointOfView = scene.rootNode.childNode(withName: "reward-camera", recursively: false)
    }

    static func updateCamera(view: SCNView, parent: RewardCitySceneView) {
        guard let scene = view.scene,
              let camera = scene.rootNode.childNode(withName: "reward-camera", recursively: false),
              let target = scene.rootNode.childNode(withName: "reward-camera-target", recursively: false)
        else { return }
        camera.camera?.orthographicScale = max(8, min(120, parent.cameraScale))
        let radians = parent.cameraYaw * .pi / 180
        camera.position = SCNVector3(
            Float(cos(radians) * 23 + parent.cameraPanX),
            24,
            Float(sin(radians) * 23 + parent.cameraPanZ)
        )
        target.position = SCNVector3(Float(parent.cameraPanX), 0, Float(parent.cameraPanZ))
        view.pointOfView = camera
        view.needsDisplay = true
    }

    private static let cachedFloatingSky = ResearchBundle.bundle.url(forResource:"FloatingSkyV354",withExtension:"png",subdirectory:"RewardCity").flatMap { NSImage(contentsOf:$0) }
    private static let cachedFloatingRock = ResearchBundle.bundle.url(forResource:"FloatingRockV354",withExtension:"png",subdirectory:"RewardCity").flatMap { NSImage(contentsOf:$0) }

    private static func addLighting(to scene: SCNScene) {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 620
        ambient.light?.color = NSColor(calibratedWhite: 0.88, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 1_150
        sun.light?.castsShadow = true
        sun.light?.shadowMode = .deferred
        sun.light?.shadowRadius = 8
        sun.light?.shadowColor = NSColor.black.withAlphaComponent(0.22)
        sun.eulerAngles = SCNVector3(-0.9, -0.65, -0.25)
        scene.rootNode.addChildNode(sun)
    }

    private static func addCamera(to scene: SCNScene, yaw: Double, scale: Double, panX: Double, panZ: Double) {
        let camera = SCNNode()
        camera.name = "reward-camera"
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = max(8, min(120, scale))
        camera.camera?.zNear = 0.1
        camera.camera?.zFar = 200
        let radians = yaw * .pi / 180
        camera.position = SCNVector3(
            Float(cos(radians) * 23 + panX),
            24,
            Float(sin(radians) * 23 + panZ)
        )
        let target = SCNNode()
        target.name = "reward-camera-target"
        target.position = SCNVector3(Float(panX), 0, Float(panZ))
        scene.rootNode.addChildNode(target)
        let constraint = SCNLookAtConstraint(target: target)
        constraint.isGimbalLockEnabled = true
        camera.constraints = [constraint]
        scene.rootNode.addChildNode(camera)
    }

    private static func addBoard(to scene: SCNScene, parent: RewardCitySceneView) {
        let renderedIDs = RewardCityGrid.renderedPlotIDs(for: parent.state.unlockedPlotIDs)
        let bounds = RewardCityGrid.bounds(for: renderedIDs)
        let island = RewardIslandLayout(minRow:bounds.minRow,maxRow:bounds.maxRow,minColumn:bounds.minColumn,maxColumn:bounds.maxColumn)
        scene.rootNode.addChildNode(RewardFloatingIsland.make(layout:island,rock:cachedFloatingRock,grass:grassTexture()))

        let renderedCoordinates = renderedIDs.compactMap(RewardCityGrid.components).sorted {
            $0.row == $1.row ? $0.column < $1.column : $0.row < $1.row
        }
        for coordinate in renderedCoordinates {
            let plotID = RewardCityGrid.id(row: coordinate.row, column: coordinate.column)
            let unlocked = parent.state.unlockedPlotIDs.contains(plotID)
            let terrain = parent.state.plotTerrains[plotID].flatMap(RewardCatalog.terrain)
            scene.rootNode.addChildNode(plotNode(row: coordinate.row, column: coordinate.column, unlocked: unlocked, terrain: terrain))
            if let terrain {
                let detail = RewardTerrainArt.model(terrain, joined: RewardTerrainArt.joinedMask(terrain, row: coordinate.row, column: coordinate.column, state: parent.state))
                detail.position = plotCenter(coordinate.row, coordinate.column, y: 0)
                detail.name = "terrain-detail:\(plotID)"
                scene.rootNode.addChildNode(detail)
            } else if !unlocked, parent.canUnlockPlot(plotID) {
                addUnlockMarker(cost: parent.plotCost(plotID), plotRow: coordinate.row, plotColumn: coordinate.column, to: scene)
            }
        }
        addMicroGrid(to: scene, bounds: bounds)
    }

    private static func plotNode(
        row: Int,
        column: Int,
        unlocked: Bool,
        terrain: RewardTerrainDefinition?
    ) -> SCNNode {
        let height: CGFloat = terrain?.kind == .lake ? 0.08 : 0.16
        let geometry = SCNBox(width: 3.005, height: height, length: 3.005, chamferRadius: terrain == nil ? 0.04 : 0.01)
        let node = SCNNode(geometry: geometry)
        node.name = "reward-ground:\(RewardCityGrid.id(row: row, column: column))"
        node.position = plotCenter(row, column, y: terrain?.kind == .lake ? -0.045 : 0)
        let color: NSColor
        if !unlocked {
            color = NSColor(calibratedRed: 0.25, green: 0.45, blue: 0.39, alpha: 0.72)
        } else if let terrain {
            color = terrainColor(terrain.kind, variant: terrain.variant)
        } else {
            let variationIndex = ((row * 7 + column * 3) % 5 + 5) % 5
            let variation = CGFloat(variationIndex) * 0.012
            color = NSColor(calibratedRed: 0.31 + variation, green: 0.66 + variation, blue: 0.35, alpha: 1)
        }
        let surface = material(color: color, roughness: terrain?.kind == .lake ? 0.18 : 0.88)
        if unlocked, terrain == nil, let texture = grassTexture() {
            surface.diffuse.contents = texture
            surface.diffuse.wrapS = .repeat
            surface.diffuse.wrapT = .repeat
            surface.diffuse.contentsTransform = SCNMatrix4MakeScale(0.6, 0.6, 1)
            surface.multiply.contents = color
        }
        if terrain?.kind == .lake {
            surface.metalness.contents = 0.12
            surface.transparency = 0.90
        }
        geometry.materials = [surface]
        return node
    }

    private static func addMicroGrid(to scene: SCNScene, bounds: RewardCityGrid.PlotBounds) {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor(calibratedWhite: 0.12, alpha: 0.18)
        material.writesToDepthBuffer = false
        let horizontalSpan = CGFloat((bounds.maxColumn - bounds.minColumn + 1) * RewardCityGrid.subdivisions)
        let verticalSpan = CGFloat((bounds.maxRow - bounds.minRow + 1) * RewardCityGrid.subdivisions)
        let startX = CGFloat(bounds.minColumn * RewardCityGrid.subdivisions) - CGFloat(RewardCityGrid.microDimension) / 2
        let startZ = CGFloat(bounds.minRow * RewardCityGrid.subdivisions) - CGFloat(RewardCityGrid.microDimension) / 2
        let centerX = startX + horizontalSpan / 2
        let centerZ = startZ + verticalSpan / 2
        for index in 0...Int(verticalSpan) {
            let coordinate = startZ + CGFloat(index)
            let thickness: CGFloat = index.isMultiple(of: RewardCityGrid.subdivisions) ? 0.035 : 0.016
            let horizontal = SCNNode(geometry: SCNBox(width: horizontalSpan, height: 0.012, length: thickness, chamferRadius: 0))
            horizontal.position = SCNVector3(centerX, 0.105, coordinate)
            horizontal.geometry?.materials = [material]
            horizontal.renderingOrder = 20
            scene.rootNode.addChildNode(horizontal)
        }
        for index in 0...Int(horizontalSpan) {
            let coordinate = startX + CGFloat(index)
            let thickness: CGFloat = index.isMultiple(of: RewardCityGrid.subdivisions) ? 0.035 : 0.016
            let vertical = SCNNode(geometry: SCNBox(width: thickness, height: 0.012, length: verticalSpan, chamferRadius: 0))
            vertical.position = SCNVector3(coordinate, 0.105, centerZ)
            vertical.geometry?.materials = [material]
            vertical.renderingOrder = 20
            scene.rootNode.addChildNode(vertical)
        }
    }

    private static func addUnlockMarker(cost: Int, plotRow: Int, plotColumn: Int, to scene: SCNScene) {
        let root = SCNNode()
        root.position = plotCenter(plotRow, plotColumn, y: 0.25)
        let base = SCNNode(geometry: SCNCylinder(radius: 0.38, height: 0.18))
        base.geometry?.materials = [material(color: NSColor(calibratedWhite: 0.17, alpha: 0.74), roughness: 0.7)]
        root.addChildNode(base)
        let text = SCNText(string: "🔓\n\(cost)", extrusionDepth: 0.015)
        text.font = NSFont.systemFont(ofSize: 0.22, weight: .semibold)
        text.alignmentMode = CATextLayerAlignmentMode.center.rawValue
        text.flatness = 0.2
        text.materials = [material(color: .white, roughness: 0.7)]
        let label = SCNNode(geometry: text)
        label.scale = SCNVector3(0.58, 0.58, 0.58)
        label.position = SCNVector3(-0.29, 0.18, 0)
        label.constraints = [SCNBillboardConstraint()]
        root.addChildNode(label)
        scene.rootNode.addChildNode(root)
    }

    private static func addTerrainDetails(
        _ terrain: RewardTerrainDefinition,
        plotRow: Int,
        plotColumn: Int,
        state: RewardCityState,
        to scene: SCNScene
    ) {
        let root = SCNNode()
        root.position = plotCenter(plotRow, plotColumn, y: 0.12)
        root.name = "terrain-detail:\(RewardCityGrid.id(row: plotRow, column: plotColumn))"
        switch terrain.kind {
        case .lake:
            for offset in [-0.72, 0.0, 0.72] {
                let ripple = SCNNode(geometry: SCNTorus(ringRadius: 0.22, pipeRadius: 0.016))
                ripple.geometry?.materials = [material(color: NSColor.white.withAlphaComponent(0.48), roughness: 0.15)]
                ripple.position = SCNVector3(Float(offset), 0.03, Float(offset * 0.35))
                ripple.scale.z = 0.55
                root.addChildNode(ripple)
            }
        case .forest:
            for (x, z) in [(-0.82, -0.75), (0.68, -0.65), (-0.52, 0.65), (0.76, 0.72)] {
                let tree = RewardModelFactory.treeNode(seed: terrain.variant + Int((x + z) * 10))
                tree.position = SCNVector3(Float(x), 0.05, Float(z))
                tree.scale = SCNVector3(0.78, 0.78, 0.78)
                root.addChildNode(tree)
            }
        case .desert:
            for (x, z) in [(-0.72, -0.62), (0.75, 0.58), (0.15, -0.85)] {
                let rock = SCNNode(geometry: SCNSphere(radius: 0.18))
                rock.scale = SCNVector3(1.4, 0.62, 1)
                rock.position = SCNVector3(Float(x), 0.1, Float(z))
                rock.geometry?.materials = [material(color: NSColor(calibratedRed: 0.69, green: 0.42, blue: 0.20, alpha: 1), roughness: 0.95)]
                root.addChildNode(rock)
            }
        case .snowMountain:
            for (x, z, scale) in [(-0.65, 0.20, 0.80), (0.35, -0.22, 1.15), (0.78, 0.58, 0.62)] {
                let mountain = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.62, height: 1.35))
                mountain.position = SCNVector3(Float(x), Float(scale * 0.55), Float(z))
                mountain.scale = SCNVector3(Float(scale), Float(scale), Float(scale))
                mountain.geometry?.materials = [material(color: NSColor(calibratedWhite: 0.90, alpha: 1), roughness: 0.72)]
                root.addChildNode(mountain)
            }
        case .wetland:
            for index in 0..<9 {
                let reed = SCNNode(geometry: SCNCylinder(radius: 0.018, height: 0.55))
                reed.position = SCNVector3(Float((index % 3) - 1) * 0.72, 0.25, Float((index / 3) - 1) * 0.72)
                reed.geometry?.materials = [material(color: NSColor(calibratedRed: 0.34, green: 0.48, blue: 0.14, alpha: 1), roughness: 0.9)]
                root.addChildNode(reed)
            }
        case .volcanic:
            let volcano = SCNNode(geometry: SCNCone(topRadius: 0.28, bottomRadius: 1.0, height: 1.25))
            volcano.position.y = 0.58
            volcano.geometry?.materials = [material(color: NSColor(calibratedWhite: 0.16, alpha: 1), roughness: 0.94)]
            root.addChildNode(volcano)
            let lava = SCNNode(geometry: SCNTorus(ringRadius: 0.23, pipeRadius: 0.07))
            lava.position.y = 1.22
            lava.geometry?.materials = [emissiveMaterial(color: .systemOrange)]
            root.addChildNode(lava)
        case .flowerMeadow:
            for index in 0..<14 {
                let flower = SCNNode(geometry: SCNSphere(radius: 0.07))
                flower.position = SCNVector3(Float((index * 47) % 250) / 100 - 1.25, 0.14, Float((index * 71) % 250) / 100 - 1.25)
                flower.geometry?.materials = [material(color: [.systemPink, .systemYellow, .systemPurple][index % 3], roughness: 0.65)]
                root.addChildNode(flower)
            }
        case .crystalField:
            for (x, z, scale) in [(-0.72, -0.52, 0.8), (0.0, 0.1, 1.25), (0.78, 0.62, 0.72)] {
                let crystal = SCNNode(geometry: SCNPyramid(width: 0.42, height: 1.0, length: 0.42))
                crystal.position = SCNVector3(Float(x), Float(scale * 0.42), Float(z))
                crystal.scale = SCNVector3(Float(scale), Float(scale), Float(scale))
                crystal.geometry?.materials = [emissiveMaterial(color: NSColor.systemCyan.withAlphaComponent(0.8))]
                root.addChildNode(crystal)
            }
        }
        addTerrainTransitions(to: root, terrain: terrain, plotRow: plotRow, plotColumn: plotColumn, state: state)
        scene.rootNode.addChildNode(root)
    }

    private static func addTerrainTransitions(
        to root: SCNNode,
        terrain: RewardTerrainDefinition,
        plotRow: Int,
        plotColumn: Int,
        state: RewardCityState
    ) {
        let edges: [(dr: Int, dc: Int, x: Float, z: Float, width: CGFloat, length: CGFloat)] = [
            (-1, 0, 0, -1.38, 2.8, 0.13), (1, 0, 0, 1.38, 2.8, 0.13),
            (0, -1, -1.38, 0, 0.13, 2.8), (0, 1, 1.38, 0, 0.13, 2.8),
        ]
        for edge in edges {
            let neighborID = RewardCityGrid.contains(row: plotRow + edge.dr, column: plotColumn + edge.dc)
                ? RewardCityGrid.id(row: plotRow + edge.dr, column: plotColumn + edge.dc)
                : nil
            let neighborKind = neighborID.flatMap { state.plotTerrains[$0] }.flatMap(RewardCatalog.terrain)?.kind
            guard neighborKind != terrain.kind else { continue }
            let strip = SCNNode(geometry: SCNBox(width: edge.width, height: 0.035, length: edge.length, chamferRadius: 0.025))
            strip.position = SCNVector3(edge.x, 0.04, edge.z)
            let transitionColor = terrain.kind == .lake
                ? NSColor(calibratedRed: 0.78, green: 0.69, blue: 0.43, alpha: 0.85)
                : terrainColor(terrain.kind, variant: terrain.variant).blended(withFraction: 0.38, of: NSColor(calibratedRed: 0.33, green: 0.67, blue: 0.36, alpha: 1)) ?? .systemGreen
            strip.geometry?.materials = [material(color: transitionColor, roughness: 0.86)]
            root.addChildNode(strip)
        }
    }

    private static func addPlacements(to scene: SCNScene, parent: RewardCitySceneView) {
        for placement in parent.state.placements.sorted(by: { $0.zIndex < $1.zIndex }) {
            guard let asset = RewardCatalog.asset(id: placement.catalogID) else { continue }
            let legacy = RewardCityGrid.legacyMicroAnchor(x: placement.x, y: placement.y)
            let row = placement.anchorRow ?? legacy.row
            let column = placement.anchorColumn ?? legacy.column
            let rotation = placement.rotationQuarterTurns ?? 0
            let footprint = asset.footprint.rotated(rotation)
            let root = placementNode(asset, selected: parent.selectedPlacementID == placement.id)
            root.name = "placement-root:\(placement.id)"
            root.eulerAngles.y = CGFloat(rotation) * .pi / 2
            root.position = SCNVector3(
                Float(column) - Float(RewardCityGrid.microDimension - 1) / 2 + Float(footprint.width - 1) / 2,
                0.12,
                Float(row) - Float(RewardCityGrid.microDimension - 1) / 2 + Float(footprint.depth - 1) / 2
            )
            scene.rootNode.addChildNode(root)
        }
    }

    static func placementNode(_ asset: RewardAssetDefinition, selected: Bool) -> SCNNode {
        // World-sized selection geometry must never inherit the model's scale.
        // Both siblings rotate together exactly once around this unit-scale root.
        let root = SCNNode()
        root.addChildNode(RewardModelFactory.assetNode(asset))
        if selected {
            let marker = SCNNode(geometry: SCNBox(
                width: CGFloat(asset.footprint.width) * 0.94,
                height: 0.008,
                length: CGFloat(asset.footprint.depth) * 0.94,
                chamferRadius: 0.04
            ))
            marker.name = "selection-footprint"
            marker.position.y = 0.005
            marker.geometry?.materials = [emissiveMaterial(color: NSColor.systemYellow.withAlphaComponent(0.72))]
            root.addChildNode(marker)
        }
        return root
    }

    private static func plotCenter(_ row: Int, _ column: Int, y: Float) -> SCNVector3 {
        SCNVector3(
            Float(column * RewardCityGrid.subdivisions + 1) - Float(RewardCityGrid.microDimension - 1) / 2,
            y,
            Float(row * RewardCityGrid.subdivisions + 1) - Float(RewardCityGrid.microDimension - 1) / 2
        )
    }

    private static func terrainColor(_ kind: RewardTerrainKind, variant: Int) -> NSColor {
        let delta = CGFloat(variant % 4) * 0.015
        switch kind {
        case .lake: return NSColor(calibratedRed: 0.12, green: 0.55 + delta, blue: 0.78, alpha: 1)
        case .forest: return NSColor(calibratedRed: 0.13, green: 0.43 + delta, blue: 0.20, alpha: 1)
        case .desert: return NSColor(calibratedRed: 0.88, green: 0.67 + delta, blue: 0.31, alpha: 1)
        case .snowMountain: return NSColor(calibratedRed: 0.82, green: 0.90, blue: 0.94 + delta, alpha: 1)
        case .wetland: return NSColor(calibratedRed: 0.24, green: 0.56 + delta, blue: 0.44, alpha: 1)
        case .volcanic: return NSColor(calibratedWhite: 0.20 + delta, alpha: 1)
        case .flowerMeadow: return NSColor(calibratedRed: 0.38, green: 0.70 + delta, blue: 0.31, alpha: 1)
        case .crystalField: return NSColor(calibratedRed: 0.25, green: 0.52 + delta, blue: 0.64, alpha: 1)
        }
    }

    private static let cachedGrassTexture: NSImage? = {
        let bundleURL = ResearchBundle.bundle.url(forResource: "grass-3d-texture", withExtension: "png", subdirectory: "RewardCity")
        let developmentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/RewardCity/grass-3d-texture.png")
        return (bundleURL ?? (FileManager.default.fileExists(atPath: developmentURL.path) ? developmentURL : nil))
            .flatMap(NSImage.init(contentsOf:))
    }()

    private static func grassTexture() -> NSImage? { cachedGrassTexture }

    fileprivate static func material(color: NSColor, roughness: CGFloat, metalness: CGFloat = 0.02) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.roughness.contents = roughness
        material.metalness.contents = metalness
        return material
    }

    fileprivate static func emissiveMaterial(color: NSColor) -> SCNMaterial {
        let material = material(color: color, roughness: 0.25, metalness: 0.18)
        material.emission.contents = color.withAlphaComponent(0.38)
        return material
    }
}

enum RewardModelFactory {
    static func assetNode(_ asset: RewardAssetDefinition) -> SCNNode {
        RewardArchitecture.model(asset)
    }

    static func treeNode(seed: Int) -> SCNNode {
        let root = SCNNode()
        let trunk = SCNNode(geometry: SCNCylinder(radius: 0.08, height: 0.58))
        trunk.position.y = 0.29
        trunk.geometry?.materials = [RewardSceneBuilder.material(color: NSColor(calibratedRed: 0.34, green: 0.20, blue: 0.10, alpha: 1), roughness: 0.95)]
        root.addChildNode(trunk)
        let crown = SCNNode(geometry: seed.isMultiple(of: 2)
            ? SCNSphere(radius: 0.34)
            : SCNCone(topRadius: 0, bottomRadius: 0.38, height: 0.72))
        crown.position.y = 0.76
        let green = NSColor(calibratedRed: 0.12, green: 0.46 + CGFloat(seed % 4) * 0.035, blue: 0.18, alpha: 1)
        crown.geometry?.materials = [RewardSceneBuilder.material(color: green, roughness: 0.92)]
        root.addChildNode(crown)
        return root
    }
}

struct RewardModelPreview: NSViewRepresentable {
    let asset: RewardAssetDefinition

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 15
        view.rendersContinuously = false
        view.isPlaying = false
        view.scene = previewScene()
        view.pointOfView = view.scene?.rootNode.childNode(withName: "reward-preview-camera", recursively: false)
        context.coordinator.assetID = asset.id
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        guard context.coordinator.assetID != asset.id else { return }
        context.coordinator.assetID = asset.id
        view.scene = previewScene()
        view.pointOfView = view.scene?.rootNode.childNode(withName: "reward-preview-camera", recursively: false)
    }

    final class Coordinator {
        var assetID = ""
    }

    private func previewScene() -> SCNScene {
        let scene = SCNScene()
        let node = RewardModelFactory.assetNode(asset)
        let footprint = asset.footprint
        node.position.y = 0.04
        scene.rootNode.addChildNode(node)
        let base = SCNNode(geometry: SCNBox(
            width: CGFloat(footprint.width) * 0.92,
            height: 0.10,
            length: CGFloat(footprint.depth) * 0.92,
            chamferRadius: 0.08
        ))
        base.position.y = -0.05
        base.geometry?.materials = [RewardSceneBuilder.material(color: NSColor(calibratedRed: 0.35, green: 0.68, blue: 0.38, alpha: 1), roughness: 0.88)]
        scene.rootNode.addChildNode(base)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 700
        scene.rootNode.addChildNode(ambient)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 1_050
        sun.eulerAngles = SCNVector3(-0.8, -0.7, -0.2)
        scene.rootNode.addChildNode(sun)
        let camera = SCNNode()
        camera.name = "reward-preview-camera"
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = Double(max(3, max(footprint.width, footprint.depth) + 1))
        camera.position = SCNVector3(4.2, 3.6, 4.2)
        let target = SCNLookAtConstraint(target: node)
        target.isGimbalLockEnabled = true
        camera.constraints = [target]
        scene.rootNode.addChildNode(camera)
        return scene
    }
}

struct ResearchCityObservationScene: View {
    let state: RewardCityState
    var body: some View {
        let layout=observationLayout(state)
        RewardCitySceneView(state:state,selectedAssetID:nil,selectedTerrainID:nil,selectedRotation:0,selectedPlacementID:nil,selectedTerrainPlotID:nil,cameraYaw:45,cameraScale:min(120,layout.overviewScale),cameraPanX:Double(layout.centerX),cameraPanZ:Double(layout.centerZ),plotCost:{_ in 0},canUnlockPlot:{_ in false},onCellClick:{_,_ in},onMovePlacement:{_,_,_ in},onSelectPlacement:{_ in},onSelectTerrain:{_ in},onRotatePlacement:{_ in},onRemovePlacement:{_ in},onMoveTerrain:{_,_ in},onRemoveTerrain:{_ in},onPan:{_,_ in},onZoom:{_ in},observationOnly:true)
    }
}

private func observationLayout(_ state:RewardCityState)->RewardIslandLayout {
    let occupied=Set(state.placements.compactMap { p -> String? in
        let legacy=RewardCityGrid.legacyMicroAnchor(x:p.x,y:p.y)
        return RewardCityGrid.plotID(microRow:p.anchorRow ?? legacy.row,microColumn:p.anchorColumn ?? legacy.column)
    })
    let ids=occupied.isEmpty ? state.unlockedPlotIDs : occupied
    let b=RewardCityGrid.bounds(for:ids)
    return RewardIslandLayout(minRow:b.minRow,maxRow:b.maxRow,minColumn:b.minColumn,maxColumn:b.maxColumn)
}
