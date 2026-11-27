from datetime import datetime, timedelta, timezone
from random import Random

import pytest

from gaoyanjiu.errors import AppError
from gaoyanjiu.library import Library, empty_library
from gaoyanjiu.reward import asset_by_id, footprint, placement_anchor
from gaoyanjiu.store import ResearchStore
from gaoyanjiu.timeutil import format_iso


NOW = datetime(2026, 11, 20, 12, tzinfo=timezone.utc)


def city_store(tmp_path, inventory, coins=0):
    library = Library(tmp_path).open()
    library.create_empty()
    city = empty_library()["rewardCity"]
    city.update(coins=coins, inventory=[{"catalogID": catalog_id, "count": count} for catalog_id, count in inventory])
    library.data["rewardCity"] = city
    library.save()
    return ResearchStore(library, rng=Random(7), clock=lambda: NOW)


def test_plot_subdivision_placement_move_and_return(tmp_path):
    cinema = "building-campus-002"
    stool = "decoration-campus-002"
    store = city_store(tmp_path, [(cinema, 2), (stool, 1)])
    assert footprint(asset_by_id(cinema), 0) == (3, 2)
    assert footprint(asset_by_id(cinema), 1) == (2, 3)
    placement = store.reward_place(cinema, anchor_row=8, anchor_column=8, rotation=0)
    assert placement_anchor(placement) == (7, 6)
    decoration = store.reward_place(stool, anchor_row=6, anchor_column=8, rotation=0)
    assert placement_anchor(decoration) == (6, 8)
    with pytest.raises(AppError) as error:
        store.reward_place(cinema, anchor_row=6, anchor_column=8)
    assert error.value.code == "plot_occupied"
    moved = store.reward_move(placement["id"], 8, 11)
    assert placement_anchor(moved) == (7, 9)
    rotated = store.reward_rotate(placement["id"])
    assert placement_anchor(rotated) == (6, 9)
    assert rotated["rotationQuarterTurns"] == 1
    store.reward_remove(placement["id"])
    data = store.reward_view()
    assert [item["id"] for item in data["placements"]] == [decoration["id"]]
    assert data["inventory"][0]["available"] == 2


def test_terrain_swap_and_negative_plot_placement(tmp_path):
    decoration = "decoration-campus-002"
    cinema = "building-campus-002"
    store = city_store(tmp_path, [(decoration, 1), (cinema, 1)], coins=300)
    city = store.library.data["rewardCity"]
    city["unlockedPlotIDs"].append("0:0")
    city["terrainInventory"] = [
        {"terrainID": "terrain-lake-01", "count": 1},
        {"terrainID": "terrain-desert-01", "count": 1},
    ]
    store.reward_purchase("-1:-1")
    store.reward_apply_terrain("terrain-lake-01", "-1:-1")
    store.reward_apply_terrain("terrain-desert-01", "0:0")
    with pytest.raises(AppError) as error:
        store.reward_place(cinema, anchor_row=-2, anchor_column=-1)
    assert error.value.code == "terrain_building"
    placed = store.reward_place(decoration, anchor_row=-2, anchor_column=-1)
    assert placement_anchor(placed) == (-2, -1)
    store.reward_move_terrain("-1:-1", "0:0")
    assert city["plotTerrains"]["0:0"] == "terrain-lake-01"
    assert city["plotTerrains"]["-1:-1"] == "terrain-desert-01"
    store.reward_clear_terrain("-1:-1")
    assert city["plotTerrains"] == {"0:0": "terrain-lake-01"}
    store.reward_remove(placed["id"])
    built = store.reward_place(cinema, anchor_row=-2, anchor_column=-1)
    assert placement_anchor(built) == (-2, -3)


def test_legacy_windows_plot_fields_render_without_rewriting_history(tmp_path):
    building = "building-campus-001"
    store = city_store(tmp_path, [(building, 1)])
    city = store.library.data["rewardCity"]
    historical = {
        "id": "previous-windows", "catalogID": building, "x": 609, "y": 330, "zIndex": 5,
        "placedAt": "2026-11-15T00:00:00Z", "anchorRow": 2, "anchorColumn": 3, "rotationQuarterTurns": 0,
        "oldExtension": {"someField": True},
    }
    city["placements"].append(historical)
    city["highestZIndex"] = 5
    city["lastCoinCollectionAt"] = format_iso(NOW - timedelta(hours=50))
    store.library.save()
    before = store.library.path.read_bytes()
    result = store.reward_view()
    assert placement_anchor(historical) == (7, 10)
    assert result["placements"][0]["anchorColumn"] == 10
    assert result["pendingCoins"] == 2.5
    assert store.library.path.read_bytes() == before
    moved = store.reward_move(historical["id"], 7, 13)
    assert placement_anchor(moved) == (7, 13)
    assert moved["oldExtension"] == {"someField": True}
    assert city["coins"] == 2.5
    assert store.reward_view()["pendingCoins"] == 0
