"use strict";

const TERMINAL = /accept|publish|reject|withdraw|declin|cancel|已接受|接收|录用|已发表|拒稿|已拒|撤稿|已撤/i;
const COMMON_STATUSES = ["已投稿", "初审中", "审稿中", "小修", "大修", "修回后审稿", "已接受", "已发表", "已拒稿", "已撤稿"];
let laterActionsExpanded = false;

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
function paperIsActive(paper) {
  return !paper.hidden && !TERMINAL.test(paper.status);
}
function currentPaperAction(paper) {
  const action = paper.nextAction;
  return action && typeof action.revision === "string" && typeof action.text === "string"
    && typeof action.dueDate === "string" && /^\d{4}-\d{2}-\d{2}$/.test(action.dueDate) ? action : null;
}
function paperActionDate(value) {
  const day = new Date(value + "T12:00:00");
  return Number.isFinite(day.getTime()) ? formatDate(day) : value;
}
function actionControl(key, label, run, options) {
  const control = button(label, run, options);
  control.dataset.nextAction = key;
  return control;
}
async function submitPaperAction(paper, operation, fields = {}) {
  return post("/api/papers/next-action", {key: paper.key, operation,
    revision: currentPaperAction(paper)?.revision || null, ...fields});
}
async function openPaperByKey(key) {
  const {paper} = await api("/api/papers/detail?" + new URLSearchParams({key}));
  return openPaperDetail(paper);
}
async function refreshPaperAction(key) {
  await refresh();
  await openPaperByKey(key);
  const heading = document.querySelector("#editor[open] .paper-next-action h2") || $("dialog-heading");
  if (heading) {
    heading.tabIndex = -1;
    safeFocus(heading);
  }
}
function openPaperActionEditor(paper) {
  const current = currentPaperAction(paper);
  const action = current?.completedAt ? null : current;
  const text = field(tr("具体行动", "Action"), "actionText", action?.text || "");
  const textInput = text.querySelector("input");
  textInput.required = true;
  textInput.maxLength = 240;
  textInput.placeholder = tr("例如：整理审稿意见并提交修订稿", "For example, submit the revised manuscript");
  const date = field(tr("截止日期", "Due date"), "dueDate", action?.dueDate || dateInput(), "date");
  date.querySelector("input").required = true;
  modal(action ? tr("编辑下一步行动", "Edit next action") : tr("设置下一步行动", "Set next action"),
    [text, date], {size: "compact paper-action-editor", subtitle: paper.title, submit: async ({actionText, dueDate}) => {
      await submitPaperAction(paper, "save", {text: actionText, dueDate});
      await refreshPaperAction(paper.key);
    }});
}
async function updatePaperAction(paper, operation) {
  await submitPaperAction(paper, operation);
  await refreshPaperAction(paper.key);
}
function removePaperAction(paper) {
  modal(tr("移除下一步行动？", "Remove the next action?"),
    [el("p", "submission-action-text", currentPaperAction(paper).text)], {size: "compact",
      dismissLabel: tr("取消", "Cancel"), actions: [
        button(tr("移除", "Remove"), () => updatePaperAction(paper, "remove"), {style: "danger"}),
      ]});
}
function paperNextAction(paper) {
  const action = currentPaperAction(paper);
  const active = paperIsActive(paper);
  if (!action && !active) return null;
  const complete = Boolean(action?.completedAt);
  const editLabel = complete ? tr("添加新行动", "Set a new action")
    : action ? tr("编辑行动", "Edit action") : tr("设置行动", "Set action");
  const panel = el("section", "card paper-next-action",
    el("div", "section-head", el("h2", "", tr("下一步行动", "Next action")),
      action && badge(complete ? tr("已完成", "Completed") : tr("未完成", "Open"), complete ? "teal" : "attention")));
  if (action) {
    const due = el("time", "", paperActionDate(action.dueDate));
    due.dateTime = action.dueDate;
    panel.append(el("p", "submission-action-text", action.text),
      el("div", "paper-action-dates", el("span", "", tr("截止", "Due"), " ", due),
        complete && el("span", "", tr("完成", "Completed"), " ", formatDate(action.completedAt, true))));
  }
  const controls = [
    active && actionControl("edit", editLabel, () => openPaperActionEditor(paper),
      {symbol: action && !complete ? "edit" : "plus", disabled: !state.writable}),
    action && !complete && actionControl("complete", tr("标记完成", "Mark complete"), () => updatePaperAction(paper, "complete"),
      {style: "primary", disabled: !state.writable}),
    action && complete && active && actionControl("reopen", tr("重新打开行动", "Reopen action"), () => updatePaperAction(paper, "reopen"),
      {disabled: !state.writable}),
    action && actionControl("remove", tr("移除行动", "Remove action"), () => removePaperAction(paper),
      {style: "quiet", disabled: !state.writable}),
  ].filter(Boolean);
  if (controls.length) panel.append(el("div", "row paper-action-controls", controls));
  return panel;
}
function submissionActionBoard(groups) {
  const labels = {
    overdue: tr("已逾期", "Overdue"), today: tr("今天到期", "Due today"),
    upcoming: tr("临近（7 天内）", "Upcoming (next 7 days)"), later: tr("稍后（7 天以后）", "Later (after 7 days)"),
  };
  const anyActions = Object.keys(labels).some((key) => groups[key]?.length);
  const sections = Object.entries(labels).filter(([key]) => key !== "later" || groups.later?.length).map(([key, label]) => {
    const later = key === "later";
    const items = groups[key] || [];
    const heading = el(later ? "summary" : "h3", "submission-action-heading", label, " ", el("span", "submission-action-count", items.length));
    const group = el(later ? "details" : "section", "submission-action-group", heading);
    if (later) {
      group.open = laterActionsExpanded;
      group.addEventListener("toggle", () => { laterActionsExpanded = group.open; });
    } else heading.tabIndex = -1;
    group.dataset.actionGroup = key;
    if (items.length) {
      group.append(el("ul", "submission-action-list", items.map((paper) => {
        const action = paper.nextAction;
        const due = el("time", "muted", paperActionDate(action.dueDate));
        due.dateTime = action.dueDate;
        const finish = actionControl("complete", tr("完成", "Complete"), async () => {
          await submitPaperAction(paper, "complete");
          await refresh();
          const header = document.querySelector('.submission-action-group[data-action-group="' + key + '"] .submission-action-heading');
          (header || document.querySelector(".submission-action-board h2"))?.focus();
        }, {style: "quiet", disabled: !state.writable});
        finish.setAttribute("aria-label", tr("完成行动", "Complete action") + " · " + action.text);
        return el("li", "submission-action-row",
          el("div", "submission-action-main", el("strong", "submission-action-text", action.text),
            button(paper.title, () => openPaperByKey(paper.key), {style: "text-button submission-action-paper"})),
          el("div", "submission-action-meta", due, finish));
      })));
    }
    return group;
  });
  const heading = el("h2", "", tr("下一步行动", "Next actions"));
  heading.tabIndex = -1;
  return el("section", "card submission-action-board", heading,
    el("div", "submission-action-groups", sections.slice(0, 3)), sections[3],
    !anyActions && el("p", "muted", tr("暂无未完成的行动。可在稿件详情中设置。", "No open actions. Set one in the manuscript details.")));
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
  ], {size: "paper-editor",
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
    paperNextAction(paper),
    events.length && card(tr("状态历史", "Status history"), "", logs),
    paper.submissionHistory && card(tr("备注与投稿历史", "Notes and submission history"), "", el("p", "text-preview", paper.submissionHistory)),
  ].filter(Boolean), {subtitle: paper.journal, actions});
}
function paperTone(paper, due) {
  if (/accept|publish|已接受|接收|录用|已发表/i.test(paper.status)) return "teal";
  if (due || paper.changed) return "attention";
  return TERMINAL.test(paper.status) ? "neutral" : "";
}
function paperProgress(paper) {
  const last = (paper.history || []).at(-1);
  return {
    title: paper.previousStatus ? `${paper.previousStatus} → ${paper.status}`
      : last?.status || paper.status,
    date: last?.checkedAt || paper.statusSince || paper.checkedAt,
  };
}
function paperRow(paper, due, canReorder, select) {
  const title = button(paper.title, () => select(paper), {style: "text-button"});
  title.dataset.paperKey = paper.key;
  title.setAttribute("aria-pressed", String(state.paperSelection === paper.key));
  const manual = paper.sourceID === "manual";
  const primary = manual ? button(tr("更新状态", "Update status"), () => openPaperEditor(paper),
    {style: "paper-update", disabled: !state.writable})
    : external(tr("打开稿件", "Open manuscript"), paper.url);
  const actions = popover(tr("论文操作", "Submission actions"), "ellipsis", [
    button(tr("查看详情", "View details"), () => openPaperDetail(paper), {symbol: "document"}),
    paperIsActive(paper) && button(tr("下一步行动", "Next action"), () => openPaperActionEditor(paper),
      {symbol: "calendar", disabled: !state.writable}),
    button(paper.hidden ? tr("恢复追踪", "Resume tracking") : tr("归档", "Archive"), () => archivePaper(paper), {symbol: "archive", disabled: !state.writable}),
    button(tr("删除", "Delete"), () => deletePaper(paper), {symbol: "trash", style: "danger", disabled: !state.writable}),
  ], true);
  const progress = paperProgress(paper);
  const action = currentPaperAction(paper);
  const days = statusDays(paper.statusSince);
  const row = el("article", "paper-row",
    el("div", "paper-identity", title, el("small", "muted", [paper.journal,
      displayedManuscript(paper)].filter(Boolean).join(" · ")),
    paperIsActive(paper) && action && !action.completedAt && el("small", "paper-action-hint",
      icon("calendar"), tr("行动截止 ", "Action due "), paperActionDate(action.dueDate))),
    el("div", "paper-stage", badge(paper.status, paperTone(paper, due)),
      paper.changed && badge(tr("有更新", "Updated"), "attention"),
      due && badge(tr("待跟进", "Follow up"), "attention"),
      el("small", "muted", tr(`${days} 天`, `${days} days`))),
    el("div", "paper-progress", el("span", "", progress.title), el("small", "muted", formatDate(progress.date))),
    el("div", "paper-actions", canReorder && state.writable && el("span", "grip", icon("grip")), primary, actions));
  return reorderItem(row, "paper", paper.key, canReorder);
}
function paperContext(papers, selected, due, select) {
  if (selected) {
    const steps = (selected.history || []).slice(-5).reverse();
    return el("section", "card paper-context is-selected",
      el("div", "section-head", el("h2", "", tr("稿件进度", "Manuscript progress")),
        button(tr("关闭稿件预览", "Close manuscript preview"), () => select(), {symbol: "close", iconOnly: true})),
      el("h3", "paper-context-title", selected.title),
      el("div", "row", badge(selected.status, paperTone(selected, due.has(selected.key))),
        due.has(selected.key) && badge(tr("待跟进", "Follow up"), "attention")),
      el("small", "muted", [selected.journal, displayedManuscript(selected)].filter(Boolean).join(" · ")),
      paperNextAction(selected),
      el("ol", "paper-events", steps.map((entry) => el("li", "", el("span", "", entry.status),
        el("small", "muted", formatDate(entry.checkedAt))))),
      button(tr("查看完整详情", "View full details"), () => openPaperDetail(selected), {symbol: "document"}));
  }
  const recent = papers.map((paper) => ({paper, ...paperProgress(paper)}))
    .sort((a, b) => (Date.parse(b.date) || 0) - (Date.parse(a.date) || 0)).slice(0, 5);
  return el("section", "card paper-context", el("h2", "", tr("最近进度", "Recent progress")),
    recent.length ? el("ul", "paper-events paper-recent", recent.map(({paper, title, date}) => el("li", "",
      button(paper.title, () => select(paper), {style: "text-button"}),
      el("small", "muted", [title, formatDate(date)].filter(Boolean).join(" · ")))))
      : el("p", "muted", tr("当前列表没有进度记录。", "There is no progress history in this list.")));
}
function tally(values) {
  const counts = new Map();
  for (const value of values) counts.set(value, (counts.get(value) || 0) + 1);
  return [...counts].map(([label, count]) => ({label, count}));
}
function submissionStatistics(papers) {
  const counts = tally(papers.map((paper) => paper.status || tr("未填写", "Unspecified")))
    .sort((a, b) => b.count - a.count || a.label.localeCompare(b.label));
  const durations = papers.map((paper) => {
    const count = statusDays(paper.statusSince);
    const terminal = TERMINAL.test(paper.status);
    const note = terminal ? "" : count >= 90 ? tr("超期", "Overdue") : count >= 60 ? tr("关注", "Watch") : "";
    return {label: paper.title + " · " + displayedManuscript(paper), count, note, tone: terminal ? "terminal" : note ? "clay" : ""};
  }).sort((a, b) => b.count - a.count || a.label.localeCompare(b.label));
  return el("div", "analytics-layout",
    chart(tr("当前投稿状态分布", "Current submission status"), tr("按当前列表中的论文状态自动统计", "Counts for the submissions in this list"), counts, {height: Math.max(190, counts.length * 30)}),
    chart(tr("各论文状态持续时间", "Time spent in current status"),
      tr("60–89 天标为关注，满 90 天标为超期。终态稿件不提醒。", "Watch at 60–89 days and overdue at 90 days. Completed submissions are excluded from reminders."),
      durations, {height: Math.max(220, durations.length * 32), unit: tr(" 天", " d")}));
}
async function pageSubmissions(_page, query) {
  const scope = state.scope;
  const [{papers, followUpKeys, nextActions}, {portals}] = await Promise.all([
    api("/api/papers?" + new URLSearchParams({scope, q: query})), api("/api/portals"),
  ]);
  const info = state.overview.submissions;
  const due = new Set(followUpKeys);
  const statuses = [...new Set([...papers.map((paper) => paper.status), state.paperStatus].filter(Boolean))].sort((a, b) => a.localeCompare(b));
  const visible = state.paperStatus ? papers.filter((paper) => paper.status === state.paperStatus) : papers;
  const inspector = el("aside", "submission-inspector");
  const rows = el("div", "submission-list");
  function updateInspector() {
    const selected = visible.find((paper) => paper.key === state.paperSelection);
    inspector.replaceChildren(paperContext(visible, selected, due, selectPaper), portalPanel(portals));
    rows.querySelectorAll("[data-paper-key]").forEach((item) => item.setAttribute("aria-pressed", String(item.dataset.paperKey === state.paperSelection)));
  }
  function selectPaper(paper = null) {
    if (paper && !inspector.getClientRects().length) return openPaperDetail(paper);
    state.paperSelection = paper?.key || "";
    const restore = !paper || inspector.contains(document.activeElement);
    updateInspector();
    if (restore) inspector.querySelector("button")?.focus();
  }
  const manual = () => openPaperEditor();
  const publisherPicker = () => openPortalPicker();
  const tabBar = el("div", "tabs");
  tabBar.setAttribute("role", "group");
  tabBar.setAttribute("aria-label", tr("投稿范围", "Submission scope"));
  const tabs = [
    ["all", tr("全部", "All"), info.count],
    ["changed", tr("有更新", "Updated"), info.changed],
    ["followup", tr("待跟进", "Follow up"), due.size],
    ["hidden", tr("已归档", "Archived"), info.hidden],
  ];
  for (const [key, label, count] of tabs) {
    const tab = button(label, async () => {
      Object.assign(state, {scope: key, paperStatus: "", paperSelection: ""});
      await render();
      document.querySelector(`.tabs [data-scope="${key}"]`)?.focus();
    });
    tab.dataset.scope = key;
    tab.setAttribute("aria-pressed", String(scope === key));
    tab.append(el("span", "tab-count", count));
    tabBar.append(tab);
  }
  const portalAction = button(tr("投稿门户", "Submission portals"), () => modal(tr("投稿门户", "Submission portals"),
    [portalPanel(portals, false)], {size: "compact"}), {symbol: "link"});
  const addition = button(tr("添加稿件", "Add manuscript"), manual, {symbol: "plus", style: "primary", disabled: !state.writable});
  const status = selectField(tr("状态筛选", "Filter by status"), "paperStatus", state.paperStatus,
    [["", tr("全部状态", "All statuses")], ...statuses.map((value) => [value, value])]);
  status.classList.add("paper-status-filter");
  status.addEventListener("change", async (event) => {
    Object.assign(state, {paperStatus: event.target.value, paperSelection: ""});
    await render();
    document.querySelector(".paper-status-filter select")?.focus();
  });
  updateInspector();
  rows.append(...(visible.length ? [
    el("div", "paper-table-head", ...[tr("稿件", "Manuscript"), tr("状态", "Status"), tr("最近进度", "Recent progress"),
      tr("操作", "Actions")].map((label) => el("span", "", label))),
    ...visible.map((paper) => paperRow(paper, due.has(paper.key), !query && !state.paperStatus && scope === "all", selectPaper)),
  ] : [emptyState(scope === "hidden" ? "archive" : "document",
    query || state.paperStatus ? tr("没有找到匹配的论文", "No matching submissions")
      : scope === "hidden" ? tr("归档中没有论文", "No archived submissions")
      : scope === "followup" ? tr("没有需要跟进的稿件", "No submissions need a follow-up")
      : scope === "changed" ? tr("暂时没有新的状态变化", "No status changes") : tr("还没有在投论文", "No submissions yet"),
    scope === "all" && !query && !state.paperStatus ? tr("手动建立记录，或从出版商系统导入。", "Add a record manually or import from a publisher portal.") : "",
    ...(scope === "all" && !query && !state.paperStatus ? [
      button(tr("从投稿系统导入", "Import from a portal"), publisherPicker, {symbol: "globe", disabled: !state.writable}),
    ] : []))]));
  return {tools: [portalAction, addition], nodes: [
    dashboard("", [
      [info.active, tr("仍在投", "In progress"), "paperplane", "teal"],
      [info.accepted, tr("已接受", "Accepted"), "seal"],
      [due.size, tr("待跟进", "Follow up"), "bell", "clay"],
    ]),
    submissionActionBoard(nextActions || {}),
    el("div", "submission-layout",
      el("section", "submission-board",
        el("div", "paper-filters", tabBar,
          el("div", "paper-filter-actions", papers.length > 0 && status,
            papers.length > 0 && button(tr("趋势", "Trends"), () => modal(tr("投稿统计与趋势", "Submission statistics and trends"),
              [submissionStatistics(visible)], {size: "wide"}), {symbol: "chart"}))), rows),
      inspector),
  ]};
}
function portalPanel(portals, wide = true) {
  const count = portals.length;
  const panel = el("section", "card stack portal-panel" + (wide ? " portal-wide" : ""),
    el("div", "section-head", wide && el("h2", "", tr("投稿门户", "Submission portals")),
      count > 0 && button(tr("添加投稿门户", "Add submission portal"), openPortalPicker, {iconOnly: wide, symbol: "plus", disabled: !state.writable})));
  if (!count) {
    panel.append(button(tr("从投稿系统导入", "Import from a portal"), openPortalPicker, {symbol: "link", disabled: !state.writable}));
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
    card(tr("选择投稿系统", "Choose a submission system"), tr("在内嵌投稿窗口登录并提取，再审核稿件后导入。", "Sign in in the embedded portal, extract submissions and review them before importing."),
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
    el("small", "muted", tr("请直接在投稿窗口登录。每个门户都有自己的浏览资料。", "Sign in directly in the submission portal. Each portal has its own browsing profile.")),
  ], {submit: async (values) => {
    const response = await post("/api/portals", {...values, id: portal?.id, identity: portal?.identity,
      publisherID: portal?.publisherID || publisher?.id || "custom"});
    const {portals} = await api("/api/portals");
    await refresh();
    await openPortalCapture(portals.find((row) => row.id === response.id));
  }});
}

async function openPortalCapture(portal, next = []) {
  if (!portal) return;
  const {available} = await api("/api/portals/browser");
  const native = button(tr("打开内嵌投稿门户", "Open embedded submission portal"), async () => {
    native.disabled = true;
    try { await watchEmbeddedPortal(portal, next); } finally { native.disabled = false; }
  }, {style: "primary", symbol: "globe", disabled: !available});
  native.dataset.portalNative = "";
  const manual = button(tr("从外部浏览器提取", "Capture from external browser"), () => openManualPortalCapture(portal, next), {symbol: "download"});
  manual.dataset.portalManual = "";
  modal(tr("导入投稿状态", "Import submission status"), [
    el("p", "", tr("在投稿窗口登录，打开稿件列表或详情，点击「提取稿件并审核」。选中的稿件需在此确认后导入。",
      "Sign in in the portal window, open the submission list or details, and click Extract for review. Confirm the selected submissions here to import them.")),
    !available && el("p", "muted", tr("当前程序没有内嵌投稿组件，可从外部浏览器提取。", "This build does not include the embedded portal. You can capture from an external browser.")),
    el("div", "row", native, manual),
    next.length ? el("small", "muted", tr("此后还有 " + next.length + " 个门户待刷新。", next.length + " more portals to refresh.")) : null,
  ], {subtitle: portal.name});
}

async function watchEmbeddedPortal(portal, next) {
  const {sessionId} = await post("/api/portals/browser/open", {id: portal.id});
  const waiting = el("p", "", tr("正在启动内嵌投稿门户…", "Starting the embedded submission portal…"));
  waiting.setAttribute("role", "status");
  modal(tr("内嵌投稿门户", "Embedded submission portal"), [
    waiting, el("small", "muted", tr("提取完成后将回到这里审核。", "Return here to review submissions after extraction.")),
  ], {subtitle: portal.name});
  const labels = {
    loading: ["投稿页面正在加载…", "The portal page is loading…"],
    "no-papers": ["尚未识别到稿件，请在投稿窗口打开稿件列表或详情。", "No submissions were detected. Open a submission list or details page in the portal window."],
    "different-origin": ["在登录后回到所选投稿门户，再提取稿件。", "After signing in, return to the selected portal to extract submissions."],
    "extract-failed": ["当前页面提取失败，请在投稿窗口重试。", "Extraction failed on this page. Try again in the portal window."],
    "navigation-failed": ["投稿页面加载失败，请在投稿窗口检查地址并重新载入。", "The portal page could not load. Check the address and reload in the portal window."],
    "missing-runtime": ["需要安装 Microsoft Edge WebView2 Runtime。", "Microsoft Edge WebView2 Runtime is required."],
    "unsupported-profile": ["Windows 策略改变了投稿资料位置，内嵌窗口已关闭。", "Windows policy redirected the isolated portal profile and the embedded window closed."],
    "cannot-initialize": ["内嵌投稿门户启动失败。", "The embedded submission portal could not start."],
  };
  const active = () => waiting.isConnected && $("editor").open;
  try {
    while (active()) {
      const result = await api("/api/portals/browser?" + new URLSearchParams({sessionId}));
      if (!active()) return;
      const label = labels[result.notice];
      if (result.state === "captured") {
        reviewPortalCapture(portal, result.capture, next);
        return;
      }
      if (["closed", "error"].includes(result.state)) {
        const message = label ? tr(...label) : tr("投稿窗口已关闭。", "The submission portal window closed.");
        const actions = [button(tr("重试", "Retry"), () => openPortalCapture(portal, next), {symbol: "globe"})];
        if (result.notice === "missing-runtime") actions.unshift(external(
          tr("获取 WebView2 Runtime", "Get WebView2 Runtime"), "https://developer.microsoft.com/microsoft-edge/webview2/#download"));
        modal(tr("内嵌投稿门户", "Embedded submission portal"), [el("p", "", message)], {subtitle: portal.name, actions});
        return;
      }
      waiting.textContent = label ? tr(...label) : result.state === "ready"
        ? tr("请在内嵌窗口打开稿件，再点击「提取稿件并审核」。", "Open your submissions in the embedded window, then click Extract for review.")
        : tr("正在启动内嵌投稿门户…", "Starting the embedded submission portal…");
      await new Promise((resolve) => setTimeout(resolve, 400));
    }
  } finally {
    await post("/api/portals/browser/close", {sessionId}).catch(() => {});
  }
}

let extractorScript;
async function openManualPortalCapture(portal, next) {
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
    reviewPortalCapture(portal, payload, next);
  }});
}

function reviewPortalCapture(portal, payload, next) {
  if (!Array.isArray(payload?.papers) || !payload.papers.length || payload.papers.length > 500)
    throw new Error(tr("没有提取到可用稿件。请登录并打开稿件列表。", "No usable submissions were captured. Sign in and open the submission list."));
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
}
