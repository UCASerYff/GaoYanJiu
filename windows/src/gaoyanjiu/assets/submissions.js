"use strict";

const TERMINAL = /accept|publish|reject|withdraw|declin|cancel|已接受|接收|录用|已发表|拒稿|已拒|撤稿|已撤/i;
const COMMON_STATUSES = ["已投稿", "初审中", "审稿中", "小修", "大修", "修回后审稿", "已接受", "已发表", "已拒稿", "已撤稿"];

function statusDays(value) {
  const date = new Date(value || "");
  if (!Number.isFinite(date.getTime())) return 0;
  const now = new Date();
  const day = (value) => Date.UTC(value.getFullYear(), value.getMonth(), value.getDate());
  return Math.max(0, Math.round((day(now) - day(date)) / 86400000));
}
function displayedManuscript(paper) {
  return paper.manuscriptID?.startsWith("pending:") ? tr("期刊尚未分配稿号", "Manuscript ID pending") : paper.manuscriptID;
}
function openPaperEditor(paper = null) {
  const title = field(tr("论文标题（必填）", "Paper title (required)"), "title", paper?.title);
  title.querySelector("input").required = true;
  const status = field(tr("状态（必填）", "Status (required)"), "status", paper?.status || tr("已投稿", "Submitted"));
  const suggestions = el("datalist", "", COMMON_STATUSES.map((value) => el("option", "", value)));
  suggestions.id = "paper-status-options";
  status.querySelector("input").setAttribute("list", suggestions.id);
  status.querySelector("input").required = true;
  modal(paper ? tr("编辑在投论文", "Edit submission") : tr("手动添加在投论文", "Add submission manually"), [
    formGroup(tr("基本信息", "Basic information"), title,
      field(tr("期刊或会议名称", "Journal or conference"), "venue", paper?.journal),
      field(tr("稿件编号（可选）", "Manuscript ID (optional)"), "manuscriptID", paper?.manuscriptID)),
    formGroup(tr("当前状态", "Current status"), status, suggestions,
      field(tr("进入该状态的日期", "Date this status began"), "statusSince", dateInput(paper?.statusSince), "date"),
      paper && el("small", "muted", tr("修改状态会将变化记入历史。", "Status changes are saved in the history."))),
    formGroup(tr("补充信息", "Additional information"),
      field(tr("投稿网页链接（可选）", "Submission page (optional)"), "url", paper?.url),
      field(tr("备注", "Notes"), "notes", paper?.submissionHistory, "area")),
  ], {subtitle: tr("适用于会议、期刊自建系统等需手动跟踪的稿件。", "For submissions tracked manually, including conferences and independent journal sites."),
    submitLabel: paper ? tr("保存", "Save") : tr("添加", "Add"), submit: async (values) => {
      await post("/api/papers", {...values, ...(paper ? {key: paper.key} : {})});
      closeDialog(); await refresh();
    }});
}
function deletePaper(paper) {
  confirmTrash(tr("删除论文及其本地历史？", "Delete this submission and its local history?"),
    tr("记录会移入回收站，可在 30 天内恢复。出版商网站上的论文不受影响。", "The record can be restored from Trash for 30 days. The publisher's copy is unaffected."),
    () => post("/api/papers/trash", {key: paper.key}));
}
async function archivePaper(paper) {
  await post("/api/papers/hidden", {key: paper.key, hidden: !paper.hidden});
  closeDialog(); await refresh();
}
async function openPaperDetail(paper) {
  if (paper.changed && state.writable) {
    await post("/api/papers/read", {key: paper.key});
    await refresh();
  }
  const events = (paper.history || []).slice().reverse();
  const logs = el("div", "list", events.map((entry) => el("div", "line-item", el("strong", "", entry.status),
    el("small", "muted", formatDate(entry.checkedAt, true)))));
  const actions = [
    paper.sourceID === "manual" && button(tr("编辑", "Edit"), () => openPaperEditor(paper), {symbol: "edit", disabled: !state.writable}),
    button(paper.hidden ? tr("恢复追踪", "Resume tracking") : tr("归档", "Archive"), () => archivePaper(paper), {symbol: "archive", disabled: !state.writable}),
    button(tr("删除", "Delete"), () => deletePaper(paper), {symbol: "trash", style: "danger", disabled: !state.writable}),
  ].filter(Boolean);
  modal(paper.title, [
    card(tr("投稿信息", "Submission details"), "", pairs(
      [tr("期刊或会议", "Journal or conference"), paper.journal], [tr("稿件编号", "Manuscript ID"), displayedManuscript(paper)],
      [tr("来源", "Source"), paper.site], [tr("当前状态", "Current status"), paper.status],
      [tr("上一状态", "Previous status"), paper.previousStatus], [tr("进入此状态", "Status began"), formatDate(paper.statusSince)],
      [tr("状态起始依据", "Status date source"), paper.statusSinceSource], [tr("最近检查", "Last checked"), formatDate(paper.checkedAt, true)]),
      external(tr("打开投稿网页", "Open submission page"), paper.url)),
    events.length && card(tr("状态历史", "Status history"), "", logs),
    paper.submissionHistory && card(tr("备注与投稿历史", "Notes and submission history"), "", el("p", "text-preview", paper.submissionHistory)),
  ].filter(Boolean), {subtitle: paper.journal, actions});
}
function paperRow(paper, query) {
  const title = button(paper.title, () => openPaperDetail(paper), {style: "text-button"});
  const actions = popover(tr("论文操作", "Submission actions"), "ellipsis", [
    button(tr("查看详情", "View details"), () => openPaperDetail(paper), {symbol: "document"}),
    button(paper.hidden ? tr("恢复追踪", "Resume tracking") : tr("归档", "Archive"), () => archivePaper(paper), {symbol: "archive", disabled: !state.writable}),
    button(tr("删除", "Delete"), () => deletePaper(paper), {symbol: "trash", style: "danger", disabled: !state.writable}),
  ], true);
  const days = statusDays(paper.statusSince);
  const row = el("article", "paper-row" + (paper.changed ? " changed" : ""),
    el("span", paper.changed ? "record-mark clay" : "record-mark", icon(paper.changed ? "bell" : "document")),
    el("div", "record-summary", el("div", "record-meta", el("span", "site", String(paper.site || "").toUpperCase()),
      el("span", "", "·"), el("span", "", displayedManuscript(paper)), paper.changed && badge(tr("有更新", "Updated"), "clay")),
    title, el("small", "muted", paper.journal)),
    el("div", "record-status", badge(paper.status, paper.changed ? "clay" : ""),
      el("small", "", tr("此阶段 " + days + " 天", days + " days in this status")),
      el("small", "", tr("更新于 " + formatDate(paper.checkedAt), "Updated " + formatDate(paper.checkedAt)))),
    el("span", "grip", icon("grip")), actions);
  row.addEventListener("click", (event) => {
    if (!event.target.closest("button, details, a") && !window.getSelection()?.toString()) title.click();
  });
  return reorderItem(row, "paper", paper.key, !query);
}
function tally(values) {
  const counts = new Map();
  for (const value of values) counts.set(value, (counts.get(value) || 0) + 1);
  return [...counts].map(([label, count]) => ({label, count}));
}
function submissionStatistics(papers) {
  const detail = el("details", "disclosure", el("summary", "", tr("投稿统计与趋势", "Submission statistics and trends")));
  const counts = tally(papers.map((paper) => paper.status || tr("未填写", "Unspecified")))
    .sort((a, b) => b.count - a.count || a.label.localeCompare(b.label));
  const durations = papers.map((paper) => {
    const count = statusDays(paper.statusSince);
    const terminal = TERMINAL.test(paper.status);
    const note = terminal ? "" : count >= 90 ? tr("超期", "Overdue") : count >= 60 ? tr("关注", "Watch") : "";
    return {label: paper.title + " · " + displayedManuscript(paper), count, note, tone: terminal ? "terminal" : note ? "clay" : ""};
  }).sort((a, b) => b.count - a.count || a.label.localeCompare(b.label));
  detail.append(el("div", "analytics-layout",
    chart(tr("当前投稿状态分布", "Current submission status"), tr("按当前列表中的论文状态自动统计", "Counts for the submissions in this list"), counts, {height: Math.max(190, counts.length * 30)}),
    chart(tr("各论文状态持续时间", "Time spent in current status"),
      tr("60–89 天标为关注，满 90 天标为超期。终态稿件不提醒。", "Watch at 60–89 days and overdue at 90 days. Completed submissions are excluded from reminders."),
      durations, {height: Math.max(220, durations.length * 32), unit: tr(" 天", " d")})));
  detail.open = state.analyticsOpen;
  detail.addEventListener("toggle", () => { state.analyticsOpen = detail.open; });
  return detail;
}
async function pageSubmissions(_page, query) {
  const scope = state.scope;
  const [{papers}, {portals}] = await Promise.all([
    api("/api/papers?" + new URLSearchParams({scope, q: query})), api("/api/portals"),
  ]);
  const info = state.overview.submissions;
  const manual = () => openPaperEditor();
  const publisherPicker = () => openPortalPicker();
  const tabBar = el("div", "tabs");
  tabBar.setAttribute("role", "group");
  tabBar.setAttribute("aria-label", tr("投稿范围", "Submission scope"));
  const tabs = [
    ["all", tr("全部", "All"), info.count],
    ["changed", tr("状态更新", "Updated"), info.changed],
    ["hidden", tr("已归档", "Archived"), info.hidden],
  ];
  for (const [key, label, count] of tabs) {
    const tab = button(label, async () => { state.scope = key; await render(); });
    tab.dataset.scope = key;
    tab.setAttribute("aria-pressed", String(scope === key));
    tab.append(el("span", "tab-count", count));
    tabBar.append(tab);
  }
  const portalNarrow = button(tr("门户", "Portals"), () => modal(tr("投稿门户", "Submission portals"),
    [portalPanel(portals, false)], {size: "compact"}), {style: "portal-narrow", symbol: "link"});
  const addition = popover(tr("添加在投", "Add submission"), "plus", [
    button(tr("手动添加", "Add manually"), manual, {symbol: "edit", disabled: !state.writable}),
    button(tr("从投稿系统导入", "Import from a portal"), publisherPicker, {symbol: "globe", disabled: !state.writable}),
  ]);
  const list = papers.length ? el("div", "submission-list",
    scope === "all" && submissionStatistics(papers), papers.map((paper) => paperRow(paper, query))
  ) : emptyState(scope === "hidden" ? "archive" : "document",
    query ? tr("没有找到匹配的论文", "No matching submissions")
      : scope === "hidden" ? tr("归档中没有论文", "No archived submissions")
      : scope === "changed" ? tr("暂时没有新的状态变化", "No status changes") : tr("还没有在投论文", "No submissions yet"),
    scope === "all" && !query ? tr("可以手动建立记录，也可以登录出版商系统导入。", "Add a record manually or sign in to a publisher portal to import it.")
      : tr("状态变化会保留在本机历史记录中。", "Status updates are stored in the local submission history."),
    ...(scope === "all" && !query ? [
      button(tr("手动添加", "Add manually"), manual, {style: "primary", symbol: "edit", disabled: !state.writable}),
      button(tr("从投稿系统导入", "Import from a portal"), publisherPicker, {symbol: "globe", disabled: !state.writable}),
    ] : []));
  return {tools: [portalNarrow, addition], nodes: [
    dashboard(latestLabel(info.latest, tr("连接投稿门户，开始整理你的学术成果", "Connect a submission portal to start organizing your work"), true), [
      [info.count, tr("论文记录", "Submissions"), "document"], [info.active, tr("仍在投", "In progress"), "paperplane", "teal"],
      [info.accepted, tr("已接受", "Accepted"), "seal"], [info.changed, tr("状态更新", "Status changes"), "bell", "clay"],
    ]),
    tabBar, el("div", "submission-layout", list, portalPanel(portals)),
  ]};
}
function portalPanel(portals, wide = true) {
  const count = portals.length;
  const panel = el("section", "card stack portal-panel" + (wide ? " portal-wide" : ""),
    el("div", "section-head", el("h2", "row", icon("link"), tr("投稿门户", "Submission portals")),
      button(tr("从投稿系统导入", "Import from a portal"), openPortalPicker, {iconOnly: true, symbol: "plus", disabled: !state.writable})),
    el("small", "muted", tr(count + " 个投稿门户", count + " submission portals")));
  if (!count) {
    panel.append(el("p", "muted", tr("连接投稿门户，开始整理你的学术成果", "Connect a portal to import and track submissions")),
      el("div", "", button(tr("从投稿系统导入", "Import from a portal"), openPortalPicker, {style: "primary", disabled: !state.writable})));
    return panel;
  }
  for (const portal of portals) {
    let address = portal.url;
    try {
      const url = new URL(portal.url);
      address = url.host + "/" + (url.pathname.split("/").filter(Boolean)[0] || "");
    } catch { /* old records can contain incomplete addresses */ }
    const stale = !portal.lastChecked || new Date(portal.lastChecked).getTime() < Date.now() - 86400000;
    const status = portal.lastError ? tr("同步有错误", "Sync error")
      : stale ? tr("历史状态，需刷新", "Needs refresh")
      : latestLabel(portal.lastChecked, "", true);
    const open = button(portal.publisherName || portal.name, () => openPortalCapture(portal), {style: "portal-name quiet"});
    open.append(el("small", "muted", address), el("small", "portal-status" + (portal.lastError ? " error" : ""), status));
    panel.append(el("div", "portal-line", open,
      popover(tr("门户操作", "Portal actions"), "ellipsis", [
        button(tr("编辑门户", "Edit portal"), () => editPortal(portal), {symbol: "edit", disabled: !state.writable}),
        button(tr("删除门户", "Delete portal"), () => confirmTrash(tr("删除投稿门户？", "Delete this submission portal?"),
          tr("已导入的论文和历史记录会保留。", "Imported submissions and their history stay in the library."),
          () => post("/api/portals/delete", {id: portal.id}), tr("删除门户，保留论文", "Delete portal and keep submissions")),
          {symbol: "trash", style: "danger", disabled: !state.writable}),
      ], true)));
  }
  panel.append(el("div", "", button(tr("刷新全部", "Refresh all"), () => openPortalCapture(portals[0], portals.slice(1)),
    {symbol: "refresh", disabled: !state.writable})));
  return panel;
}
async function openPortalPicker() {
  const {publishers} = await api("/api/publishers");
  modal(tr("从投稿系统导入", "Import from a submission portal"), [
    card(tr("选择投稿系统", "Choose a submission system"), tr("在浏览器登录，再捕获当前稿件页面。", "Sign in in the browser, then capture the submission page."),
      el("div", "publisher-grid", publishers.map((publisher) => button(publisher.name, () => editPortal(null, publisher), {symbol: "globe"})),
        button(tr("自定义投稿网站", "Custom submission website"), () => editPortal(), {symbol: "link"}))),
  ], {size: "wide"});
}
function editPortal(portal = null, publisher = null) {
  const name = field(tr("门户名称", "Portal name"), "name", portal?.name || publisher?.name);
  name.querySelector("input").required = true;
  const address = field(publisher?.requiresJournalURL ? tr("期刊专用投稿入口", "Journal-specific submission URL")
    : tr("投稿网址", "Submission URL"), "url", portal?.url || publisher?.url, "url");
  address.querySelector("input").required = true;
  modal(portal ? tr("编辑投稿门户", "Edit submission portal") : tr("连接投稿门户", "Connect a submission portal"), [
    formGroup(tr("门户信息", "Portal details"), name, address),
    formGroup(tr("本地凭据", "Local credentials"),
      field(tr("账号（可选）", "Account (optional)"), "identity", portal?.identity),
      field(tr("密码（可选）", "Password (optional)"), "password", "", "password"),
      el("small", "muted", tr("应用使用 Windows 加密保存凭据。投稿网站由浏览器负责登录。", "Saved credentials use Windows encryption. Sign in to publisher sites in your browser."))),
  ], {submit: async (values) => {
    const response = await post("/api/portals", {...values, id: portal?.id, publisherID: portal?.publisherID || publisher?.id || "custom"});
    const {portals} = await api("/api/portals");
    await refresh();
    await openPortalCapture(portals.find((row) => row.id === response.id));
  }});
}

let extractorScript;
async function openPortalCapture(portal, next = []) {
  if (!portal) return;
  const source = {name: portal.publisherName || portal.name, kind: portal.kind};
  const host = new URL(portal.url).hostname.toLowerCase().replace(/^www\./, "");
  const instructions = tr("将“提取投稿状态”拖到浏览器收藏夹栏，在已登录的稿件页面点击该收藏项。复制出现的结果，再粘贴到下面审核。",
    "Drag Capture submission status to your bookmarks bar. On the signed-in submissions page, run that bookmark, copy the result and paste it below to review.");
  const captureLink = el("a", "button", icon("download"), tr("提取投稿状态", "Capture submission status"));
  const raw = await (extractorScript ||= fetch("/assets/extractor.js").then((response) => {
    if (!response.ok) throw new Error(tr("找不到投稿状态提取组件。", "The submission extractor could not be loaded."));
    return response.text();
  }).catch((error) => { extractorScript = null; throw error; }));
  captureLink.href = "javascript:" + encodeURIComponent(
    "void(async()=>{if(location.hostname.toLowerCase().replace(/^www\\./,'')!==" + JSON.stringify(host) +
    "){alert(" + JSON.stringify(tr("请先打开所选投稿门户的稿件页面。", "Open the submissions page for the selected portal first.")) +
    ");return;}" + raw + "\nconst result=await globalThis.PaperSignalExtractor.extract(" + JSON.stringify(source) +
    ");result.url=location.origin+location.pathname;const output=document.createElement('textarea');output.value=JSON.stringify(result);output.setAttribute('readonly','');" +
    "output.style.cssText='position:fixed;box-sizing:border-box;z-index:2147483647;top:12px;left:12px;width:min(90vw,740px);height:100px;color:black;background:white;padding:12px;border:2px solid #244b42';" +
    "document.body.append(output);output.focus();output.select();output.addEventListener('keydown',(event)=>{if(event.key==='Escape')output.remove()});" +
    "})().catch(()=>alert(" + JSON.stringify(tr("提取失败。请确认已登录并打开稿件列表。", "Capture failed. Make sure you are signed in and on the submissions page.")) + "));"
  );
  captureLink.addEventListener("click", (event) => { event.preventDefault(); toast(instructions); });
  const pasted = field(tr("粘贴投稿状态结果", "Paste the captured submission status"), "capture", "", "area");
  pasted.querySelector("textarea").required = true;
  modal(tr("导入投稿状态", "Import submission status"), [
    el("p", "", instructions), el("div", "row", external(tr("打开投稿网站", "Open submission website"), portal.url, "globe"), captureLink),
    pasted, next.length ? el("small", "muted", tr("此后还有 " + next.length + " 个门户待刷新。", next.length + " more portals to refresh.")) : null,
  ], {subtitle: portal.name, submitLabel: tr("审核稿件", "Review submissions"), submit: async ({capture}) => {
    let payload;
    try { payload = JSON.parse(capture); } catch { throw new Error(tr("无法读取结果。请复制提取框里的完整内容。", "Copy the entire result from the capture box.")); }
    if (!Array.isArray(payload?.papers) || !payload.papers.length || payload.papers.length > 500)
      throw new Error(tr("没有提取到可用稿件。请登录并打开真实稿件列表。", "No usable submissions were captured. Sign in and open the actual submissions list."));
    const rows = payload.papers.map((paper) => {
      if (!paper || typeof paper.title !== "string" || typeof paper.status !== "string")
        throw new Error(tr("结果含无法读取的稿件。", "The capture contains an unreadable submission."));
      const choice = el("input");
      choice.type = "checkbox";
      choice.checked = true;
      return {paper, choice, row: el("label", "line-item", choice, el("div", "grow", el("strong", "", paper.title),
        el("small", "muted block", [paper.journal, paper.id, paper.status].filter(Boolean).join(" · "))))};
    });
    modal(tr("审核投稿状态", "Review submission status"), [
      el("p", "muted", tr("勾选要导入或更新的稿件。已有稿件会保留状态历史。", "Select the submissions to import or update. Existing submission histories are kept.")),
      el("div", "list", rows.map(({row}) => row)),
    ], {subtitle: portal.name, submitLabel: tr("确认导入", "Confirm import"), submit: async () => {
      const result = await post("/api/portals/capture", {id: portal.id, capture: {...payload, papers: rows.filter(({choice}) => choice.checked).map(({paper}) => paper)}});
      closeDialog(); await refresh();
      toast(tr("新增 " + result.imported + " 篇，状态更新 " + result.changed + " 篇。", result.imported + " added, " + result.changed + " statuses updated."));
      if (next.length) await openPortalCapture(next[0], next.slice(1));
    }});
  }});
}
