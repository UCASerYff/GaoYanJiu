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
PLOT_COST = 100
TERRAIN_COST = 100.0
COIN_CAP_SECONDS = 72 * 3600


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
    if kind == "building":
        style = (sequence // 10 + (5 if "future" in pool_id else 2 if "royal" in pool_id else 0)) % 6
        use = (sequence - 1) % 10
        architectural = f"{BUILDING_STYLES[style]}·{BUILDING_USES[use]}"
    else:
        architectural = DECOR[(sequence - 1) % 12]
    return {
        "id": f"{pool_id}-{sequence:03d}",
        "poolID": pool_id,
        "kind": kind,
        "rarity": rarity,
        "sequence": sequence,
        "architecturalName": architectural,
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
    return f"{asset['architecturalName']} · {rarity} {asset['sequence']:03d}"


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
    gained = pending_coins(city, now)
    city["coins"] = round(float(city.get("coins") or 0) + gained, 4)
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
    city["coins"] = round(float(city["coins"]) - PLOT_COST, 4)
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
    city["coins"] = round(float(city["coins"]) - TERRAIN_COST, 4)
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


def place_asset(library: dict, catalog_id: str, plot_id: str, now: datetime, placement_id: str) -> dict:
    city = ensure_city(library)
    asset = asset_by_id(catalog_id)
    parts = _plot_parts(plot_id)
    if asset is None or parts is None:
        raise AppError("invalid_field")
    if plot_id not in city["unlockedPlotIDs"]:
        raise AppError("invalid_plot")
    if any(item.get("anchorRow") == parts[0] and item.get("anchorColumn") == parts[1] for item in city["placements"]):
        raise AppError("plot_occupied")
    if available_asset_count(city, catalog_id) <= 0:
        raise AppError("insufficient_tickets")
    city["highestZIndex"] = int(city.get("highestZIndex") or 0) + 1
    placement = {
        "id": placement_id,
        "catalogID": catalog_id,
        "x": parts[1] * 174 + 87,
        "y": parts[0] * 132 + 66,
        "zIndex": city["highestZIndex"],
        "placedAt": format_iso(now),
        "anchorRow": parts[0],
        "anchorColumn": parts[1],
        "rotationQuarterTurns": 0,
    }
    city["placements"].append(placement)
    return placement


def remove_placement(library: dict, placement_id: str) -> None:
    city = ensure_city(library)
    before = len(city["placements"])
    city["placements"] = [item for item in city["placements"] if item.get("id") != placement_id]
    if len(city["placements"]) == before:
        raise AppError("not_found", 404)


def apply_terrain(library: dict, terrain_id: str, plot_id: str) -> None:
    city = ensure_city(library)
    if terrain_by_id(terrain_id) is None or plot_id not in city["unlockedPlotIDs"]:
        raise AppError("invalid_field")
    current = (city.get("plotTerrains") or {}).get(plot_id)
    if current != terrain_id and available_terrain_count(city, terrain_id) <= 0:
        raise AppError("insufficient_coins")
    city["plotTerrains"][plot_id] = terrain_id


def clear_terrain(library: dict, plot_id: str) -> None:
    city = ensure_city(library)
    if plot_id not in (city.get("plotTerrains") or {}):
        raise AppError("not_found", 404)
    del city["plotTerrains"][plot_id]


def follow_up_cutoff(now: datetime, days: int) -> datetime:
    return now - timedelta(days=days)
