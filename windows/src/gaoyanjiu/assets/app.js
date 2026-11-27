"use strict";

const $ = (id) => document.getElementById(id);
const token = document.querySelector('meta[name="gao-token"]').content;
const DOCUMENT_PAGES = ["experimentData", "summaryReports", "importantLiterature"];
const PAGE_LABELS = {
  submissions: ["在投管理", "Submissions"], works: ["成果管理", "Works"],
  experimentData: ["实验数据", "Experiment Data"], summaryReports: ["总结报告", "Summary Reports"],
  importantLiterature: ["重要文献", "Important Literature"], certificates: ["证书", "Certificates"], city: ["研究城", "Research City"],
};
const PAGE_ICONS = {submissions: "document", works: "seal", experimentData: "flask", summaryReports: "report", importantLiterature: "books", certificates: "certificate", city: "city"};
const SYMBOLS = {
  archive: "\uE7B8", arrow: "\uE76C", back: "\uE76B", bell: "\uEA8F", books: "\uE8F1", calendar: "\uE787", certificate: "\uEB95",
  city: "\uE80F", clip: "\uE723", close: "\uE711", coin: "\uEC0A", document: "\uE8A5", download: "\uE896", edit: "\uE70F",
  ellipsis: "\uE712", exit: "\uE8BB", flask: "\uEA80", folder: "\uE8B7", globe: "\uE774", grip: "\uE700", image: "\uEB9F",
  link: "\uE71B", menu: "\uE89F", open: "\uE8E5", paperplane: "\uE724", plus: "\uE710", refresh: "\uE72C", report: "\uE9F9",
  seal: "\uE930", search: "\uE721", settings: "\uE713", tag: "\uE8EC", ticket: "\uE8EC", trash: "\uE74D", upload: "\uE898",
};
const state = {
  page: "submissions", scope: "all", folder: "", tag: "", documentSort: "uploadedAt", language: "zh-Hans", query: "",
  certificateSort: "eventDate", certificateDescending: true, analyticsOpen: false, overview: {}, settings: {}, writable: true,
};

function tr(zh, en) { return (state.language === "en" && en) || zh; }
function pageLabel(page) { return tr(...PAGE_LABELS[page]); }
function el(tag, classes, ...children) {
  const node = document.createElement(tag);
  if (classes) node.className = classes;
  node.append(...children.flat(Infinity).filter((child) => child !== null && child !== undefined && child !== false));
  return node;
}
function icon(name) {
  const symbol = el("span", "symbol", SYMBOLS[name] || "");
  symbol.setAttribute("aria-hidden", "true");
  return symbol;
}
function toast(message) {
  const node = $("toast");
  node.textContent = message;
  node.classList.add("show");
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => node.classList.remove("show"), 4000);
}
function report(error) {
  const message = error.message || String(error);
  const inline = $("editor").open && $("editor").querySelector(".dialog-error");
  if (inline) {
    inline.hidden = false;
    inline.textContent = message;
  } else toast(message);
}
async function api(path, options = {}) {
  const headers = Object.assign({"X-Gao-Token": token}, options.headers || {});
  const response = await fetch(path, {...options, headers});
  if (!response.ok || response.headers.get("content-type")?.includes("json")) {
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(payload.message || tr("请求没有完成。", "The request did not complete."));
    return payload;
  }
  return response;
}
function post(path, body = {}) {
  return api(path, {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(body)});
}
function button(label, handler, options = {}) {
  const {symbol, style, iconOnly, disabled} = options;
  const node = el("button", [style, iconOnly && "icon-button"].filter(Boolean).join(" "),
    symbol && icon(symbol), !iconOnly && label);
  node.type = "button";
  node.disabled = Boolean(disabled);
  if (iconOnly) {
    node.title = label;
    node.setAttribute("aria-label", label);
  }
  if (handler) node.addEventListener("click", () => Promise.resolve().then(handler).catch(report));
  return node;
}
function external(label, url, symbol = "open") {
  let safe;
  try { safe = new URL(url); } catch { return null; }
  if (!["https:", "http:"].includes(safe.protocol) || safe.username || safe.password) return null;
  const link = el("a", "button", icon(symbol), label);
  link.href = safe.href;
  link.target = "_blank";
  link.rel = "noopener noreferrer";
  return link;
}
function popover(label, symbol, children, iconOnly = false) {
  const title = el("summary", iconOnly ? "icon-button" : "button", icon(symbol), !iconOnly && label);
  title.setAttribute("aria-label", label);
  title.title = label;
  const menu = el("details", "popover", title, el("div", "popover-menu", children));
  menu.addEventListener("click", (event) => {
    if (event.target.closest(".popover-menu button, .popover-menu a")) menu.open = false;
  });
  return menu;
}
function field(label, name, value = "", type = "text") {
  const control = el(type === "area" ? "textarea" : "input");
  control.name = name;
  if (type !== "area") control.type = type;
  control.value = value ?? "";
  control.autocomplete = type === "password" ? "new-password" : "off";
  return el("label", "field", el("span", "field-label", label), control);
}
function selectField(label, name, value, options) {
  const control = el("select");
  control.name = name;
  for (const [key, text] of options) {
    const option = el("option", "", text);
    option.value = key;
    control.append(option);
  }
  control.value = value ?? "";
  return el("label", "field", el("span", "field-label", label), control);
}
function formGroup(title, ...children) { return el("fieldset", "form-group stack", el("legend", "", title), children); }
function closeDialog() { if ($("editor").open) $("editor").close(); }
function modal(title, nodes, options = {}) {
  const dialog = $("editor");
  const {subtitle, submit, submitLabel, actions = [], size = "", unclosable = false} = options;
  dialog.className = size;
  const heading = el("h2", "", title);
  heading.id = "dialog-heading";
  const error = el("p", "dialog-error");
  error.hidden = true;
  error.setAttribute("role", "alert");
  const body = el("div", "dialog-body stack", nodes);
  const footer = el("footer", "dialog-foot", actions);
  if (!unclosable) footer.append(button(submit ? tr("取消", "Cancel") : tr("完成", "Done"), closeDialog));
  if (submit) {
    const save = el("button", "primary", submitLabel || tr("保存", "Save"));
    save.type = "submit";
    footer.append(save);
  }
  const form = el(submit ? "form" : "div", "dialog-layout",
    el("header", "dialog-header", heading, subtitle && el("p", "muted", subtitle)), body, error, footer);
  if (submit) form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const submitter = event.submitter;
    if (submitter) submitter.disabled = true;
    error.hidden = true;
    try { await submit(Object.fromEntries(new FormData(form)), form); } catch (failure) { report(failure); }
    finally { if (submitter) submitter.disabled = false; }
  });
  dialog.replaceChildren(form);
  if (!dialog.open) dialog.showModal();
  return form;
}
function confirmTrash(title, details, run, label = tr("删除", "Delete")) {
  modal(title, [el("p", "", details)], {size: "compact", actions: [button(label, async () => {
    await run(); closeDialog(); await refresh();
  }, {style: "danger"})]});
}
function card(title, subtitle, ...content) {
  return el("section", "card", title && el("h2", "section-title", title),
    subtitle && el("p", "section-subtitle", subtitle), content);
}
function emptyState(symbol, title, subtitle, ...actions) {
  return el("section", "card empty", el("div", "empty-mark", icon(symbol)), el("h2", "", title),
    subtitle && el("p", "muted", subtitle), actions.length > 0 && el("div", "row", actions));
}
function pairs(...rows) {
  return el("dl", "pairs", rows.filter(([, value]) => value || value === 0).flatMap(([label, value]) =>
    [el("dt", "", label), el("dd", "", value)]));
}
function formatDate(value, withTime = false) {
  const date = new Date(value || "");
  if (!Number.isFinite(date.getTime())) return "—";
  return new Intl.DateTimeFormat(state.language === "en" ? "en-US" : "zh-CN", {
    dateStyle: "medium", ...(withTime ? {timeStyle: "short"} : {}),
  }).format(date);
}
function dateInput(value) {
  if (value) return String(value).slice(0, 10);
  const day = new Date();
  return `${day.getFullYear()}-${String(day.getMonth() + 1).padStart(2, "0")}-${String(day.getDate()).padStart(2, "0")}`;
}
function safeFocus(node) { if (node && node.isConnected) node.focus({preventScroll: true}); }
function badge(text, style = "") { return el("span", `badge ${style}`, text); }
function chart(title, subtitle, values, options = {}) {
  const {height = 0, unit = "", mark = "", empty = tr("还没有可显示的数据", "No data to display")} = options;
  const box = el("div", "chart-bars");
  const largest = Math.max(1, ...values.map((row) => row.count));
  for (const row of values) {
    const fill = el("i", "chart-fill");
    fill.style.width = `${row.count * 100 / largest}%`;
    const line = el("div", `bar ${row.tone || mark}`, el("span", "bar-label", row.label),
      el("span", "bar-track", fill), el("span", "bar-count", `${row.count}${unit}${row.note ? ` · ${row.note}` : ""}`));
    box.append(line);
  }
  if (!values.length) box.append(el("p", "muted chart-empty", empty));
  if (height) box.style.minHeight = `${height}px`;
  return card(title, subtitle, box);
}
function reorderItem(node, kind, id, enabled = true) {
  if (!enabled || !state.writable) return node;
  const mime = "application/x-gaoresearch-order";
  node.draggable = true;
  node.addEventListener("dragstart", (event) => {
    event.dataTransfer.setData(mime, JSON.stringify({kind, id}));
    event.dataTransfer.effectAllowed = "move";
  });
  node.addEventListener("dragover", (event) => {
    if (event.dataTransfer.types.includes(mime)) { event.preventDefault(); node.classList.add("drop-target"); }
  });
  node.addEventListener("dragleave", () => node.classList.remove("drop-target"));
  node.addEventListener("drop", async (event) => {
    const data = event.dataTransfer.getData(mime);
    if (!data) return;
    event.preventDefault();
    event.stopPropagation();
    node.classList.remove("drop-target");
    try {
      const from = JSON.parse(data);
      if (from.kind !== kind || from.id === id) return;
      await post("/api/reorder", {kind, sourceID: from.id, targetID: id});
      await refresh();
    } catch (error) { report(error); }
  });
  return node;
}
function downloadURL(kind, owner, row, preview = false) {
  return `/api/download?${new URLSearchParams({kind, owner, name: row.storedName, token, ...(preview ? {preview: "1"} : {})})}`;
}
function downloadLink(kind, owner, row) {
  const link = el("a", "button", icon("download"), tr("下载", "Download"));
  link.href = downloadURL(kind, owner, row);
  link.download = row.originalName || "";
  return link;
}
function storedPreview(kind, owner, row, page = null) {
  const extension = (row.fileExtension || (row.originalName || row.storedName).split(".").at(-1)).toLowerCase();
  if (!/^(pdf|jpe?g|png|gif|webp|bmp|avif)$/.test(extension)) return null;
  let url = downloadURL(kind, owner, row, true);
  if (row.ocrSource) url += "&ocrSource=" + encodeURIComponent(row.ocrSource);
  if (extension === "pdf") {
    const frame = el("iframe", "pdf-preview");
    frame.title = tr("PDF 预览", "PDF preview");
    frame.src = url + (page ? `#page=${page}` : "");
    return frame;
  }
  const image = el("img", "image-preview");
  image.src = url;
  image.alt = row.displayName || row.originalName;
  return image;
}
function uploadFile(path, file, extra) {
  const data = new FormData();
  for (const [key, value] of Object.entries(extra)) data.set(key, value);
  data.set("file", file);
  return api(path, {method: "POST", body: data});
}
function chooseFiles(handler, accept = "") {
  const input = el("input");
  input.type = "file";
  input.multiple = true;
  input.accept = accept;
  input.addEventListener("change", async () => {
    try { await handler(Array.from(input.files)); } catch (error) { report(error); }
  }, {once: true});
  input.click();
}

function applyChrome() {
  document.documentElement.lang = state.language === "en" ? "en" : "zh-CN";
  document.title = tr("搞研究", "GaoYanJiu");
  document.body.dataset.theme = state.settings.appearance || "system";
  document.querySelectorAll("[data-zh]").forEach((node) => { node.textContent = tr(node.dataset.zh, node.dataset.en); });
}
function setPage(page) {
  state.page = page;
  state.folder = "";
  state.tag = "";
  state.query = "";
  if (page === "submissions") state.scope = "all";
  $("search").value = "";
  $("main").scrollTop = 0;
  return render();
}
function navGroups() {
  const groups = [
    [tr("研究工作台", "Research Workspace"), ["submissions", "works"]],
    [tr("资料与资产", "Library and Assets"), [...DOCUMENT_PAGES, "certificates"]],
    [tr("探索", "Explore"), ["city"]],
  ];
  $("nav").replaceChildren(...groups.map(([label, pages]) => el("section", "nav-group", el("h2", "", label), pages.map((page) => {
    const node = button(pageLabel(page), () => setPage(page), {symbol: PAGE_ICONS[page], style: "nav-row"});
    node.append(el("span", "nav-count", state.overview[page]?.count ?? 0));
    if (page === state.page) node.setAttribute("aria-current", "page");
    return node;
  }))));
  const status = state.page === "submissions" ? [el("div", "status-line", el("span", "status-dot"),
    tr(`${state.overview.portals || 0} 个投稿门户`, `${state.overview.portals || 0} submission portals`))] : [];
  $("sidebar-status").replaceChildren(...status, el("small", "muted", tr("本地存储", "Local storage")));
}
function searchPrompt() {
  return {
    submissions: tr("搜索标题、期刊、稿号或状态", "Search title, journal, manuscript ID or status"),
    works: tr("搜索成果、作者、期刊或编号", "Search works, authors, venues or identifiers"),
    certificates: tr("搜索证书名称、标签或附件", "Search certificate name, tags or attachments"),
  }[state.page] || tr("搜索文件夹、文件名、标签或正文", "Search folders, filenames, tags or text");
}
function utilities() {
  const sidebar = button(tr("显示或隐藏侧栏", "Toggle sidebar"), () => {
    const collapsed = $("shell").classList.toggle("sidebar-collapsed");
    sidebar.setAttribute("aria-expanded", String(!collapsed));
  }, {iconOnly: true, symbol: "menu"});
  sidebar.setAttribute("aria-controls", "sidebar");
  sidebar.setAttribute("aria-expanded", String(!$("shell").classList.contains("sidebar-collapsed")));
  $("utilities").replaceChildren(sidebar,
    button(tr("回收站", "Trash"), openTrash, {iconOnly: true, symbol: "trash"}),
    button(tr("设置", "Settings"), openSettings, {iconOnly: true, symbol: "settings"}));
  $("search-icon").replaceChildren(icon("search"));
  document.querySelector(".search-wrap").hidden = state.page === "city";
  const search = $("search");
  search.placeholder = searchPrompt();
  search.setAttribute("aria-label", search.placeholder);
  $("clear-search").hidden = !state.query;
  $("clear-search").title = tr("清除搜索", "Clear search");
  $("clear-search").setAttribute("aria-label", $("clear-search").title);
  $("clear-search").replaceChildren(icon("close"));
}
function dashboard(subtitle, stats) {
  return el("header", "dashboard", el("h1", "", pageLabel(state.page)), el("p", "dashboard-caption", subtitle),
    el("div", "stats", stats.map(([value, label, symbol, style]) => el("div", "stat", el("div", `stat-symbol ${style || ""}`, icon(symbol)),
      el("div", "", el("strong", "", value ?? 0), el("small", "muted", label))))));
}
function latestLabel(value, empty, checked = false) {
  if (!value) return empty;
  const moment = formatDate(value, true);
  return checked ? tr(`最近检查：${moment}`, `Last checked ${moment}`) : tr(`最近更新：${moment}`, `Last updated ${moment}`);
}

async function openTrash() {
  const {items} = await api("/api/trash");
  const rows = el("div", "list");
  const labels = {
    paper: tr("在投论文", "Submission"), existingWork: tr("成果", "Work"), certificate: tr("证书", "Certificate"),
    documentFolder: tr("文件夹", "Folder"), managedDocument: tr("文件", "File"), workAttachment: tr("成果附件", "Work attachment"),
    certificateAttachment: tr("证书附件", "Certificate attachment"), project: tr("历史项目", "Historical project"),
    fundingRecord: tr("历史资金记录", "Historical funding record"),
  };
  for (const item of items) {
    rows.append(el("article", "line-item", el("div", "grow", el("strong", "", item.title || labels[item.kind] || tr("记录", "Record")),
      el("small", "muted block", [labels[item.kind], formatDate(item.deletedAt, true)].filter(Boolean).join(" · "))),
    button(tr("恢复", "Restore"), async () => { await post("/api/trash/restore", {id: item.id}); await openTrash(); await refresh(); }),
    button(tr("彻底删除", "Delete permanently"), () => modal(tr("永久删除此记录？", "Permanently delete this record?"),
      [el("p", "", item.title || tr("这项操作无法撤销。", "This action cannot be undone."))], {size: "compact", actions: [button(tr("彻底删除", "Delete permanently"), async () => {
        await post("/api/trash/delete", {id: item.id}); await openTrash(); await refresh();
      }, {style: "danger"})]}), {style: "danger"})));
  }
  modal(tr("回收站", "Trash"), [el("p", "muted", tr("已删除的记录和附件保留 30 天。", "Deleted records and attachments are kept for 30 days.")),
    items.length ? rows : emptyState("trash", tr("回收站为空", "Trash is empty"))]);
}
async function openSettings() {
  const [data, reminders] = await Promise.all([api("/api/settings"), api("/api/notifications/status")]);
  const systemReminders = el("input");
  systemReminders.type = "checkbox";
  systemReminders.name = "notificationsEnabled";
  systemReminders.checked = data.settings.notificationsEnabled === true;
  systemReminders.disabled = reminders.state === "unavailable";
  const remindersMessage = {
    active: tr(`已安排 ${reminders.count} 条 Windows 通知。`, `${reminders.count} Windows notifications scheduled.`),
    blocked: tr("Windows 已阻止通知，可在系统通知设置中允许“搞研究”。", "Windows has blocked notifications. Allow GaoYanJiu in Windows notification settings."),
    pending: tr("正在更新 Windows 通知。", "Updating Windows notifications."),
    off: tr("系统提醒已关闭。", "System reminders are off."),
    error: tr("Windows 通知暂未安排成功。", "Windows could not schedule the reminders."),
    unavailable: tr("系统提醒适用于已安装应用的默认资料库。", "System reminders are available for the installed app’s default library."),
  };
  const links = el("div", "row", button(tr("在文件资源管理器中显示", "Show in File Explorer"),
    () => post("/api/files/reveal", {kind: "root"}), {symbol: "folder"}));
  links.append(button(tr("打开桌面小组件", "Open desktop widgets"),
    () => post("/api/widgets/open", {page: state.page === "works" ? "works" : "submissions"}), {symbol: "city"}));
  modal(tr("设置", "Settings"), [formGroup(tr("通用", "General"),
    selectField(tr("外观", "Appearance"), "appearance", data.settings.appearance, [["system", tr("跟随系统", "System")], ["light", tr("浅色", "Light")], ["dark", tr("深色", "Dark")]]),
    selectField(tr("语言", "Language"), "language", data.settings.language, [["zh-Hans", "简体中文"], ["en", "English"]])),
  formGroup(tr("投稿提醒", "Follow-up reminders"),
    field(tr("待跟进天数", "Follow-up days"), "followUpDays", data.settings.followUpDays, "number"),
    el("label", "row", systemReminders, tr("启用 Windows 系统通知", "Enable Windows system notifications")),
    el("small", "muted", tr("系统通知会显示稿件标题和当前状态。", "Notifications show the manuscript title and current status.")),
    el("small", "muted", remindersMessage[reminders.state])),
  formGroup(tr("本地资料", "Local data"), el("p", "path-text", data.dataDir), links,
    el("small", "muted", `Windows ${state.version} · build ${state.build}`))], {submit: async (values) => {
    const {notificationsEnabled, ...settings} = values;
    if (!systemReminders.disabled) settings.notificationsEnabled = Boolean(notificationsEnabled);
    await post("/api/settings", {...settings, followUpDays: Number(settings.followUpDays)});
    closeDialog(); await refresh();
  }, actions: [button(tr("退出搞研究", "Quit GaoYanJiu"), quit, {symbol: "exit"})]});
}
async function quit() {
  await post("/api/shutdown");
  closeDialog();
  $("shell").hidden = true;
  $("gate").hidden = false;
  $("gate-text").textContent = tr("搞研究已退出。", "GaoYanJiu has quit.");
  $("gate-create").hidden = $("gate-retry").hidden = $("gate-quit").hidden = true;
  window.close();
}
async function pageCity() {
  const data = await api("/api/reward");
  const balances = data.city || data;
  const stats = dashboard(tr("让每一份学术积累，长成属于你的绿色研究城", "Grow a green city with each research milestone"), [
    [Math.floor((balances.coins || 0) + (data.pendingCoins || 0)), tr("金币", "Coins"), "coin", "clay"],
    [balances.buildingTickets, tr("房屋券", "Building tickets"), "ticket"],
    [balances.decorationTickets, tr("摆件券", "Decoration tickets"), "seal", "teal"],
  ]);
  const collect = button(tr("收取金币", "Collect coins"), async () => { await post("/api/reward/collect"); await refresh(); },
    {symbol: "coin", disabled: (data.pendingCoins || 0) < 0.01});
  const city = renderRewardCity({data, request: api, language: state.language, onUpdate: (next) => {
    const latest = next.city || next;
    [Math.floor((latest.coins || 0) + (next.pendingCoins || 0)), latest.buildingTickets, latest.decorationTickets].forEach((value, index) => {
      stats.querySelectorAll(".stat strong")[index].textContent = value ?? 0;
    });
    collect.disabled = (next.pendingCoins || 0) < 0.01;
    state.overview.city.count = next.placements?.length ?? latest.placements?.length ?? 0;
    navGroups();
  }});
  return {tools: [collect], nodes: [stats, city]};
}

let renderGeneration = 0;
async function render() {
  if ($("shell").hidden) return;
  const generation = ++renderGeneration;
  const page = state.page;
  navGroups(); utilities(); applyChrome();
  const build = {submissions: pageSubmissions, works: pageWorks, certificates: pageCertificates, city: pageCity}[page] || pageDocuments;
  const result = await build(page, state.query);
  if (generation !== renderGeneration || page !== state.page) return;
  $("page-tools").replaceChildren(...result.tools);
  const notice = state.writable ? [] : [el("p", "readonly-notice", state.libraryMessage)];
  $("main").replaceChildren(...notice, ...result.nodes);
  $("main").dataset.page = page;
}
async function refresh(info = null) {
  const data = info || await api("/api/bootstrap");
  Object.assign(state, {settings: data.settings, language: data.settings.language || "zh-Hans", overview: data.overview,
    build: data.build, version: data.version, writable: data.writable, libraryMessage: data.message});
  applyChrome();
  if (data.status !== "ready") {
    $("gate").hidden = false;
    $("shell").hidden = true;
    $("gate-text").textContent = data.message;
    const empty = data.status === "needs_create";
    $("gate-create").hidden = !empty;
    $("gate-retry").hidden = empty;
    return;
  }
  $("gate").hidden = true;
  $("shell").hidden = false;
  await render();
}
async function applyRoute() {
  const route = decodeURIComponent(location.hash.slice(1));
  if (!route || $("shell").hidden) return;
  if (route === "exchange") await window.researchExchange?.open({api, folderID: state.folder, refresh, language: state.language});
  else if (route.match(/^follow-up\/[0-9a-f]{40}$/)) {
    const {paper} = await api(`/api/notifications/paper?ref=${route.split("/")[1]}`);
    await setPage("submissions");
    if (paper) await openPaperDetail(paper);
    else toast(tr("这条提醒对应的稿件已找不到。", "The submission for this reminder is no longer available."));
  }
  else if (Object.hasOwn(PAGE_LABELS, route)) await setPage(route);
  else if (["changed", "hidden", "projects"].includes(route)) {
    await setPage("submissions");
    if (route !== "projects") { state.scope = route; await render(); }
  }
  history.replaceState(null, "", location.pathname);
}
let searchTimer;
function applySearch() {
  state.query = $("search").value.trim();
  $("clear-search").hidden = !state.query;
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => render().catch(report), 150);
}
document.addEventListener("DOMContentLoaded", async () => {
  $("gate-create").addEventListener("click", () => post("/api/library/create").then(refresh).then(applyRoute).catch(report));
  $("gate-retry").addEventListener("click", () => post("/api/library/reload").then(refresh).then(applyRoute).catch(report));
  $("gate-quit").addEventListener("click", () => quit().catch(report));
  $("search").addEventListener("input", applySearch);
  $("clear-search").addEventListener("click", () => { $("search").value = ""; applySearch(); safeFocus($("search")); });
  window.addEventListener("hashchange", () => applyRoute().catch(report));
  document.addEventListener("keydown", (event) => {
    if ($("shell").hidden || $("editor").open || !(event.ctrlKey || event.metaKey)) return;
    if (event.key.toLowerCase() === "f" && state.page !== "city") { event.preventDefault(); safeFocus($("search")); }
    if (event.key === ",") { event.preventDefault(); openSettings().catch(report); }
  });
  document.addEventListener("click", (event) => {
    document.querySelectorAll(".popover[open]").forEach((menu) => { if (!menu.contains(event.target)) menu.open = false; });
  });
  try {
    const info = await api("/api/bootstrap");
    await refresh(info); await applyRoute();
    if (info.followUps) toast(tr(`${info.followUps} 篇论文待跟进`, `${info.followUps} submissions to follow up`));
  } catch (error) { report(error); }
});
