from __future__ import annotations

import random
from datetime import datetime, timedelta

from gaoyanjiu.errors import AppError
from gaoyanjiu.library import default_reward_city
from gaoyanjiu.timeutil import format_iso, parse_iso

POOLS = (
    {"id": "building-campus", "kind": "building", "title": "学术街区", "titleEn": "Campus", "baseHue": -8},
    {"id": "building-garden", "kind": "building", "title": "绿野家园", "titleEn": "Garden", "baseHue": 18},
    {"id": "building-future", "kind": "building", "title": "未来实验城", "titleEn": "Future labs", "baseHue": 150},
    {"id": "building-royal", "kind": "building", "title": "典藏王城", "titleEn": "Royal", "baseHue": 32},
    {"id": "decoration-campus", "kind": "decoration", "title": "校园小景", "titleEn": "Campus objects", "baseHue": -4},
    {"id": "decoration-nature", "kind": "decoration", "title": "自然花园", "titleEn": "Nature", "baseHue": 28},
    {"id": "decoration-discovery", "kind": "decoration", "title": "发现工坊", "titleEn": "Discovery", "baseHue": 145},
    {"id": "decoration-ceremony", "kind": "decoration", "title": "荣誉广场", "titleEn": "Ceremony", "baseHue": 24},
)
RARITY_RATE = {"common": 0.05, "rare": 0.12, "epic": 0.30, "legendary": 0.80, "mythic": 2.00}
RARITY_LABELS = {
    "zh-Hans": {"common": "普通", "rare": "稀有", "epic": "史诗", "legendary": "传说", "mythic": "神话"},
    "en": {"common": "Common", "rare": "Rare", "epic": "Epic", "legendary": "Legendary", "mythic": "Mythic"},
}
TERRAIN_KINDS = (
    "lake",
    "forest",
    "desert",
    "snowMountain",
    "wetland",
    "volcanic",
    "flowerMeadow",
    "crystalField",
)
TERRAIN_LABELS = {
    "zh-Hans": {
        "lake": "湖泊",
        "forest": "森林",
        "desert": "沙漠",
        "snowMountain": "雪山",
        "wetland": "湿地",
        "volcanic": "火山地",
        "flowerMeadow": "花海",
        "crystalField": "晶石原野",
    },
    "en": {
        "lake": "Lake",
        "forest": "Forest",
        "desert": "Desert",
        "snowMountain": "Snow mountain",
        "wetland": "Wetland",
        "volcanic": "Volcanic",
        "flowerMeadow": "Flower meadow",
        "crystalField": "Crystal field",
    },
}
BUILDING_STYLES = ["中式", "西式", "埃及", "中东", "日式", "未来科技"]
BUILDING_USES = ["餐厅", "电影院", "图书馆", "酒店", "城堡", "游乐园", "市集", "博物馆", "住宅", "天文台"]
DECOR = ["花园长椅", "灯笼牌坊", "叠水喷泉", "鲜花推车", "纪念钟塔", "雕塑花园", "竹影庭院", "朱红鸟居", "方尖碑", "棕榈绿洲", "双臂街灯", "太阳能驿站"]
BUILDING_STYLES_EN = ["Chinese", "European", "Egyptian", "Middle Eastern", "Japanese", "Futuristic"]
BUILDING_USES_EN = ["Restaurant", "Cinema", "Library", "Hotel", "Castle", "Amusement park", "Market", "Museum", "Residence", "Observatory"]
DECOR_EN = ["Garden bench", "Lantern gateway", "Tiered fountain", "Flower cart", "Clock tower", "Sculpture garden", "Bamboo garden", "Torii", "Obelisk", "Palm oasis", "Street lights", "Solar station"]
PLOT_COST = 100
TERRAIN_COST = 100.0
COIN_CAP_SECONDS = 72 * 3600
SUBDIVISIONS = 3
LEGACY_PLOT_WIDTH = 174
LEGACY_PLOT_HEIGHT = 132


def _pool(pool_id: str) -> dict | None:
    for pool in POOLS:
        if pool["id"] == pool_id:
            return pool
    return None


def rarity_for_index(index: int) -> str:
    if index < 120:
        return "common"
    if index < 180:
        return "rare"
    if index < 216:
        return "epic"
    if index < 234:
        return "legendary"
    return "mythic"


def asset_record(pool_id: str, index: int) -> dict:
    sequence = index + 1
    rarity = rarity_for_index(index)
    pool = _pool(pool_id)
    kind = pool["kind"] if pool else "building"
    prototype_start, prototype_count, rarity_start = {
        "common": (0, 6, 0), "rare": (6, 6, 120), "epic": (12, 12, 180),
        "legendary": (24, 6, 216), "mythic": (30, 6, 234),
    }[rarity]
    prototype = prototype_start + (index - rarity_start) % prototype_count
    style = (sequence // 10 + (5 if "future" in pool_id else 2 if "royal" in pool_id else 0)) % 6
    use = index % 10
    if kind == "building":
        architectural = f"{BUILDING_STYLES[style]}·{BUILDING_USES[use]}"
        english_name = f"{BUILDING_STYLES_EN[style]}·{BUILDING_USES_EN[use]}"
        width, depth = {
            1: (3, 2), 4: (3, 3), 5: (3, 3), 6: (3, 2), 7: (3, 2), 8: (1, 2),
        }.get(use, (2, 2))
    else:
        architectural = DECOR[index % len(DECOR)]
        english_name = DECOR_EN[index % len(DECOR_EN)]
        width, depth = 1, (2 if prototype % 5 == 0 else 1)
    finish = index % 7
    return {
        "id": f"{pool_id}-{sequence:03d}",
        "poolID": pool_id,
        "kind": kind,
        "rarity": rarity,
        "sequence": sequence,
        "architecturalName": architectural,
        "architecturalNameEn": english_name,
        "architectureStyle": style,
        "architectureUse": use,
        "prototypeIndex": prototype,
        "finishVariant": finish,
        "hueDegrees": (pool["baseHue"] if pool else 0) + (finish - 3) * 9,
        "width": width,
        "depth": depth,
    }


def assets_for(pool_id: str, rarity: str | None = None) -> list[dict]:
    rows = [asset_record(pool_id, index) for index in range(240)]
    if rarity is None:
        return rows
    return [row for row in rows if row["rarity"] == rarity]


def asset_by_id(catalog_id: str) -> dict | None:
    for pool in POOLS:
        prefix = pool["id"] + "-"
        if catalog_id.startswith(prefix):
            suffix = catalog_id[len(prefix) :]
            if suffix.isdigit():
                sequence = int(suffix)
                if 1 <= sequence <= 240:
                    return asset_record(pool["id"], sequence - 1)
    return None


def display_name(asset: dict, language: str = "zh-Hans") -> str:
    rarity = (RARITY_LABELS.get(language) or RARITY_LABELS["zh-Hans"])[asset["rarity"]]
    name_key = "architecturalNameEn" if language == "en" else "architecturalName"
    return f"{asset[name_key]} · {rarity} {asset['sequence']:03d}"


def terrain_catalog() -> list[dict]:
    rows = []
    for kind in TERRAIN_KINDS:
        for variant in range(9):
            rows.append(
                {
                    "id": f"terrain-{kind}-{variant + 1:02d}",
                    "kind": kind,
                    "variant": variant,
                }
            )
    return rows


def terrain_by_id(terrain_id: str) -> dict | None:
    for item in terrain_catalog():
        if item["id"] == terrain_id:
            return item
    return None


def ensure_city(library: dict) -> dict:
    city = library.get("rewardCity")
    if not isinstance(city, dict):
        city = default_reward_city()
        library["rewardCity"] = city
    city.setdefault("coins", 0)
    city.setdefault("buildingTickets", 0)
    city.setdefault("decorationTickets", 0)
    city.setdefault("unlockedPlotIDs", [f"{row}:{column}" for row in range(2, 5) for column in range(2, 5)])
    city.setdefault("inventory", [])
    city.setdefault("placements", [])
    city.setdefault("terrainInventory", [])
    city.setdefault("plotTerrains", {})
    city.setdefault("rewardedWorkIDs", [])
    city.setdefault("rewardedCertificateIDs", [])
    city.setdefault("buildingPity", 0)
    city.setdefault("decorationPity", 0)
    city.setdefault("lastCoinCollectionAt", format_iso(datetime.now().astimezone()))
    city.setdefault("highestZIndex", 0)
    return city


def building_ticket_reward(work_type: str) -> int:
    if work_type == "graduationThesis":
        return 10
    if work_type == "journalArticle":
        return 5
    if work_type == "conferencePaper":
        return 3
    return 1


def grant_work(library: dict, work_id: str, work_type: str) -> None:
    city = ensure_city(library)
    if work_id in city["rewardedWorkIDs"]:
        return
    city["rewardedWorkIDs"].append(work_id)
    city["buildingTickets"] = int(city.get("buildingTickets") or 0) + building_ticket_reward(work_type)


def grant_certificate(library: dict, certificate_id: str) -> None:
    city = ensure_city(library)
    if certificate_id in city["rewardedCertificateIDs"]:
        return
    city["rewardedCertificateIDs"].append(certificate_id)
    city["decorationTickets"] = int(city.get("decorationTickets") or 0) + 1


def _plot_parts(plot_id: str) -> tuple[int, int] | None:
    parts = plot_id.split(":")
    if len(parts) != 2:
        return None
    try:
        return int(parts[0]), int(parts[1])
    except ValueError:
        return None


def neighboring_plots(plot_id: str) -> set[str]:
    parts = _plot_parts(plot_id)
    if parts is None:
        return set()
    row, column = parts
    return {
        f"{row + dr}:{column + dc}"
        for dr in (-1, 0, 1)
        for dc in (-1, 0, 1)
        if not (dr == 0 and dc == 0)
    }


def frontier(unlocked: list[str]) -> list[str]:
    owned = set(unlocked)
    found = set()
    for plot_id in unlocked:
        found.update(neighboring_plots(plot_id))
    return sorted(found - owned)


def coin_rate(city: dict) -> float:
    total = 0.0
    for placement in city.get("placements") or []:
        asset = asset_by_id(str(placement.get("catalogID") or ""))
        if asset and asset["kind"] == "building":
            total += RARITY_RATE[asset["rarity"]]
    return total


def pending_coins(city: dict, now: datetime) -> float:
    try:
        last = parse_iso(str(city.get("lastCoinCollectionAt") or ""))
    except ValueError:
        last = now
    elapsed = min(max(0.0, (now - last).total_seconds()), COIN_CAP_SECONDS)
    return coin_rate(city) * elapsed / 3600


def collect_coins(library: dict, now: datetime) -> float:
    city = ensure_city(library)
    return _bank_coins(city, now)


def _bank_coins(city: dict, now: datetime) -> float:
    gained = pending_coins(city, now)
    city["coins"] = float(city.get("coins") or 0) + gained
    city["lastCoinCollectionAt"] = format_iso(now)
    return gained


def purchase_plot(library: dict, plot_id: str) -> None:
    city = ensure_city(library)
    if _plot_parts(plot_id) is None or plot_id in city["unlockedPlotIDs"]:
        raise AppError("invalid_plot")
    if not neighboring_plots(plot_id).intersection(city["unlockedPlotIDs"]):
        raise AppError("invalid_plot")
    if float(city.get("coins") or 0) < PLOT_COST:
        raise AppError("insufficient_coins")
    city["coins"] = float(city["coins"]) - PLOT_COST
    city["unlockedPlotIDs"].append(plot_id)


def draw_rarity(city: dict, kind: str, roll: int) -> str:
    pity_key = "buildingPity" if kind == "building" else "decorationPity"
    pity = int(city.get(pity_key) or 0)
    if pity >= 79:
        rarity = "legendary"
    elif roll < 20:
        rarity = "mythic"
    elif roll < 170:
        rarity = "legendary"
    elif roll < 800:
        rarity = "epic"
    elif roll < 2600:
        rarity = "rare"
    else:
        rarity = "rare" if pity >= 9 else "common"
    city[pity_key] = 0 if rarity in {"legendary", "mythic"} else pity + 1
    return rarity


def _add_inventory(city: dict, catalog_id: str) -> None:
    for item in city["inventory"]:
        if item.get("catalogID") == catalog_id:
            item["count"] = int(item.get("count") or 0) + 1
            return
    city["inventory"].append({"catalogID": catalog_id, "count": 1})


def available_asset_count(city: dict, catalog_id: str) -> int:
    acquired = 0
    for item in city.get("inventory") or []:
        if item.get("catalogID") == catalog_id:
            acquired = int(item.get("count") or 0)
            break
    placed = sum(1 for item in city.get("placements") or [] if item.get("catalogID") == catalog_id)
    return max(0, acquired - placed)


def draw_rewards(library: dict, pool_id: str, count: int, rng: random.Random) -> list[dict]:
    pool = _pool(pool_id)
    if pool is None or count <= 0:
        raise AppError("invalid_field")
    city = ensure_city(library)
    ticket_key = "buildingTickets" if pool["kind"] == "building" else "decorationTickets"
    if int(city.get(ticket_key) or 0) < count:
        raise AppError("insufficient_tickets")
    city[ticket_key] = int(city[ticket_key]) - count
    drawn = []
    for _ in range(count):
        rarity = draw_rarity(city, pool["kind"], rng.randrange(10_000))
        candidates = assets_for(pool_id, rarity)
        asset = candidates[rng.randrange(len(candidates))]
        _add_inventory(city, asset["id"])
        drawn.append(asset)
    return drawn


def draw_terrain(library: dict, rng: random.Random) -> dict:
    city = ensure_city(library)
    if float(city.get("coins") or 0) < TERRAIN_COST:
        raise AppError("insufficient_coins")
    catalog = terrain_catalog()
    terrain = catalog[rng.randrange(len(catalog))]
    city["coins"] = float(city["coins"]) - TERRAIN_COST
    for item in city["terrainInventory"]:
        if item.get("terrainID") == terrain["id"]:
            item["count"] = int(item.get("count") or 0) + 1
            return terrain
    city["terrainInventory"].append({"terrainID": terrain["id"], "count": 1})
    return terrain


def available_terrain_count(city: dict, terrain_id: str) -> int:
    acquired = 0
    for item in city.get("terrainInventory") or []:
        if item.get("terrainID") == terrain_id:
            acquired = int(item.get("count") or 0)
    used = sum(1 for value in (city.get("plotTerrains") or {}).values() if value == terrain_id)
    return max(0, acquired - used)


def footprint(asset: dict, rotation: int) -> tuple[int, int]:
    width, depth = asset["width"], asset["depth"]
    return (depth, width) if rotation % 2 else (width, depth)


def cell_plot(row: int, column: int) -> str:
    return f"{row // SUBDIVISIONS}:{column // SUBDIVISIONS}"


def _normalized_anchor(asset: dict, row: int, column: int, rotation: int) -> tuple[int, int]:
    width, depth = footprint(asset, rotation)
    base_row = (row // SUBDIVISIONS) * SUBDIVISIONS
    base_column = (column // SUBDIVISIONS) * SUBDIVISIONS
    return min(row, base_row + SUBDIVISIONS - depth), min(column, base_column + SUBDIVISIONS - width)


def placement_anchor(placement: dict) -> tuple[int, int]:
    row, column = placement.get("anchorRow"), placement.get("anchorColumn")
    x, y = placement.get("x") or 0, placement.get("y") or 0
    if row is None or column is None:
        return (
            max(0, min(6, int(y / LEGACY_PLOT_HEIGHT))) * SUBDIVISIONS + 1,
            max(0, min(6, int(x / LEGACY_PLOT_WIDTH))) * SUBDIVISIONS + 1,
        )
    # The first Windows build recorded plot coordinates in Mac's microcell fields.
    if x == (column + 0.5) * LEGACY_PLOT_WIDTH and y == (row + 0.5) * LEGACY_PLOT_HEIGHT:
        row, column = row * SUBDIVISIONS + 1, column * SUBDIVISIONS + 1
        asset = asset_by_id(str(placement.get("catalogID") or ""))
        if asset:
            return _normalized_anchor(asset, row, column, int(placement.get("rotationQuarterTurns") or 0))
    return row, column


def _cells(row: int, column: int, asset: dict, rotation: int) -> set[tuple[int, int]]:
    width, depth = footprint(asset, rotation)
    return {(r, c) for r in range(row, row + depth) for c in range(column, column + width)}


def _occupied_cells(city: dict, excluding: str | None = None) -> set[tuple[int, int]]:
    occupied = set()
    for placed in city["placements"]:
        asset = asset_by_id(str(placed.get("catalogID") or ""))
        if asset and placed.get("id") != excluding:
            row, column = placement_anchor(placed)
            occupied.update(_cells(row, column, asset, int(placed.get("rotationQuarterTurns") or 0)))
    return occupied


def _validate_anchor(
    city: dict, asset: dict, row: int, column: int, rotation: int, excluding: str | None = None,
) -> tuple[int, int]:
    if type(row) is not int or type(column) is not int:
        raise AppError("invalid_plot")
    if type(rotation) is not int:
        raise AppError("invalid_field")
    row, column = _normalized_anchor(asset, row, column, rotation)
    plot_id = cell_plot(row, column)
    if plot_id not in city["unlockedPlotIDs"]:
        raise AppError("invalid_plot")
    if asset["kind"] == "building" and plot_id in city["plotTerrains"]:
        raise AppError("terrain_building")
    if _cells(row, column, asset, rotation) & _occupied_cells(city, excluding):
        raise AppError("plot_occupied")
    return row, column


def _update_placement(placement: dict, row: int, column: int, rotation: int) -> None:
    placement.update(
        anchorRow=row, anchorColumn=column, rotationQuarterTurns=rotation % 4,
        x=(column + 0.5) / SUBDIVISIONS * LEGACY_PLOT_WIDTH,
        y=(row + 0.5) / SUBDIVISIONS * LEGACY_PLOT_HEIGHT,
    )


def _next_z_index(city: dict) -> int:
    city["highestZIndex"] = int(city.get("highestZIndex") or 0) + 1
    return city["highestZIndex"]


def place_asset(
    library: dict, catalog_id: str, plot_id: str | None, now: datetime, placement_id: str,
    *, anchor_row: int | None = None, anchor_column: int | None = None, rotation: int = 0,
) -> dict:
    city = ensure_city(library)
    asset = asset_by_id(catalog_id)
    if asset is None:
        raise AppError("invalid_field")
    if plot_id is not None:
        parts = _plot_parts(plot_id)
        if parts is None:
            raise AppError("invalid_plot")
        anchor_row, anchor_column = (part * SUBDIVISIONS + 1 for part in parts)
    row, column = _validate_anchor(city, asset, anchor_row, anchor_column, rotation)
    if available_asset_count(city, catalog_id) <= 0:
        raise AppError("insufficient_tickets")
    _bank_coins(city, now)
    placement = {
        "id": placement_id,
        "catalogID": catalog_id,
        "zIndex": _next_z_index(city),
        "placedAt": format_iso(now),
    }
    _update_placement(placement, row, column, rotation)
    city["placements"].append(placement)
    return placement


def _placement(city: dict, placement_id: str) -> tuple[dict, dict]:
    for placement in city["placements"]:
        if placement.get("id") == placement_id:
            asset = asset_by_id(str(placement.get("catalogID") or ""))
            if asset is None:
                raise AppError("invalid_field")
            return placement, asset
    raise AppError("not_found", 404)


def move_placement(library: dict, placement_id: str, row: int, column: int, now: datetime) -> dict:
    city = ensure_city(library)
    placement, asset = _placement(city, placement_id)
    rotation = int(placement.get("rotationQuarterTurns") or 0)
    row, column = _validate_anchor(city, asset, row, column, rotation, placement_id)
    _bank_coins(city, now)
    _update_placement(placement, row, column, rotation)
    placement["zIndex"] = _next_z_index(city)
    return placement


def rotate_placement(library: dict, placement_id: str) -> dict:
    city = ensure_city(library)
    placement, asset = _placement(city, placement_id)
    rotation = (int(placement.get("rotationQuarterTurns") or 0) + 1) % 4
    row, column = placement_anchor(placement)
    row, column = _validate_anchor(city, asset, row, column, rotation, placement_id)
    _update_placement(placement, row, column, rotation)
    return placement


def remove_placement(library: dict, placement_id: str, now: datetime | None = None) -> None:
    city = ensure_city(library)
    remaining = [item for item in city["placements"] if item.get("id") != placement_id]
    if len(remaining) == len(city["placements"]):
        raise AppError("not_found", 404)
    _bank_coins(city, now or datetime.now().astimezone())
    city["placements"] = remaining


def _plot_has_building(city: dict, plot_id: str) -> bool:
    for placement in city["placements"]:
        asset = asset_by_id(str(placement.get("catalogID") or ""))
        if asset and asset["kind"] == "building" and cell_plot(*placement_anchor(placement)) == plot_id:
            return True
    return False


def apply_terrain(library: dict, terrain_id: str, plot_id: str) -> None:
    city = ensure_city(library)
    if terrain_by_id(terrain_id) is None or plot_id not in city["unlockedPlotIDs"]:
        raise AppError("invalid_field")
    current = (city.get("plotTerrains") or {}).get(plot_id)
    if current == terrain_id:
        return
    if available_terrain_count(city, terrain_id) <= 0:
        raise AppError("terrain_unavailable")
    if _plot_has_building(city, plot_id):
        raise AppError("terrain_building")
    city["plotTerrains"][plot_id] = terrain_id


def move_terrain(library: dict, source_plot_id: str, destination_plot_id: str) -> None:
    city = ensure_city(library)
    terrains = city["plotTerrains"]
    if source_plot_id == destination_plot_id:
        return
    if source_plot_id not in terrains or destination_plot_id not in city["unlockedPlotIDs"]:
        raise AppError("invalid_plot")
    if _plot_has_building(city, destination_plot_id):
        raise AppError("terrain_building")
    source_terrain = terrains.pop(source_plot_id)
    if destination_plot_id in terrains:
        terrains[source_plot_id] = terrains[destination_plot_id]
    terrains[destination_plot_id] = source_terrain


def clear_terrain(library: dict, plot_id: str) -> None:
    city = ensure_city(library)
    if plot_id not in (city.get("plotTerrains") or {}):
        raise AppError("not_found", 404)
    del city["plotTerrains"][plot_id]


def follow_up_cutoff(now: datetime, days: int) -> datetime:
    return now - timedelta(days=days)
