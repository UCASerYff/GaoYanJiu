import AppKit
import SwiftUI

private enum RewardCityMode: String, CaseIterable, Identifiable {
    case city
    case wishes
    var id: String { rawValue }
    var title: String { self == .city ? AppLocalization.text("我的城市") : AppLocalization.text("祈愿池") }
}

private enum RewardWishCategory: String, CaseIterable, Identifiable {
    case building
    case decoration
    case terrain
    var id: String { rawValue }
    var title: String {
        switch self {
        case .building: AppLocalization.text("房屋池")
        case .decoration: AppLocalization.text("摆件池")
        case .terrain: AppLocalization.text("特殊地皮池")
        }
    }
}

struct RewardCityDashboard: View {
    @EnvironmentObject private var store: PaperStore
    @State private var mode: RewardCityMode = .city
    @State private var selectedAssetID: String?
    @SceneStorage("gqns.research.inventory") private var showInventory=false
    @State private var selectedTerrainID: String?
    @State private var selectedRotation = 0
    @State private var drawResults: [RewardAssetDefinition] = []
    @State private var terrainResult: RewardTerrainDefinition?
    @State private var showingDrawResults = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Picker("", selection: $mode) {
                    ForEach(RewardCityMode.allCases) { option in Text(option.title).tag(option) }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)

                Spacer()
                Button(showInventory ? "收起库存" : "展开库存") { showInventory.toggle() }
                RewardResourcePill(symbol: "dollarsign.circle.fill", value: coinText, label: "金币", color: .orange)
                RewardResourcePill(symbol: "ticket.fill", value: "\(store.rewardCity.buildingTickets)", label: "房屋券", color: AppTheme.blue)
                RewardResourcePill(symbol: "seal.fill", value: "\(store.rewardCity.decorationTickets)", label: "摆件券", color: AppTheme.teal)
            }
            .padding(.horizontal, 24)

            if mode == .city {
                HStack(spacing: 12) {
                    RewardCityScenePanel(
                        selectedAssetID: $selectedAssetID,
                        selectedTerrainID: $selectedTerrainID,
                        selectedRotation: $selectedRotation
                    )
                    if showInventory { RewardInventoryPanel(
                        selectedAssetID: $selectedAssetID,
                        selectedTerrainID: $selectedTerrainID,
                        openWishes: { mode = .wishes }
                    )
                    .frame(width: 250) }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
            } else {
                RewardWishPoolsView { assets, terrain in
                    drawResults = assets
                    terrainResult = terrain
                    showingDrawResults = !assets.isEmpty || terrain != nil
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
            }
        }
        .sheet(isPresented: $showingDrawResults) {
            RewardDrawResultsSheet(assets: drawResults, terrain: terrainResult)
        }
    }

    private var coinText: String {
        let total = store.rewardCity.coins + store.pendingRewardCoins()
        return total >= 1_000 ? String(format: "%.1fk", total / 1_000) : String(format: "%.1f", total)
    }
}

private struct RewardResourcePill: View {
    let symbol: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(value).font(.callout.monospacedDigit().weight(.semibold))
            Text(AppLocalization.text(label)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.07)))
        .accessibilityElement(children: .combine)
    }
}

private struct RewardInventoryPanel: View {
    @EnvironmentObject private var store: PaperStore
    @Binding var selectedAssetID: String?
    @Binding var selectedTerrainID: String?
    let openWishes: () -> Void
    @State private var category: RewardWishCategory = .building

    private var assets: [RewardAssetDefinition] {
        let kind: RewardAssetKind = category == .building ? .building : .decoration
        return store.rewardCity.inventory.compactMap { item in
            guard let asset = RewardCatalog.asset(id: item.catalogID), asset.kind == kind,
                  store.availableRewardAssetCount(catalogID: asset.id) > 0 else { return nil }
            return asset
        }
        .sorted { $0.rarity.rawValue < $1.rarity.rawValue }
    }

    private var terrains: [RewardTerrainDefinition] {
        store.rewardCity.terrainInventory.compactMap { item in
            guard store.availableTerrainCount(terrainID: item.terrainID) > 0 else { return nil }
            return RewardCatalog.terrain(id: item.terrainID)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(AppLocalization.text("库存")).font(.headline)
                Spacer()
                Button(AppLocalization.text("去祈愿"), action: openWishes).buttonStyle(.borderless)
            }
            Picker("", selection: $category) {
                Text(AppLocalization.text("房屋")).tag(RewardWishCategory.building)
                Text(AppLocalization.text("摆件")).tag(RewardWishCategory.decoration)
                Text(AppLocalization.text("地皮")).tag(RewardWishCategory.terrain)
            }
            .pickerStyle(.segmented)

            ScrollView {
                if category == .terrain {
                    terrainGrid
                } else {
                    assetGrid
                }
            }

            Text(category == .terrain ? AppLocalization.text("选择后点击已解锁地皮应用") : AppLocalization.text("选择后点击草坪放置；右键已放置物可收回"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
        .onChange(of: category) { _ in
            selectedAssetID = nil
            selectedTerrainID = nil
        }
    }

    private var assetGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(assets) { asset in
                let selected = selectedAssetID == asset.id
                Button {
                    selectedAssetID = asset.id
                    selectedTerrainID = nil
                } label: {
                    VStack(spacing: 2) {
                        RewardAssetSprite(asset: asset).frame(width: 76, height: 66)
                        Text(asset.name).font(.caption2).lineLimit(1)
                        Text(AppLocalization.format("占地 %@", asset.footprint.title))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("×\(store.availableRewardAssetCount(catalogID: asset.id))")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .background(selected ? asset.rarity.color.opacity(0.16) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? asset.rarity.color : Color.clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.format(
                    "%@，占地 %@，剩余 %d 个",
                    asset.name,
                    asset.footprint.title,
                    store.availableRewardAssetCount(catalogID: asset.id)
                ))
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .overlay {
            if assets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "shippingbox").font(.title2).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(AppLocalization.text("库存为空")).foregroundStyle(.secondary)
                }
                .padding(.top, 50)
            }
        }
    }

    private var terrainGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(terrains) { terrain in
                let selected = selectedTerrainID == terrain.id
                Button {
                    selectedTerrainID = terrain.id
                    selectedAssetID = nil
                } label: {
                    VStack(spacing: 4) {
                        RewardTerrainThumbnail(terrain: terrain).frame(height: 62)
                        Text(terrain.name).font(.caption2).lineLimit(1)
                        Text("×\(store.availableTerrainCount(terrainID: terrain.id))")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .background(selected ? AppTheme.teal.opacity(0.16) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? AppTheme.teal : Color.clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.format(
                    "地皮 %@，剩余 %d 个",
                    terrain.name,
                    store.availableTerrainCount(terrainID: terrain.id)
                ))
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
    }
}

private struct RewardWishPoolsView: View {
    @EnvironmentObject private var store: PaperStore
    let resultAction: ([RewardAssetDefinition], RewardTerrainDefinition?) -> Void
    @State private var category: RewardWishCategory = .building

    private var pools: [RewardPoolDefinition] {
        category == .building ? RewardCatalog.buildingPools : RewardCatalog.decorationPools
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Picker("", selection: $category) {
                        ForEach(RewardWishCategory.allCases) { option in Text(option.title).tag(option) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 470)
                    Spacer()
                    Text(AppLocalization.text("每个房屋池与摆件池各含 240 种藏品"))
                        .font(.caption).foregroundStyle(.secondary)
                }

                if category == .terrain {
                    terrainPool
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(pools) { pool in RewardPoolCard(pool: pool, resultAction: resultAction) }
                    }
                }

                RewardRulesCard()
            }
            .frame(maxWidth: 1050)
            .padding(.bottom, 12)
        }
    }

    private var terrainPool: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(LinearGradient(colors: [Color.cyan.opacity(0.22), Color.green.opacity(0.20)], startPoint: .topLeading, endPoint: .bottomTrailing))
                HStack(spacing: 8) {
                    ForEach(RewardCatalog.terrains.filter { $0.variant == 0 }.prefix(4)) { terrain in
                        RewardTerrainThumbnail(terrain: terrain).frame(width: 92, height: 74)
                    }
                }
            }
            .frame(height: 180)

            VStack(alignment: .leading, spacing: 10) {
                Label(AppLocalization.text("自然奇境"), systemImage: "mountain.2.fill").font(.title3.weight(.semibold))
                Text(AppLocalization.text("雪山、湖泊、森林、沙漠等 72 种特殊地皮，全部等概率，无稀有度。"))
                    .font(.callout).foregroundStyle(.secondary)
                Text(AppLocalization.text("相同湖泊会自动连成完整水面；不同地形的过渡带只绘制在特殊地皮一侧。"))
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    resultAction([], store.drawSpecialTerrain())
                } label: {
                    Label(AppLocalization.text("100 金币祈愿一次"), systemImage: "dollarsign.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.rewardCity.coins < RewardCatalog.terrainDrawCost)
            }
            .frame(width: 330, alignment: .leading)
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
    }
}

private struct RewardPoolCard: View {
    @EnvironmentObject private var store: PaperStore
    let pool: RewardPoolDefinition
    let resultAction: ([RewardAssetDefinition], RewardTerrainDefinition?) -> Void

    private var ticketCount: Int {
        pool.kind == .building ? store.rewardCity.buildingTickets : store.rewardCity.decorationTickets
    }

    private var preview: RewardAssetDefinition? {
        RewardCatalog.assets(poolID: pool.id, rarity: .mythic).first
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.08))
                if let preview { RewardAssetSprite(asset: preview).padding(8) }
            }
            .frame(width: 138, height: 138)

            VStack(alignment: .leading, spacing: 7) {
                Label(pool.title, systemImage: pool.symbol).font(.headline)
                Text(pool.subtitle).font(.caption).foregroundStyle(.secondary)
                Text(AppLocalization.text("240 种 · 五档稀有度")).font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button(AppLocalization.text("祈愿 1 次")) { resultAction(store.drawRewards(poolID: pool.id, count: 1), nil) }
                        .disabled(ticketCount < 1)
                    Button(AppLocalization.text("祈愿 10 次")) { resultAction(store.drawRewards(poolID: pool.id, count: 10), nil) }
                        .buttonStyle(.borderedProminent)
                        .disabled(ticketCount < 10)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
    }
}

private struct RewardRulesCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(AppLocalization.text("奖励规则"), systemImage: "gift.fill").font(.headline)
            Text(AppLocalization.text("每新增 1 张证书获得 1 张摆件券。每新增 1 项成果：毕业论文 10 张房屋券、期刊论文 5 张、会议论文 3 张，其余成果 1 张。"))
            Text(AppLocalization.text("祈愿含普通、稀有、史诗、传说、神话五档；越稀有的房屋越豪华、金币产出越高。连续 10 次至少获得稀有，80 次内必得传说或神话。"))
            Text(AppLocalization.text("建筑离线产出最多累计 72 小时；特殊地皮每次消耗 100 金币且不设稀有度。"))
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
    }
}

private struct RewardDrawResultsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let assets: [RewardAssetDefinition]
    let terrain: RewardTerrainDefinition?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLocalization.text("祈愿结果")).font(.title2.weight(.semibold))
                    Text(AppLocalization.text("藏品已自动放入库存")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(AppLocalization.text("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }

            if let terrain {
                VStack(spacing: 10) {
                    RewardTerrainThumbnail(terrain: terrain).frame(width: 220, height: 150)
                    Text(terrain.name).font(.headline)
                    Text(AppLocalization.text("特殊地皮 · 无稀有度")).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 12) {
                        ForEach(assets) { asset in
                            VStack(spacing: 6) {
                                RewardAssetSprite(asset: asset).frame(width: 112, height: 100)
                                Text(asset.name).font(.caption).lineLimit(1)
                                Text(AppLocalization.format("占地 %@", asset.footprint.title))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(asset.rarity.title).font(.caption2.weight(.semibold)).foregroundStyle(asset.rarity.color)
                            }
                            .padding(10)
                            .background(asset.rarity.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: assets.count > 1 ? 720 : 380, height: assets.count > 1 ? 530 : 360)
    }
}

struct RewardAssetSprite: View {
    let asset: RewardAssetDefinition

    var body: some View {
        RewardModelPreview(asset: asset)
        .shadow(color: asset.rarity.color.opacity(0.24), radius: asset.rarity == .mythic ? 8 : 2, y: 2)
        // 3D 缩略图对读屏只是装饰，名称/数量文本始终伴随出现
        .accessibilityHidden(true)
    }
}

private struct RewardTerrainThumbnail: View {
    let terrain: RewardTerrainDefinition
    var body: some View {
        Image(nsImage: RewardTerrainArt.thumbnail(terrain))
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.35)))
            // 地皮缩略图对读屏只是装饰，名称文本始终伴随出现
            .accessibilityHidden(true)
    }
}
