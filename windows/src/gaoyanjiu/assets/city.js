(function () {
"use strict";

const i18n = (pair, english) => pair[english ? 1 : 0];
const poolNames = {
  "building-campus": ["学舍、图书馆与学院建筑", "Academic houses, libraries and colleges"],
  "building-garden": ["草木环绕的温暖居所", "Welcoming homes surrounded by greenery"],
  "building-future": ["实验室、观测站与研究塔", "Laboratories, observatories and research towers"],
  "building-royal": ["宫殿、城堡与纪念建筑", "Palaces, castles and memorial architecture"],
  "decoration-campus": ["长椅、路灯与学术陈设", "Benches, street lamps and academic ornaments"],
  "decoration-nature": ["花坛、绿篱、水景与树木", "Flowerbeds, hedges, water features and trees"],
  "decoration-discovery": ["仪器、天文与科学雕塑", "Instruments, astronomy and scientific sculptures"],
  "decoration-ceremony": ["纪念碑、华亭与典礼景观", "Monuments, pavilions and ceremonial landscapes"],
};
const terrainNames = {
  lake: ["湖泊", "Lake"], forest: ["森林", "Forest"], desert: ["沙漠", "Desert"], snowMountain: ["雪山", "Snow mountain"],
  wetland: ["湿地", "Wetland"], volcanic: ["火山地", "Volcanic land"], flowerMeadow: ["花海", "Flower meadow"],
  crystalField: ["晶石原野", "Crystal field"],
};
const rarityNames = {
  common: ["普通", "Common"], rare: ["稀有", "Rare"], epic: ["史诗", "Epic"],
  legendary: ["传说", "Legendary"], mythic: ["神话", "Mythic"],
};

const camera = {yaw: 45, elevation: Math.atan2(24, 23) * 180 / Math.PI, x: 10.5, z: 10.5, zoom: 1, initialized: false};
let rememberedInventory = false;

function node(tag, className, ...children) {
  const result = document.createElement(tag);
  if (className) result.className = className;
  result.append(...children.filter((child) => child !== null && child !== undefined));
  return result;
}

function cityButton(label, callback, {primary = false, disabled = false, symbol = null} = {}) {
  const button = node("button", primary ? "city-button city-primary" : "city-button", symbol || label);
  button.type = "button";
  button.disabled = disabled;
  if (symbol) {
    button.title = label;
    button.setAttribute("aria-label", label);
  }
  button.addEventListener("click", callback);
  return button;
}

function option(value, title) {
  const result = node("option", "", title);
  result.value = value;
  return result;
}

function localizedAsset(asset, english) {
  const title = english ? asset.architecturalNameEn : asset.architecturalName;
  const rarity = i18n(rarityNames[asset.rarity], english);
  return title + " · " + rarity + " " + String(asset.sequence).padStart(3, "0");
}

function rewardCanvas(width, height) {
  const canvas = node("canvas", "city-thumbnail");
  canvas.setAttribute("aria-hidden", "true");
  canvas.width = width;
  canvas.height = height;
  canvas.style.width = width + "px";
  canvas.style.height = height + "px";
  return canvas;
}

function renderRewardCity({data, request, language, onUpdate}) {
  const english = language === "en";
  const text = (zh, en) => i18n([zh, en], english);
  const locality = (kind, variant) => i18n(terrainNames[kind], english) + " " + String(variant + 1).padStart(2, "0");
  const world = window.rewardCityPreview;
  let mode = "city";
  let wishKind = "building";
  let showRules = false;
  let tab = "building";
  let showInventory = rememberedInventory;
  let query = "";
  let catalogueSelection = null;
  let terrainSelection = null;
  let placementID = null;
  let terrainPlotID = null;
  let rotation = 0;
  let moving = false;
  let busy = false;
  let scene;
  let cursorPlot = "";
  let cursorCell = "1:1";
  let canvas;
  let sceneToolbar;
  let selectionPanel;
  let plotSummary;
  let income;
  let inventory;
  let resources;
  let choosePlot;
  let chooseCell;
  let contextMenu;

  const root = node("section", "reward-city");
  const toolbar = node("div", "city-toolbar");
  const status = node("p", "city-status");
  status.setAttribute("role", "status");
  status.hidden = true;
  const content = node("div", "city-content");
  root.append(toolbar, status, content);

  const activeAsset = () => data.inventory.find(({catalogID}) => catalogID === catalogueSelection)?.asset;
  const activePlacement = () => data.placements.find(({id}) => id === placementID);
  const coins = () => Number(data.coins || 0);
  const pending = () => Number(data.pendingCoins || 0);
  const plotByID = (plotID) => data.plots.find((plot) => plot.id === plotID);
  const number = new Intl.NumberFormat(english ? "en-US" : "zh-CN", {maximumFractionDigits: 2});
  const clear = () => { catalogueSelection = null; terrainSelection = null; placementID = null; terrainPlotID = null; rotation = 0; moving = false; };

  function statusMessage(message, failure = false) {
    status.textContent = message;
    status.hidden = !message;
    status.dataset.kind = failure ? "error" : "update";
  }

  async function perform(action, body = {}, after) {
    if (busy) return;
    busy = true;
    statusMessage(text("正在更新研究城…", "Updating Research City…"));
    root.setAttribute("aria-busy", "true");
    try {
      const result = await request("/api/reward/" + action, {
        method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(body),
      });
      data = await request("/api/reward");
      if (onUpdate) onUpdate(data);
      statusMessage("");
      if (after) after(result);
      updateView();
      return result;
    } catch (error) {
      statusMessage(error.message || text("研究城操作未完成。", "The city action could not be completed."), true);
      return null;
    } finally {
      busy = false;
      root.removeAttribute("aria-busy");
    }
  }

  function groups(tabs, selected, makeSelection, label) {
    const element = node("div", "city-segment");
    element.setAttribute("role", "group");
    element.setAttribute("aria-label", label);
    tabs.forEach(([key, label]) => {
      const button = cityButton(label, () => {
        const focused = document.activeElement === button;
        makeSelection(key);
        if (focused) root.querySelector('[data-city-tab="' + key + '"]')?.focus({preventScroll: true});
      });
      button.dataset.cityTab = key;
      button.setAttribute("aria-pressed", String(key === selected));
      element.append(button);
    });
    return element;
  }

  function resourcesBar() {
    const balance = (label, value) => node("span", "city-balance", node("strong", "", number.format(value)), label);
    resources.replaceChildren(
      balance(text("金币", "Coins"), coins()),
      balance(text("房屋券", "Building tickets"), data.buildingTickets || 0),
      balance(text("摆件券", "Decor tickets"), data.decorationTickets || 0),
    );
  }

  function switchMode(value) {
    if (mode === value) return;
    mode = value;
    render();
  }

  function purchase(plotID) {
    if (coins() < 100) {
      statusMessage(text("金币不足，购买地皮需要 100 金币。", "Buying a plot costs 100 coins."), true);
      return;
    }
    void perform("purchase", {plotID}, () => statusMessage(text("已解锁这块地皮。", "The plot is unlocked.")));
  }

  function openContext({cell, placement}, x, y) {
    contextMenu?.remove();
    if (busy || (!placement && !cell?.plot.terrain)) return;
    clear();
    placementID = placement?.id || null;
    terrainPlotID = !placement && cell.plot.terrain ? cell.plot.id : null;
    updateSelection();
    const menu = node("div", "city-context");
    contextMenu = menu;
    menu.setAttribute("role", "group");
    menu.setAttribute("aria-label", text("研究城动作", "Research city actions"));
    const add = (label, action) => menu.append(cityButton(label, () => { menu.remove(); action(); }));
    if (placementID) {
      add(text("收回背包", "Return to inventory"), () => { void perform("remove", {placementID}, clear); });
      add(text("旋转", "Rotate"), () => { void perform("rotate", {placementID}); });
    } else {
      add(text("收回地皮", "Return terrain"), () => { void perform("terrain/clear", {plotID: terrainPlotID}, clear); });
    }
    menu.addEventListener("keydown", (event) => {
      if (event.key === "Escape") { menu.remove(); canvas.focus({preventScroll: true}); }
    });
    menu.addEventListener("focusout", (event) => {
      if (!menu.contains(event.relatedTarget)) queueMicrotask(() => menu.remove());
    });
    root.append(menu);
    menu.style.left = Math.max(0, Math.min(x, innerWidth - menu.offsetWidth - 6)) + "px";
    menu.style.top = Math.max(0, Math.min(y, innerHeight - menu.offsetHeight - 6)) + "px";
    menu.querySelector("button").focus();
  }

  function activate({cell, placement}) {
    if (busy) return;
    if (cell?.plot.frontier) {
      purchase(cell.plot.id);
      return;
    }
    if (cell?.plot.unlocked) {
      if (catalogueSelection) {
        void perform("place", {catalogID: catalogueSelection, anchorRow: cell.row,
          anchorColumn: cell.column, rotationQuarterTurns: rotation}, () => {
          const chosen = data.inventory.find(({catalogID}) => catalogID === catalogueSelection);
          if (!chosen?.available) clear();
        });
        return;
      }
      if (terrainSelection) {
        void perform("terrain/apply", {terrainID: terrainSelection, plotID: cell.plot.id}, () => clear());
        return;
      }
      if (moving) {
        if (placementID) moveBuilding(activePlacement(), cell);
        else if (terrainPlotID) moveTerrain(terrainPlotID, cell.plot.id);
        return;
      }
    }
    placementID = placement?.id || null;
    terrainPlotID = !placement && cell?.plot.terrain ? cell.plot.id : null;
    updateSelection();
  }

  function moveBuilding(placement, cell) {
    if (!placement) return;
    void perform("move", {placementID: placement.id, anchorRow: cell.row, anchorColumn: cell.column}, () => {
      moving = false;
      placementID = placement.id;
    });
  }

  function moveTerrain(source, destination) {
    if (source === destination) { moving = false; updateSelection(); return; }
    void perform("terrain/move", {sourcePlotID: source, destinationPlotID: destination}, () => {
      moving = false;
      terrainPlotID = destination;
    });
  }

  function possible(asset, row, column, turns, excluded) {
    const plotID = world.plotForCell(row, column);
    if (asset.kind === "building" && plotByID(plotID)?.terrain) return false;
    const [width, depth] = world.dimensions(asset, turns);
    return !data.placements.some((placed) => {
      if (placed.id === excluded || !placed.asset) return false;
      const [otherWidth, otherDepth] = world.dimensions(placed.asset, placed.rotationQuarterTurns || 0);
      return row < placed.anchorRow + otherDepth && row + depth > placed.anchorRow
        && column < placed.anchorColumn + otherWidth && column + width > placed.anchorColumn;
    });
  }

  function selectionHint() {
    if (moving) return text("选择新的地皮或小格完成移动。", "Choose a destination plot or cell to move the selection.");
    const asset = activeAsset();
    if (asset) {
      const footprint = world.dimensions(asset, rotation).join("×");
      const name = localizedAsset(asset, english);
      return text("已选择“" + name + "” · 占地 " + footprint + "，点击小格放置",
        "Selected " + name + " · " + footprint + " footprint. Choose a cell.");
    }
    if (terrainSelection) {
      const chosen = data.terrains.find(({terrainID}) => terrainID === terrainSelection);
      if (chosen) return text("已选择“" + locality(chosen.kind, chosen.variant) + "”，点击地皮应用",
        "Selected " + locality(chosen.kind, chosen.variant) + ". Choose a plot.");
    }
    if (placementID) return activePlacement()?.name || "";
    if (terrainPlotID) return text("已选择特殊地皮，可拖动或收回。", "Special terrain selected. Drag or return it to inventory.");
    return text("点击场景中的建筑或地皮，可查看和调整摆放。", "Select a building or plot to see placement actions.");
  }

  function preserveFocus(container, update) {
    const key = container.contains(document.activeElement) ? document.activeElement.dataset.cityFocus : "";
    update();
    if (!key) return;
    const next = [...container.querySelectorAll("[data-city-focus]")].find((control) => control.dataset.cityFocus === key);
    (next || canvas)?.focus({preventScroll: true});
  }

  function namedButton(key, label, callback, options) {
    const button = cityButton(label, callback, options);
    button.dataset.cityFocus = key;
    return button;
  }

  function sceneControls() {
    const actions = node("div", "city-scene-actions");
    if (catalogueSelection || terrainSelection || moving) actions.append(namedButton("cancel",
      text("取消选择", "Clear selection"), () => { clear(); updateSelection(true); }));
    if (catalogueSelection) actions.append(namedButton("rotate-preview", text("旋转待放物", "Rotate item"), () => {
      rotation = (rotation + 1) % 4;
      updateSelection();
    }));
    const move = (key, label) => {
      const control = namedButton(key, moving ? text("取消移动", "Cancel move") : label, () => { moving = !moving; updateSelection(); });
      control.setAttribute("aria-pressed", String(moving));
      return control;
    };
    if (placementID) {
      actions.append(
        namedButton("rotate", text("旋转", "Rotate"), () => { void perform("rotate", {placementID}); }),
        move("move", text("移动", "Move")),
        namedButton("return", text("收回库存", "Return to inventory"), () => { void perform("remove", {placementID}, clear); }),
      );
    }
    if (terrainPlotID) {
      actions.append(
        move("move-terrain", text("移动地皮", "Move terrain")),
        namedButton("return-terrain", text("收回地皮", "Return terrain"), () => { void perform("terrain/clear", {plotID: terrainPlotID}, clear); }),
      );
    }
    preserveFocus(selectionPanel, () => selectionPanel.replaceChildren(
      node("h3", "", text("摆放操作", "Placement")),
      node("p", "city-muted", selectionHint()), actions,
    ));
    const plots = data.plots.filter((plot) => plot.unlocked).length;
    plotSummary.textContent = text(plots + " 块地皮 · " + data.placements.length + " 项摆放",
      plots + " owned plots · " + data.placements.length + " placements");
    const rate = number.format(Number(data.coinRate || 0));
    const amount = number.format(pending());
    preserveFocus(income, () => income.replaceChildren(
      node("h3", "", text("建筑收益", "City income")),
      node("div", "city-income-stat", node("span", "city-muted", text("待收金币", "Pending coins")), node("strong", "", amount)),
      node("small", "city-muted", text("每小时产出 " + rate + " 金币", rate + " coins per hour")),
      namedButton("collect", text("收取金币", "Collect coins"), () => { void perform("collect", {}, ({gained}) => {
        const formatted = number.format(Number(gained || 0));
        statusMessage(text("已收取 " + formatted + " 金币。", "Collected " + formatted + " coins."));
      }); }, {primary: true, disabled: pending() < 0.01}),
    ));
  }

  function sceneCameraControls() {
    const cameraButtons = node("div", "city-control-group",
      cityButton(text("向左旋转视角", "Orbit left"), () => scene.orbit(-45), {symbol: "↶"}),
      cityButton(text("向右旋转视角", "Orbit right"), () => scene.orbit(45), {symbol: "↷"}),
      cityButton(text("缩小", "Zoom out"), () => scene.zoom(0.86), {symbol: "−"}),
      cityButton(text("回到中心", "Center"), () => scene.center(), {symbol: "◎"}),
      cityButton(text("放大", "Zoom in"), () => scene.zoom(1.16), {symbol: "+"}),
    );
    cameraButtons.setAttribute("role", "group");
    cameraButtons.setAttribute("aria-label", text("视角控制", "Camera controls"));
    sceneToolbar.append(node("strong", "", text("场景视口", "City viewport")), cameraButtons);
  }

  function updatePlotOptions() {
    const next = data.plots.map((plot) => {
      const format = plot.id.replace(":", ", ");
      const availability = plot.unlocked ? text("已拥有", "Owned") : text("100 金币", "100 coins");
      return option(plot.id, format + " · " + availability);
    });
    choosePlot.replaceChildren(...next);
    if (!plotByID(cursorPlot)) cursorPlot = (data.plots.find((plot) => plot.unlocked) || data.plots[0])?.id || "";
    choosePlot.value = cursorPlot;
  }

  function accessibleBoard() {
    const disclosure = node("details", "city-accessible");
    const caption = node("summary", "", text("地皮与摆放控件", "Plot and placement controls"));
    choosePlot = node("select");
    choosePlot.setAttribute("aria-label", text("地皮", "Plot"));
    choosePlot.addEventListener("change", () => { cursorPlot = choosePlot.value; });
    chooseCell = node("select", "", ...Array.from({length: 9}, (_, index) => {
      const microRow = Math.floor(index / 3), microCol = index % 3;
      return option(microRow + ":" + microCol, text("小格", "Cell") + " " + (microRow + 1) + ", " + (microCol + 1));
    }));
    chooseCell.setAttribute("aria-label", text("小格", "Cell"));
    chooseCell.value = cursorCell;
    chooseCell.addEventListener("change", () => { cursorCell = chooseCell.value; });
    const place = cityButton(text("确定地皮或小格", "Use plot or cell"), () => {
      const plot = plotByID(choosePlot.value);
      if (!plot) return;
      const [row, col] = plot.id.split(":").map(Number);
      const [subRow, subCol] = chooseCell.value.split(":").map(Number);
      const placement = data.placements.find((item) => {
        if (!item.asset) return false;
        const [width, depth] = world.dimensions(item.asset, item.rotationQuarterTurns || 0);
        const r = row * 3 + subRow, c = col * 3 + subCol;
        return r >= item.anchorRow && r < item.anchorRow + depth
          && c >= item.anchorColumn && c < item.anchorColumn + width;
      });
      activate({cell: {plot, row: row * 3 + subRow, column: col * 3 + subCol}, placement});
    });
    const controls = node("div", "city-control-group", choosePlot, chooseCell, place);
    disclosure.append(caption, controls);
    updatePlotOptions();
    return disclosure;
  }

  function updateSelection(refreshInventory = false) {
    sceneControls();
    scene.draw();
    if (refreshInventory && showInventory) renderInventory();
  }

  function renderInventory() {
    const head = node("div", "city-inventory-head", node("h3", "", text("库存", "Inventory")),
      cityButton(text("前往祈愿", "Open wishes"), () => switchMode("wishes")));
    const categories = [
      ["building", text("房屋", "Buildings")], ["decoration", text("摆件", "Decor")], ["terrain", text("地皮", "Terrain")],
    ];
    const group = groups(categories, tab, (value) => { tab = value; query = ""; clear(); updateSelection(true); },
      text("库存类别", "Inventory categories"));
    const filter = node("input", "city-inventory-filter");
    filter.type = "search";
    filter.placeholder = text("筛选库存", "Filter inventory");
    filter.setAttribute("aria-label", filter.placeholder);
    filter.value = query;
    const grid = node("div", "city-inventory-grid");
    function drawInventory() {
      const cards = [];
      const rows = tab === "terrain" ? data.terrains : data.inventory.filter((row) => row.kind === tab);
      const q = query.trim().toLocaleLowerCase();
      for (const row of rows) {
        if (!row.available) continue;
        const terrain = tab === "terrain";
        const id = terrain ? row.terrainID : row.catalogID;
        const name = terrain ? locality(row.kind, row.variant) : localizedAsset(row.asset, english);
        if (q && !name.toLocaleLowerCase().includes(q) && !id.includes(q)) continue;
        const thumbnail = rewardCanvas(76, 62);
        if (terrain) world.terrain(thumbnail, row.kind, row.variant);
        else world.asset(thumbnail, row.asset);
        const selected = terrain ? terrainSelection === id : catalogueSelection === id;
        const card = node("button", "city-inventory-item", node("span", "city-preview", thumbnail),
          node("span", "city-inventory-label", node("strong", "", name),
            terrain ? null : node("small", "city-muted", text("占地 ", "Footprint ") + world.dimensions(row.asset, 0).join("×"))),
          node("small", "city-quantity", "×" + row.available));
        card.type = "button";
        card.dataset.cityFocus = id;
        card.setAttribute("aria-pressed", String(selected));
        card.addEventListener("click", () => {
          clear();
          if (!selected) {
            if (terrain) terrainSelection = id;
            else catalogueSelection = id;
          }
          drawInventory();
          updateSelection();
        });
        cards.push(card);
      }
      if (!cards.length) cards.push(node("p", "city-muted city-inventory-empty",
        q ? text("没有匹配的藏品", "No matching items") : text("库存为空，可前往祈愿。", "No items in this category yet.")));
      preserveFocus(grid, () => grid.replaceChildren(...cards));
    }
    filter.addEventListener("input", () => { query = filter.value; drawInventory(); });
    filter.dataset.cityFocus = "filter";
    preserveFocus(inventory, () => {
      inventory.replaceChildren(head, group, filter, grid);
      drawInventory();
    });
  }

  function makeScene() {
    sceneToolbar = node("div", "city-scene-tools");
    canvas = node("canvas", "city-scene-canvas");
    canvas.tabIndex = 0;
    canvas.setAttribute("aria-label", text("三维浮空研究城。使用方向键旋转、加减键缩放，或使用下方控件操作建筑和地皮。",
      "3D floating research city. Use arrows to orbit and plus/minus to zoom, or use the controls below to manage plots and items."));
    plotSummary = node("span", "city-plot-summary");
    const caption = node("div", "city-scene-caption", plotSummary, node("small", "city-muted",
      text("左键拖动空地 · 滚轮缩放 · 右键调整视角", "Drag open ground, scroll to zoom, right-drag to orbit")));
    const scenePanel = node("div", "city-scene-panel", sceneToolbar, canvas, caption, accessibleBoard());
    scene = new window.RewardCityScene(canvas, camera, {
      selection: () => ({asset: activeAsset(), rotation, terrain: terrainSelection,
        placement: activePlacement(), selectedTerrain: terrainPlotID}),
      activate, move: moveBuilding, moveTerrain, possible, context: openContext,
    });
    if (!scene.ctx) scenePanel.insertBefore(node("p", "city-fallback city-muted",
      text("当前设备无法绘制场景，可使用地皮控件。", "The 3D scene is unavailable. Use the plot controls below.")), canvas);
    inventory = node("aside", "city-inventory-panel");
    inventory.id = "city-inventory";
    inventory.hidden = !showInventory;
    selectionPanel = node("section", "city-selection-panel");
    income = node("section", "city-income");
    const side = node("aside", "city-inspector", selectionPanel, inventory, income);
    side.setAttribute("aria-label", text("研究城管理", "City management"));
    content.replaceChildren(node("div", "city-body", scenePanel, side));
    scene.setData(data);
    sceneCameraControls();
    sceneControls();
    if (showInventory) renderInventory();
  }

  function resultDialog(result) {
    const draw = result.drawn || [];
    const terrain = result.terrain;
    const results = node("div", "city-results");
    for (const asset of draw) {
      const picture = rewardCanvas(102, 78);
      world.asset(picture, asset);
      const name = english ? asset.architecturalNameEn : asset.architecturalName;
      results.append(node("div", "city-result city-result-" + asset.rarity, node("div", "city-preview", picture), node("span", "", name),
        node("small", "city-muted", text("占地 ", "Footprint ") + world.dimensions(asset, 0).join("×")),
        node("strong", "", i18n(rarityNames[asset.rarity], english) + " " + String(asset.sequence).padStart(3, "0"))));
    }
    if (terrain) {
      const picture = rewardCanvas(102, 78);
      world.terrain(picture, terrain.kind, terrain.variant);
      results.append(node("div", "city-result", picture, node("span", "", locality(terrain.kind, terrain.variant)),
        node("small", "city-muted", text("特殊地皮 · 无稀有度", "Special terrain · No rarity"))));
    }
    const title = text("祈愿结果", "Wish results");
    const dialog = node("dialog", "city-dialog city-result-dialog", node("h3", "", title),
      node("p", "city-muted", text("藏品已自动放入库存", "Items have been added to your inventory.")), results);
    if (results.childElementCount === 1) dialog.classList.add("city-single-result");
    dialog.setAttribute("aria-label", title);
    dialog.append(node("div", "city-dialog-actions", cityButton(text("完成", "Done"), () => dialog.close(), {primary: true})));
    const trigger = document.activeElement?.dataset.cityFocus;
    root.append(dialog);
    dialog.addEventListener("close", () => {
      dialog.remove();
      const button = trigger && [...content.querySelectorAll("[data-city-focus]:enabled")]
        .find((control) => control.dataset.cityFocus === trigger);
      (button || toolbar.querySelector('[aria-pressed="true"]'))?.focus({preventScroll: true});
    }, {once: true});
    dialog.showModal();
  }

  function renderWishes() {
    const category = groups([
      ["building", text("房屋池", "Building pools")], ["decoration", text("摆件池", "Decoration pools")],
      ["terrain", text("特殊地皮池", "Special terrain")],
    ], wishKind, (value) => { wishKind = value; renderWishes(); }, text("祈愿类别", "Wish categories"));
    const copy = {
      building: text("每次消耗 1 张房屋券", "1 building ticket per wish"),
      decoration: text("每次消耗 1 张摆件券", "1 decor ticket per wish"),
      terrain: text("每次消耗 100 金币", "100 coins per wish"),
    };
    const header = node("div", "city-wishes-header", category, node("small", "city-muted", copy[wishKind]));
    const pools = node("div", "city-pools");
    if (wishKind === "terrain") {
      const samples = node("div", "city-terrain-samples");
      for (const kind of ["lake", "forest", "desert", "snowMountain"]) {
        const picture = rewardCanvas(94, 72);
        world.terrain(picture, kind, 0);
        samples.append(picture);
      }
      pools.classList.add("city-single-pool");
      pools.append(node("div", "city-pool city-terrain-pool", samples, node("div", "city-pool-body",
        node("h3", "", text("自然奇境", "Natural wonders")),
        node("p", "city-muted", text("雪山、湖泊、森林、沙漠等 72 种特殊地皮，全部等概率，无稀有度。",
          "72 equally likely terrains including snowy peaks, lakes, forests, and deserts.")),
        node("p", "city-muted", text("相邻湖泊会连成完整水面。", "Neighboring lakes join into a continuous water surface.")),
        namedButton("terrain-wish", text("100 金币祈愿一次", "Wish once for 100 coins"), () => { void perform("terrain", {}, resultDialog); },
          {primary: true, disabled: coins() < 100}))));
    } else {
      const ticketCount = wishKind === "building" ? data.buildingTickets : data.decorationTickets;
      for (const pool of data.pools.filter((item) => item.kind === wishKind)) {
        const picture = rewardCanvas(134, 120);
        world.asset(picture, pool.preview);
        const actions = node("div", "city-control-group",
          namedButton(pool.id + "-single", text("祈愿 1 次", "Wish once"), () => { void perform("draw", {poolID: pool.id, count: 1}, resultDialog); },
            {primary: true, disabled: ticketCount < 1}),
          namedButton(pool.id + "-batch", text("祈愿 10 次", "Wish 10 times"), () => { void perform("draw", {poolID: pool.id, count: 10}, resultDialog); },
            {disabled: ticketCount < 10}));
        pools.append(node("div", "city-pool", node("div", "city-pool-preview", picture), node("div", "city-pool-body",
          node("h3", "", pool.title), node("p", "city-muted", i18n(poolNames[pool.id], english)), actions)));
      }
    }
    const rules = node("details", "city-rules", node("summary", "", text("奖励规则", "Reward rules")),
      node("p", "", text("每个房屋池与摆件池各有 240 种藏品。", "Each building and decor pool contains 240 items.")),
      node("p", "", text("每新增 1 张证书获得 1 张摆件券。每新增 1 项成果：毕业论文 10 张房屋券、期刊论文 5 张、会议论文 3 张，其余成果 1 张。",
        "Each new certificate gives one decoration ticket. A new thesis gives 10 building tickets, a journal article gives five, a conference paper gives three, and other works give one.")),
      node("p", "", text("祈愿含普通、稀有、史诗、传说、神话五档。连续 10 次至少获得稀有，80 次内必得传说或神话。",
        "Wish for common, rare, epic, legendary, or mythic items. The pity counters guarantee rare or better at ten and legendary or better at eighty.")),
      node("p", "", text("建筑离线产出最多累计 72 小时。特殊地皮每次消耗 100 金币。",
        "Buildings accrue up to 72 hours of offline production. A special terrain wish costs 100 coins.")));
    rules.open = showRules;
    rules.addEventListener("toggle", () => { showRules = rules.open; });
    content.replaceChildren(node("div", "city-wishes", header, pools, rules));
  }

  function updateView() {
    resourcesBar();
    if (mode === "city") {
      scene.setData(data);
      sceneControls();
      updatePlotOptions();
      if (showInventory) renderInventory();
    } else renderWishes();
  }

  function render() {
    contextMenu?.remove();
    if (scene) scene.dispose();
    resources = node("div", "city-resources");
    const toggle = cityButton(mode === "city" && showInventory ? text("收起库存", "Hide inventory") : text("展开库存", "Show inventory"), () => {
      showInventory = !showInventory;
      rememberedInventory = showInventory;
      if (mode === "wishes") {
        showInventory = true;
        rememberedInventory = true;
        switchMode("city");
        toolbar.querySelector(".city-toolbar-end > button")?.focus({preventScroll: true});
      }
      else {
        inventory.hidden = !showInventory;
        if (showInventory) renderInventory();
        toggle.textContent = showInventory ? text("收起库存", "Hide inventory") : text("展开库存", "Show inventory");
        toggle.setAttribute("aria-expanded", String(showInventory));
      }
    });
    toggle.setAttribute("aria-expanded", String(mode === "city" && showInventory));
    if (mode === "city") toggle.setAttribute("aria-controls", "city-inventory");
    toolbar.replaceChildren(groups([["city", text("我的城市", "My city")], ["wishes", text("祈愿池", "Wish pools")]], mode, switchMode,
      text("研究城页面", "Research City views")), resources, node("div", "city-toolbar-end", toggle));
    resourcesBar();
    if (mode === "city") makeScene();
    else renderWishes();
  }

  render();
  return root;
}

window.renderRewardCity = renderRewardCity;
}());
