const token = document.querySelector('meta[name="gao-token"]').content;
const state = { page: "submissions", scope: "all", kind: "experimentData", folder: "", selection: null, language: "zh-Hans" };
const I18N = {
  "zh-Hans": {
    search: "搜索", quit: "退出", createLibrary: "创建我的资料库",
    submissions: "在投管理", works: "成果管理", documents: "资料库", certificates: "证书",
    trash: "回收站", city: "研究城", portals: "投稿门户", history: "历史记录", settings: "设置",
    all: "全部", changed: "状态更新", hidden: "已归档", create: "新建", edit: "编辑", archive: "归档",
    unarchive: "取消归档", remove: "移入回收站", restore: "恢复", purge: "清理超过 30 天", forever: "彻底删除",
    save: "保存", cancel: "取消", follow: "待跟进", open: "打开网站", collect: "收取金币", draw: "抽一次",
    buy: "购买相邻地皮", place: "放置", experimentData: "实验数据", summaryReports: "总结报告",
    importantLiterature: "重要文献", importFile: "导入文件", newFolder: "新建文件夹"
  },
  en: {
    search: "Search", quit: "Quit", createLibrary: "Create my library",
    submissions: "Submissions", works: "Works", documents: "Library", certificates: "Certificates",
    trash: "Trash", city: "Research city", portals: "Portals", history: "History", settings: "Settings",
    all: "All", changed: "Updated", hidden: "Archived", create: "New", edit: "Edit", archive: "Archive",
    unarchive: "Unarchive", remove: "Move to trash", restore: "Restore", purge: "Purge after 30 days", forever: "Delete forever",
    save: "Save", cancel: "Cancel", follow: "Follow up", open: "Open site", collect: "Collect coins", draw: "Draw once",
    buy: "Buy a neighboring plot", place: "Place", experimentData: "Experiments", summaryReports: "Reports",
    importantLiterature: "Literature", importFile: "Import file", newFolder: "New folder"
  }
};
const t = (key) => (I18N[state.language] || I18N["zh-Hans"])[key] || I18N["zh-Hans"][key] || key;
const $ = (id) => document.getElementById(id);

function toast(message) {
  const node = $("toast");
  node.textContent = message;
  node.classList.add("show");
  clearTimeout(toast._timer);
  toast._timer = setTimeout(() => node.classList.remove("show"), 3200);
}

async function api(path, options = {}) {
  const headers = Object.assign({ "X-Gao-Token": token }, options.headers || {});
  const response = await fetch(path, Object.assign({}, options, { headers }));
  const isJson = (response.headers.get("content-type") || "").includes("json");
  const payload = isJson ? await response.json() : null;
  if (!response.ok) throw new Error((payload && payload.message) || "请求没有完成");
  return payload;
}

function applyChrome() {
  document.querySelectorAll("[data-i18n]").forEach((node) => {
    node.textContent = t(node.dataset.i18n);
  });
  document.documentElement.lang = state.language === "en" ? "en" : "zh-CN";
}

function setTheme(appearance) {
  document.body.dataset.theme = appearance || "system";
}

const NAV = ["submissions", "works", "documents", "certificates", "trash", "city", "portals", "history", "settings"];

function renderNav() {
  $("nav").replaceChildren(...NAV.map((page) => {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = t(page);
    if (page === state.page) button.setAttribute("aria-current", "page");
    button.addEventListener("click", () => { state.page = page; state.selection = null; render(); });
    return button;
  }));
}

function field(label, name, value, type = "text") {
  const wrap = document.createElement("label");
  wrap.className = "stack";
  wrap.textContent = label;
  const input = document.createElement(type === "area" ? "textarea" : "input");
  if (type !== "area") input.type = type;
  input.name = name;
  input.value = value || "";
  wrap.append(input);
  return wrap;
}

function selectField(label, name, value, options) {
  const wrap = document.createElement("label");
  wrap.className = "stack";
  wrap.textContent = label;
  const select = document.createElement("select");
  select.name = name;
  options.forEach(([id, text]) => {
    const option = document.createElement("option");
    option.value = id;
    option.textContent = text;
    if (id === (value || "")) option.selected = true;
    select.append(option);
  });
  wrap.append(select);
  return wrap;
}

function openEditor(title, nodes, onSubmit) {
  const dialog = $("editor");
  const form = document.createElement("form");
  form.className = "stack";
  const heading = document.createElement("h2");
  heading.textContent = title;
  const actions = document.createElement("div");
  actions.className = "row";
  const save = document.createElement("button");
  save.className = "primary";
  save.type = "submit";
  save.textContent = t("save");
  const cancel = document.createElement("button");
  cancel.type = "button";
  cancel.textContent = t("cancel");
  cancel.addEventListener("click", () => dialog.close());
  actions.append(save, cancel);
  form.append(heading, ...nodes, actions);
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const data = Object.fromEntries(new FormData(form).entries());
    try {
      await onSubmit(data);
      dialog.close();
      await render();
    } catch (error) {
      toast(error.message);
    }
  });
  dialog.replaceChildren(form);
  dialog.showModal();
}

function rowItem(title, subtitle, ...actions) {
  const row = document.createElement("div");
  row.className = "item";
  const text = document.createElement("div");
  const strong = document.createElement("strong");
  strong.textContent = title || "未命名";
  const span = document.createElement("span");
  span.textContent = subtitle || "";
  text.append(strong, span);
  row.append(text, ...actions);
  return row;
}

function itemButton(title, subtitle, selected, onClick) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "item";
  if (selected) button.setAttribute("aria-selected", "true");
  const strong = document.createElement("strong");
  strong.textContent = title || "未命名";
  const span = document.createElement("span");
  span.textContent = subtitle || "";
  button.append(strong, span);
  button.addEventListener("click", onClick);
  return button;
}

function actionButton(label, className, onClick) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = className || "";
  button.textContent = label;
  button.addEventListener("click", async () => {
    try { await onClick(); await render(); } catch (error) { toast(error.message); }
  });
  return button;
}

function detailBox(rows) {
  const box = document.createElement("div");
  box.className = "detail";
  rows.forEach(([label, value]) => {
    const heading = document.createElement("h3");
    heading.textContent = label;
    const paragraph = document.createElement("p");
    paragraph.textContent = value || "—";
    box.append(heading, paragraph);
  });
  return box;
}

async function pageSubmissions() {
  const data = await api(`/api/papers?scope=${state.scope}`);
  const selected = data.papers.find((paper) => paper.key === state.selection) || data.papers[0];
  if (selected) state.selection = selected.key;
  const head = document.createElement("div");
  head.className = "page-head";
  const title = document.createElement("h1");
  title.textContent = t("submissions");
  const tools = document.createElement("div");
  tools.className = "toolbar";
  ["all", "changed", "hidden"].forEach((scope) => {
    const button = document.createElement("button");
    button.textContent = t(scope);
    button.setAttribute("aria-pressed", String(scope === state.scope));
    button.addEventListener("click", () => { state.scope = scope; state.selection = null; render(); });
    tools.append(button);
  });
  tools.append(actionButton(t("create"), "primary", async () => {
    openEditor(t("create"), [
      field("标题", "title"), field("期刊或会议", "venue"), field("稿号", "manuscriptID"),
      field("状态", "status", "已投稿"), field("状态日期", "statusSince", new Date().toISOString().slice(0, 10), "date"),
      field("投稿网址", "url"), field("备注", "notes", "", "area"),
      selectField("标为状态更新", "flagChanged", "", [["", "否"], ["yes", "是"]])
    ], async (form) => {
      await api("/api/papers", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({
        title: form.title, venue: form.venue, manuscriptID: form.manuscriptID, status: form.status,
        statusSince: form.statusSince, url: form.url, notes: form.notes, flagChanged: form.flagChanged === "yes"
      }) });
    });
  }));
  if (selected) {
    tools.append(actionButton(t("edit"), "", async () => {
      openEditor(t("edit"), [
        field("标题", "title", selected.title), field("期刊或会议", "venue", selected.journal),
        field("稿号", "manuscriptID", selected.manuscriptID), field("状态", "status", selected.status),
        field("状态日期", "statusSince", String(selected.statusSince || "").slice(0, 10), "date"),
        field("投稿网址", "url", selected.url), field("备注", "notes", selected.submissionHistory || "", "area")
      ], async (form) => {
        await api("/api/papers", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({
          key: selected.key, title: form.title, venue: form.venue, manuscriptID: form.manuscriptID,
          status: form.status, statusSince: form.statusSince, url: form.url, notes: form.notes
        }) });
      });
    }));
    tools.append(actionButton(selected.hidden ? t("unarchive") : t("archive"), "", async () => {
      await api("/api/papers/hidden", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ key: selected.key, hidden: !selected.hidden }) });
    }));
    tools.append(actionButton(t("remove"), "danger", async () => {
      await api("/api/papers/trash", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ key: selected.key }) });
      state.selection = null;
    }));
  }
  head.append(title, tools);
  const split = document.createElement("div");
  split.className = "split";
  const list = document.createElement("div");
  list.className = "list";
  data.papers.forEach((paper) => list.append(itemButton(paper.title, `${paper.journal || ""} · ${paper.status || ""}`, paper.key === state.selection, () => {
    state.selection = paper.key; render();
  })));
  const history = (selected && selected.history || []).map((event) => `${event.checkedAt || ""} ${event.status || ""}`).join("\n");
  split.append(list, detailBox(selected ? [
    ["标题", selected.title], ["期刊", selected.journal], ["稿号", selected.manuscriptID],
    ["状态", selected.status], ["来源", selected.site], ["历史", history], ["备注", selected.submissionHistory]
  ] : [["提示", "还没有在投记录"]]));
  return [head, split];
}

async function pageWorks() {
  const data = await api("/api/works");
  const selected = data.works.find((work) => work.id === state.selection) || data.works[0];
  if (selected) state.selection = selected.id;
  const head = document.createElement("div");
  head.className = "page-head";
  const title = document.createElement("h1");
  title.textContent = t("works");
  const tools = document.createElement("div");
  tools.className = "toolbar";
  const types = [["journalArticle", "期刊论文"], ["conferencePaper", "会议论文"], ["graduationThesis", "毕业论文"], ["book", "专著"], ["bookChapter", "书籍章节"], ["patent", "专利"], ["dataset", "数据集"], ["software", "软件成果"], ["other", "其他成果"]];
  tools.append(actionButton(t("create"), "primary", async () => {
    openEditor(t("create"), [
      field("标题", "title"), selectField("类型", "type", "journalArticle", types),
      field("发表载体", "venue"), field("作者", "authors"), field("完成日期", "completedAt", new Date().toISOString().slice(0, 10), "date"),
      field("标识", "identifier"), field("链接", "url"), field("ISSN", "journalISSN"), field("备注", "notes", "", "area")
    ], async (form) => { await api("/api/works", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(form) }); });
  }));
  if (selected) {
    tools.append(actionButton(t("remove"), "danger", async () => {
      await api("/api/works/trash", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id: selected.id }) });
      state.selection = null;
    }));
  }
  head.append(title, tools);
  const cards = document.createElement("div");
  cards.className = "cards";
  const chart = document.createElement("div");
  chart.className = "card";
  chart.style.minHeight = `${data.analytics.chartHeight}px`;
  const max = Math.max(1, ...data.analytics.categories.map((row) => row.count));
  data.analytics.categories.forEach((row) => {
    const line = document.createElement("div");
    line.className = "bar";
    const name = document.createElement("span");
    name.textContent = row.label;
    const track = document.createElement("span");
    const fill = document.createElement("i");
    fill.style.width = `${Math.round(row.count / max * 100)}%`;
    track.append(fill);
    const count = document.createElement("strong");
    count.textContent = String(row.count);
    line.append(name, track, count);
    chart.append(line);
  });
  if (!data.analytics.categories.length) chart.textContent = "还没有成果";
  const authors = document.createElement("div");
  authors.className = "card";
  data.analytics.authorPositions.forEach((row) => {
    const line = document.createElement("p");
    line.textContent = `${row.label} ${row.count}`;
    authors.append(line);
  });
  cards.append(chart, authors);
  const list = document.createElement("div");
  list.className = "list";
  data.works.forEach((work) => list.append(itemButton(work.title, work.venue || work.type, work.id === state.selection, () => {
    state.selection = work.id; render();
  })));
  const split = document.createElement("div");
  split.className = "split";
  split.append(list, detailBox(selected ? [["标题", selected.title], ["类型", selected.type], ["作者", selected.authors], ["载体", selected.venue], ["备注", selected.notes]] : [["提示", "还没有成果"]]));
  return [head, cards, split];
}

async function pageDocuments() {
  const data = await api(`/api/documents?kind=${state.kind}&folder=${encodeURIComponent(state.folder)}`);
  state.folder = data.folderID || "";
  const head = document.createElement("div");
  head.className = "page-head";
  const title = document.createElement("h1");
  title.textContent = t("documents");
  const tools = document.createElement("div");
  tools.className = "toolbar";
  ["experimentData", "summaryReports", "importantLiterature"].forEach((kind) => {
    const button = document.createElement("button");
    button.textContent = t(kind);
    button.setAttribute("aria-pressed", String(kind === state.kind));
    button.addEventListener("click", () => { state.kind = kind; state.folder = ""; render(); });
    tools.append(button);
  });
  tools.append(actionButton(t("newFolder"), "primary", async () => {
    const name = prompt(t("newFolder"));
    if (!name) return;
    const created = await api("/api/documents/folder", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ kind: state.kind, name }) });
    state.folder = created.id;
  }));
  head.append(title, tools);
  const folders = document.createElement("div");
  folders.className = "toolbar";
  data.folders.forEach((folder) => {
    const button = document.createElement("button");
    button.textContent = folder.name;
    button.setAttribute("aria-pressed", String(folder.id === state.folder));
    button.addEventListener("click", () => { state.folder = folder.id; render(); });
    folders.append(button);
  });
  const importer = document.createElement("form");
  importer.className = "toolbar";
  const file = document.createElement("input");
  file.type = "file";
  const path = document.createElement("input");
  path.placeholder = "或粘贴本机路径";
  const submit = document.createElement("button");
  submit.className = "primary";
  submit.type = "submit";
  submit.textContent = t("importFile");
  importer.append(file, path, submit);
  importer.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!state.folder) { toast(state.language === "en" ? "Choose a folder first." : "请先选择资料文件夹。"); return; }
    try {
      if (path.value.trim()) {
        await api("/api/documents/import-path", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ folderID: state.folder, path: path.value.trim() }) });
      } else if (file.files[0]) {
        const form = new FormData();
        form.set("folderID", state.folder);
        form.set("file", file.files[0]);
        await api("/api/documents/import", { method: "POST", body: form });
      }
      await render();
    } catch (error) { toast(error.message); }
  });
  const list = document.createElement("div");
  list.className = "list";
  data.documents.forEach((document) => {
    const remove = actionButton(t("remove"), "danger", async () => {
      await api("/api/documents/trash", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id: document.id }) });
    });
    const link = document.createElement("a");
    link.href = `/api/download?kind=document&owner=${encodeURIComponent(document.folderID)}&name=${encodeURIComponent(document.storedName)}&token=${encodeURIComponent(token)}`;
    link.textContent = "下载";
    list.append(rowItem(document.displayName, document.originalName, link, remove));
  });
  return [head, folders, importer, list];
}

async function pageCertificates() {
  const data = await api("/api/certificates");
  const head = document.createElement("div");
  head.className = "page-head";
  const title = document.createElement("h1");
  title.textContent = t("certificates");
  const tools = document.createElement("div");
  tools.className = "toolbar";
  tools.append(actionButton(t("create"), "primary", async () => {
    openEditor(t("create"), [field("名称", "name"), field("日期", "eventDate", new Date().toISOString().slice(0, 10), "date"), field("标签", "tags")], async (form) => {
      await api("/api/certificates", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name: form.name, eventDate: form.eventDate, tags: form.tags.split(/[,，]/).map((part) => part.trim()).filter(Boolean) }) });
    });
  }));
  head.append(title, tools);
  const list = document.createElement("div");
  list.className = "list";
  data.certificates.forEach((record) => {
    list.append(rowItem(
      record.name,
      `${String(record.eventDate || "").slice(0, 10)} ${(record.tags || []).join(" ")}`,
      actionButton(t("remove"), "danger", async () => {
        await api("/api/certificates/trash", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id: record.id }) });
      })
    ));
  });
  const years = document.createElement("div");
  years.className = "card";
  data.analytics.years.forEach((row) => {
    const line = document.createElement("p");
    line.textContent = `${row.label} · ${row.count}`;
    years.append(line);
  });
  return [head, years, list];
}

async function pageTrash() {
  const data = await api("/api/trash");
  const head = document.createElement("div");
  head.className = "page-head";
  const title = document.createElement("h1");
  title.textContent = t("trash");
  head.append(title, actionButton(t("purge"), "", async () => {
    const result = await api("/api/trash/purge", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
    toast(String(result.removed));
  }));
  const list = document.createElement("div");
  list.className = "list";
  data.items.forEach((item) => {
    list.append(rowItem(
      item.title,
      `${item.kind} · ${item.deletedAt}`,
      actionButton(t("restore"), "primary", async () => {
        await api("/api/trash/restore", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id: item.id }) });
      }),
      actionButton(t("forever"), "danger", async () => {
        await api("/api/trash/delete", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id: item.id }) });
      })
    ));
  });
  return [head, list];
}

async function pageCity() {
  const data = await api("/api/reward");
  const head = document.createElement("div");
  head.className = "page-head";
  const title = document.createElement("h1");
  title.textContent = t("city");
  head.append(title);
  const summary = document.createElement("div");
  summary.className = "card";
  summary.textContent = `金币 ${data.coins} · 待收 ${data.pendingCoins} · 房屋券 ${data.buildingTickets} · 摆件券 ${data.decorationTickets}`;
  const tools = document.createElement("div");
  tools.className = "toolbar";
  tools.append(actionButton(t("collect"), "primary", async () => { await api("/api/reward/collect", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" }); }));
  const pool = document.createElement("select");
  data.pools.forEach((item) => {
    const option = document.createElement("option");
    option.value = item.id;
    option.textContent = item.title;
    pool.append(option);
  });
  tools.append(pool, actionButton(t("draw"), "", async () => {
    await api("/api/reward/draw", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ poolID: pool.value, count: 1 }) });
  }));
  tools.append(actionButton("特殊地皮", "", async () => {
    await api("/api/reward/terrain", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
  }));
  const grid = document.createElement("div");
  grid.className = "city";
  data.plots.forEach((plot) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = plot.unlocked ? "plot owned" : "plot";
    const name = document.createElement("strong");
    name.textContent = plot.placement ? plot.placement.name : plot.id;
    const meta = document.createElement("small");
    meta.textContent = plot.unlocked ? (plot.terrain || "已拥有") : "可购买";
    button.append(name, meta);
    button.addEventListener("click", async () => {
      try {
        if (!plot.unlocked) {
          await api("/api/reward/purchase", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ plotID: plot.id }) });
        } else if (!plot.placement) {
          const available = data.inventory.find((item) => item.available > 0);
          if (!available) { toast("库存里没有可放置的建筑或摆件"); return; }
          await api("/api/reward/place", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ catalogID: available.catalogID, plotID: plot.id }) });
        } else {
          await api("/api/reward/remove", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ placementID: plot.placement.id }) });
        }
        await render();
      } catch (error) { toast(error.message); }
    });
    grid.append(button);
  });
  const inventory = document.createElement("div");
  inventory.className = "card";
  data.inventory.filter((item) => item.available > 0).forEach((item) => {
    const line = document.createElement("p");
    line.textContent = `${item.name} × ${item.available}`;
    inventory.append(line);
  });
  return [head, summary, tools, grid, inventory];
}

async function pagePortals() {
  const publishers = await api("/api/publishers");
  const portals = await api("/api/portals");
  const head = document.createElement("div");
  head.className = "page-head";
  const title = document.createElement("h1");
  title.textContent = t("portals");
  head.append(title, actionButton(t("create"), "primary", async () => {
    openEditor(t("create"), [
      selectField("系统", "publisherID", "springer", publishers.publishers.map((item) => [item.id, item.name]).concat([["custom", "自定义"]])),
      field("名称", "name"), field("网址", "url", "https://"), field("账号", "identity"), field("密码", "password", "", "password")
    ], async (form) => { await api("/api/portals", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(form) }); });
  }));
  const builtIn = document.createElement("div");
  builtIn.className = "list";
  publishers.publishers.forEach((item) => {
    const link = document.createElement("a");
    link.href = item.url;
    link.target = "_blank";
    link.rel = "noreferrer";
    link.className = "item";
    const strong = document.createElement("strong");
    strong.textContent = item.name;
    const span = document.createElement("span");
    span.textContent = item.subtitle;
    link.append(strong, span);
    builtIn.append(link);
  });
  const saved = document.createElement("div");
  saved.className = "list";
  portals.portals.forEach((portal) => {
    const link = document.createElement("a");
    link.href = portal.url;
    link.target = "_blank";
    link.rel = "noreferrer";
    link.textContent = t("open");
    saved.append(rowItem(portal.name, portal.identity || portal.url, link));
  });
  return [head, builtIn, saved];
}

async function pageHistory() {
  const data = await api("/api/history");
  const head = document.createElement("div");
  head.className = "page-head";
  const title = document.createElement("h1");
  title.textContent = t("history");
  head.append(title);
  const note = document.createElement("p");
  note.className = "muted";
  note.textContent = "项目页已在 Mac 版 4.14 移除，科研资金改由搞积蓄管理。这里只读显示历史记录，不会改写。";
  const projects = document.createElement("div");
  projects.className = "list";
  data.projects.forEach((project) => projects.append(itemButton(project.title, "项目", false, () => {})));
  const funding = document.createElement("div");
  funding.className = "list";
  data.fundingRecords.forEach((record) => funding.append(itemButton(record.name, String(record.amount), false, () => {})));
  return [head, note, projects, funding];
}

async function pageSettings() {
  const data = await api("/api/settings");
  const inspect = await api("/api/inspect");
  const head = document.createElement("div");
  head.className = "page-head";
  const title = document.createElement("h1");
  title.textContent = t("settings");
  head.append(title);
  const form = document.createElement("form");
  form.className = "card stack";
  form.append(
    selectField("外观", "appearance", data.settings.appearance, [["system", "跟随系统"], ["light", "浅色"], ["dark", "深色"]]),
    selectField("语言", "language", data.settings.language, [["zh-Hans", "简体中文"], ["en", "English"]]),
    field("待跟进天数", "followUpDays", String(data.settings.followUpDays), "number")
  );
  const save = document.createElement("button");
  save.className = "primary";
  save.type = "submit";
  save.textContent = t("save");
  form.append(save);
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const values = Object.fromEntries(new FormData(form).entries());
    try {
      await api("/api/settings", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({
        appearance: values.appearance, language: values.language, followUpDays: Number(values.followUpDays)
      }) });
      state.language = values.language;
      setTheme(values.appearance);
      applyChrome();
      await render();
    } catch (error) { toast(error.message); }
  });
  const secret = document.createElement("form");
  secret.className = "card stack";
  secret.append(field("EasyScholar Secret Key", "secret", "", "password"));
  const saveKey = document.createElement("button");
  saveKey.className = "primary";
  saveKey.textContent = data.hasEasyScholarKey ? "更新密钥" : "保存密钥";
  secret.append(saveKey);
  secret.addEventListener("submit", async (event) => {
    event.preventDefault();
    const values = Object.fromEntries(new FormData(secret).entries());
    try {
      await api("/api/secrets/easyscholar", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ secret: values.secret }) });
      toast("已保存到本机凭据，没有写入资料库。");
    } catch (error) { toast(error.message); }
  });
  const lookup = document.createElement("form");
  lookup.className = "card stack";
  lookup.append(field("期刊名或 ISSN", "query"));
  const find = document.createElement("button");
  find.textContent = "查询期刊指标";
  lookup.append(find);
  const result = document.createElement("div");
  lookup.append(result);
  lookup.addEventListener("submit", async (event) => {
    event.preventDefault();
    const values = Object.fromEntries(new FormData(lookup).entries());
    try {
      const payload = await api("/api/metrics/lookup", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ query: values.query }) });
      result.replaceChildren();
      payload.metrics.items.forEach((item) => {
        const line = document.createElement("p");
        line.textContent = `${item.label} ${item.value}`;
        result.append(line);
      });
    } catch (error) { toast(error.message); }
  });
  const meta = document.createElement("p");
  meta.className = "muted";
  meta.textContent = `${data.dataDir} · schema ${inspect.schema} · 论文 ${inspect.counts.papers} · 成果 ${inspect.counts.existingWorks} · 证书 ${inspect.counts.certificates}`;
  return [head, form, secret, lookup, meta];
}

async function pageSearch(query) {
  const data = await api(`/api/search?q=${encodeURIComponent(query)}`);
  const head = document.createElement("div");
  head.className = "page-head";
  const title = document.createElement("h1");
  title.textContent = t("search");
  head.append(title);
  const list = document.createElement("div");
  list.className = "list";
  data.papers.forEach((paper) => list.append(itemButton(paper.title, "在投", false, () => {})));
  data.works.forEach((work) => list.append(itemButton(work.title, "成果", false, () => {})));
  data.certificates.forEach((record) => list.append(itemButton(record.name, "证书", false, () => {})));
  data.documents.forEach((document) => list.append(itemButton(document.displayName, "资料", false, () => {})));
  return [head, list];
}

async function render() {
  renderNav();
  applyChrome();
  const main = $("main");
  const query = $("search").value.trim();
  let nodes = [];
  if (query) nodes = await pageSearch(query);
  else if (state.page === "submissions") nodes = await pageSubmissions();
  else if (state.page === "works") nodes = await pageWorks();
  else if (state.page === "documents") nodes = await pageDocuments();
  else if (state.page === "certificates") nodes = await pageCertificates();
  else if (state.page === "trash") nodes = await pageTrash();
  else if (state.page === "city") nodes = await pageCity();
  else if (state.page === "portals") nodes = await pagePortals();
  else if (state.page === "history") nodes = await pageHistory();
  else nodes = await pageSettings();
  main.replaceChildren(...nodes);
}

async function boot() {
  const info = await api("/api/bootstrap");
  state.language = info.settings.language || "zh-Hans";
  setTheme(info.settings.appearance);
  $("brand-version").textContent = `Windows ${info.version} · build ${info.build}`;
  applyChrome();
  if (info.status !== "ready") {
    $("gate").hidden = false;
    $("shell").hidden = true;
    $("gate-text").textContent = info.message;
    $("gate-create").hidden = info.status !== "needs_create";
    return;
  }
  $("gate").hidden = true;
  $("shell").hidden = false;
  if (info.followUps) toast(`${t("follow")} ${info.followUps}`);
  await render();
}

$("gate-create").addEventListener("click", async () => {
  try {
    await api("/api/library/create", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
    await boot();
  } catch (error) { toast(error.message); }
});
$("quit").addEventListener("click", async () => {
  try { await api("/api/shutdown", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" }); } catch (error) { /* 进程即将退出 */ }
});
$("search").addEventListener("change", () => { if (!$("shell").hidden) render().catch((error) => toast(error.message)); });
boot().catch((error) => toast(error.message));
