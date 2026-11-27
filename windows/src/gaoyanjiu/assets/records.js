"use strict";

const WORK_TYPES = {
  journalArticle: ["期刊论文", "Journal article"], conferencePaper: ["会议论文", "Conference paper"],
  graduationThesis: ["毕业论文", "Thesis"], book: ["专著", "Book"], bookChapter: ["书籍章节", "Book chapter"],
  patent: ["专利", "Patent"], dataset: ["数据集", "Dataset"], software: ["软件成果", "Software"], other: ["其他成果", "Other work"],
};
const PATENT_TYPES = {invention: ["发明专利", "Invention patent"], utilityModel: ["实用新型", "Utility model"], design: ["外观设计", "Design patent"]};
const AUTHOR_POSITIONS = {
  first: ["一作", "First author"], corresponding: ["通讯作者", "Corresponding author"], second: ["二作", "Second author"],
  third: ["三作", "Third author"], fourth: ["四作", "Fourth author"], fifth: ["五作", "Fifth author"], beyondFifth: ["五作+", "Beyond fifth"],
};
const ATTACHMENT_ACCEPT = "application/pdf,image/*,.tif,.tiff,.heic";
const catalogViews = {work: "records", certificate: "records"};
let workTypeFilter = "";

function localizedOptions(values) { return Object.entries(values).map(([key, label]) => [key, tr(...label)]); }
function valueLabel(values, key) { return values[key] ? tr(...values[key]) : key || ""; }
function workType(work) { return valueLabel(work.type === "patent" && work.patentType ? PATENT_TYPES : WORK_TYPES, work.patentType || work.type); }
function formatTags(text) {
  const seen = new Set();
  return String(text || "").split(/[,，、;；]/).map((item) => item.trim()).filter((item) => {
    if (!item || seen.has(item.toLowerCase())) return false;
    seen.add(item.toLowerCase());
    return true;
  });
}
function catalogHeader(kind, tools = []) {
  const selected = catalogViews[kind];
  const options = [["records", tr("记录", "Records")], ["analysis", tr("统计", "Analytics")]];
  const switcher = el("div", "catalog-switch", options.map(([view, label]) => {
    const tab = button(label, async () => {
      if (catalogViews[kind] === view) return;
      catalogViews[kind] = view;
      await render();
      safeFocus(document.querySelector(`[data-catalog-view="${view}"]`));
    }, {style: "quiet"});
    tab.dataset.catalogView = view;
    tab.setAttribute("aria-pressed", String(selected === view));
    return tab;
  }));
  switcher.setAttribute("role", "group");
  switcher.setAttribute("aria-label", tr("视图", "View"));
  return el("header", "catalog-toolbar", switcher,
    tools.length > 0 && el("div", "catalog-controls row", tools));
}
function yearsForWorks(works) {
  const years = works.map((item) => String(item.completedAt || "").slice(0, 4)).filter((year) => /^\d{4}$/.test(year));
  return tally(years).sort((a, b) => a.label.localeCompare(b.label));
}
function metricsPanel(metrics) {
  if (!metrics?.items?.length) return null;
  return card(tr("期刊评价", "Journal metrics"),
    [metrics.matchedJournalName, metrics.source, metrics.lookedUpAt && formatDate(metrics.lookedUpAt)].filter(Boolean).join(" · "),
    pairs(...metrics.items.map((metric) => [metric.label, metric.value])));
}
function workCard(work, sortable) {
  const title = button(work.title, () => viewWork(work), {style: "text-button"});
  const actions = popover(tr("成果操作", "Work actions"), "ellipsis", [
    button(tr("查看详情", "View details"), () => viewWork(work), {symbol: "document"}),
    button(tr("编辑", "Edit"), () => editWork(work), {symbol: "edit", disabled: !state.writable}),
    button(tr("添加附件", "Add attachments"), () => addRecordAttachments("work", work.id), {symbol: "clip", disabled: !state.writable}),
    button(tr("移入回收站", "Move to Trash"), () => deleteRecord("work", work), {symbol: "trash", style: "danger", disabled: !state.writable}),
  ], true);
  const attachments = work.attachments?.length || 0;
  const attachmentCount = button(String(attachments), () => viewWork(work), {symbol: "clip", style: "quiet"});
  attachmentCount.setAttribute("aria-label", tr(`查看附件（${attachments}）`, `View attachments (${attachments})`));
  const orderMark = sortable && state.writable && el("span", "grip", icon("grip"));
  if (orderMark) orderMark.title = tr("拖动调整顺序", "Drag to reorder");
  const metadata = [work.venue, work.authors, work.identifier].filter(Boolean).join(" · ");
  const authorPosition = valueLabel(AUTHOR_POSITIONS, work.authorPosition);
  const row = el("article", "work-row catalog-work-row",
    el("div", "catalog-item-name",
      el("span", "catalog-type-icon", icon(work.type === "patent" ? "seal" : "document")),
      el("div", "record-summary", title, metadata && el("div", "record-meta", metadata))),
    el("div", "catalog-category", el("span", "", workType(work)), authorPosition && el("small", "muted", authorPosition)),
    el("span", "catalog-date", formatDate(work.completedAt)),
    el("div", "catalog-attachments", attachmentCount),
    el("div", "catalog-row-actions", orderMark, actions));
  row.addEventListener("click", (event) => {
    if (!event.target.closest("button, details, a, .grip") && !window.getSelection()?.toString()) title.click();
  });
  return reorderItem(row, "work", work.id, sortable);
}
function workIndex(works, query) {
  const canReorder = !query && !workTypeFilter;
  return el("div", "catalog-work-list",
    el("div", "catalog-column-head", el("span", "", tr("成果名称", "Title")), el("span", "", tr("类型", "Type")),
      el("span", "", tr("日期", "Date")), el("span", "", tr("附件", "Attachments"))),
    works.map((work) => workCard(work, canReorder)));
}
async function pageWorks(_page, query) {
  const {works, analytics} = await api("/api/works?" + new URLSearchParams({q: query}));
  const info = state.overview.works;
  const newWork = () => button(tr("新建成果", "New work"), () => editWork(), {symbol: "plus", style: "primary", disabled: !state.writable});
  const stats = dashboard(latestLabel(info.latest, ""), [
    [info.count, tr("成果总数", "Works"), "seal"], [info.attachments, tr("附件", "Attachments"), "clip", "teal"],
    [info.thisYear, tr("本年成果", "Works this year"), "calendar", "clay"],
  ]);
  const records = catalogViews.work === "records";
  const types = selectField(tr("成果类型", "Work type"), "workTypeFilter", workTypeFilter,
    [["", tr("全部类型", "All types")], ...localizedOptions(WORK_TYPES)]);
  types.addEventListener("change", async (event) => {
    workTypeFilter = event.target.value;
    await render();
    safeFocus(document.querySelector('[name="workTypeFilter"]'));
  });
  const visible = workTypeFilter ? works.filter((work) => work.type === workTypeFilter) : works;
  const filtered = query || (records && workTypeFilter);
  const itemCount = filtered && el("span", "catalog-result-count muted",
    tr(`${records ? visible.length : works.length} 项匹配`, `${records ? visible.length : works.length} matches`));
  const body = (records ? visible.length : works.length) ? (records ? workIndex(visible, query) :
    el("div", "catalog-analysis",
      chart(tr("成果类别", "Works by category"), "", analytics.categories),
      chart(tr("期刊论文署名", "Journal article authorship"), "", analytics.authorPositions, {mark: "teal"}),
      chart(tr("年度趋势", "Works by year"), "", yearsForWorks(works), {mark: "teal"}))) :
    emptyState("seal", filtered ? tr("没有匹配的成果", "No matching works") : tr("还没有成果", "No works yet"),
      filtered ? tr("可调整筛选或尝试其他标题、作者和编号。", "Adjust filters or try another title, author or identifier.") : "",
      ...(!filtered ? [newWork()] : []));
  return {tools: [newWork()], nodes: [stats, el("section", "catalog-workspace",
    catalogHeader("work", [itemCount, records && types].filter(Boolean)), body)]};
}
function attachmentIdentity(kind, owner, attachment) {
  return {kind, ownerID: owner, attachmentID: attachment.id, name: attachment.storedName};
}
function previewAttachment(kind, owner, attachment, goBack) {
  modal(attachment.originalName || tr("附件", "Attachment"), [
    storedPreview(kind, owner, attachment) || el("p", "muted", tr("此格式可以下载并使用本机应用查看。", "Download this format to view it in a Windows app.")),
  ], {size: "wide", actions: [
    button(tr("返回记录", "Back to record"), goBack),
    button(tr("在文件资源管理器中显示", "Show in File Explorer"), () => post("/api/files/reveal", attachmentIdentity(kind, owner, attachment)), {symbol: "folder"}),
    downloadLink(kind, owner, attachment),
  ]});
}
function recordAttachments(kind, record, goBack) {
  const owner = record.id;
  const files = record.attachments || [];
  return el("section", "catalog-detail-section",
    el("div", "catalog-detail-head", el("h3", "section-title", tr("附件", "Attachments")),
      button(tr("添加附件", "Add attachments"), () => addRecordAttachments(kind, owner, true), {symbol: "clip", disabled: !state.writable})),
    files.length ? el("div", "catalog-attachments-list", files.map((attachment) => el("div", "line-item",
      el("div", "grow", button(attachment.originalName, () => previewAttachment(kind, owner, attachment, goBack), {symbol: "document", style: "text-button"}),
        el("small", "muted block", formatDate(attachment.addedAt))),
      downloadLink(kind, owner, attachment),
      button(tr("移入回收站", "Move to Trash"), () => confirmTrash(tr("删除此附件？", "Delete this attachment?"),
        tr("附件可在回收站恢复 30 天。", "The attachment can be recovered from Trash for 30 days."),
        () => post("/api/attachments/trash", attachmentIdentity(kind, owner, attachment))), {iconOnly: true, symbol: "trash", disabled: !state.writable}))))
      : el("p", "catalog-no-attachments muted", tr("还没有附件", "No attachments")));
}
function recordPath(kind) { return kind === "work" ? "/api/works" : "/api/certificates"; }
async function loadRecord(kind, id) {
  const result = await api(recordPath(kind));
  return (kind === "work" ? result.works : result.certificates).find((item) => item.id === id);
}
async function addRecordAttachments(kind, id, fromDetail = false) {
  chooseFiles(async (files) => {
    const failures = [];
    for (const file of files) {
      try { await uploadFile(recordPath(kind) + "/attachment", file, {ownerID: id}); }
      catch (error) { failures.push(file.name + " · " + error.message); }
    }
    await refresh();
    if (fromDetail) {
      const record = await loadRecord(kind, id);
      if (record) (kind === "work" ? viewWork : viewCertificate)(record);
    }
    if (failures.length) throw new Error(failures.join("\n"));
  }, ATTACHMENT_ACCEPT);
}
function deleteRecord(kind, record) {
  confirmTrash(kind === "work" ? tr("删除此成果及其附件？", "Delete this work and its attachments?")
    : tr("删除该证书记录及其附件？", "Delete this certificate and its attachments?"),
    tr("记录及附件移入回收站，可在 30 天内恢复。", "The record and attachments can be restored from Trash for 30 days."),
    () => post(recordPath(kind) + "/trash", {id: record.id}));
}
function viewWork(work) {
  modal(work.title, [
    el("section", "catalog-detail-section", pairs(
      [tr("类型", "Type"), workType(work)], [tr("日期", "Date"), formatDate(work.completedAt)],
      [tr("发表载体", "Venue"), work.venue], [tr("作者", "Authors"), work.authors],
      [tr("我的署名顺序", "My authorship position"), valueLabel(AUTHOR_POSITIONS, work.authorPosition)],
      [tr("索引编号", "Identifier"), work.identifier], ["ISSN", work.journalISSN],
      [tr("备注", "Notes"), work.notes]), external(tr("打开成果网页", "Open work website"), work.url)),
    metricsPanel(work.journalMetrics), recordAttachments("work", work, () => viewWork(work)),
  ], {size: "catalog-detail", actions: [
    button(tr("移入回收站", "Move to Trash"), () => deleteRecord("work", work), {style: "danger", symbol: "trash", disabled: !state.writable}),
    button(tr("编辑成果", "Edit work"), () => editWork(work), {symbol: "edit", disabled: !state.writable}),
  ]});
}
function saveWithAttachments(kind, persist, inputForm) {
  if (!inputForm.reportValidity()) return;
  chooseFiles(async (files) => {
    if (!files.length) return;
    const result = await persist(Object.fromEntries(new FormData(inputForm)));
    const failures = [];
    for (const file of files) {
      try { await uploadFile(recordPath(kind) + "/attachment", file, {ownerID: result.id}); }
      catch (error) { failures.push(file.name + " · " + error.message); }
    }
    await refresh();
    const record = await loadRecord(kind, result.id);
    if (record) (kind === "work" ? viewWork : viewCertificate)(record);
    else closeDialog();
    if (failures.length) throw new Error(failures.join("\n"));
  }, ATTACHMENT_ACCEPT);
}
async function editWork(work = null) {
  const title = field(tr("成果标题（必填）", "Work title (required)"), "title", work?.title);
  title.querySelector("input").required = true;
  const kind = selectField(tr("成果类型", "Work type"), "type", work?.type || "journalArticle", localizedOptions(WORK_TYPES));
  const patent = selectField(tr("专利类型", "Patent type"), "patentType", work?.patentType || (work ? "" : "invention"),
    [["", tr("未细分专利", "Unspecified patent")], ...localizedOptions(PATENT_TYPES)]);
  const venue = field(tr("期刊、会议、出版社或授权机构", "Journal, conference, publisher or authority"), "venue", work?.venue);
  const issn = field(tr("ISSN（可选）", "ISSN (optional)"), "journalISSN", work?.journalISSN);
  const secret = field("EasyScholar Secret Key", "secret", "", "password");
  const suggestionList = el("div", "journal-suggestions");
  const metricsView = el("div", "stack", metricsPanel(work?.journalMetrics));
  const lookupStatus = el("small", "muted");
  const keyStatus = el("small", "muted");
  let metrics = work?.journalMetrics || null;
  let lookupRunning = false;
  const saveKey = button(tr("保存密钥", "Save key"), async () => {
    const control = secret.querySelector("input");
    if (!control.value.trim()) throw new Error(tr("请输入 EasyScholar 密钥。", "Enter an EasyScholar key."));
    await post("/api/secrets/easyscholar", {secret: control.value});
    control.value = "";
    keyStatus.textContent = tr("密钥已保存", "Key saved");
  });
  const lookup = button(tr("自动检索期刊指标", "Look up journal metrics"), async () => {
    const input = secret.querySelector("input");
    const query = (issn.querySelector("input").value || venue.querySelector("input").value).trim();
    if (!query) throw new Error(tr("请输入期刊名称或 ISSN。", "Enter a journal name or ISSN."));
    lookupStatus.textContent = tr("正在检索…", "Looking up…");
    lookup.disabled = true;
    lookupRunning = true;
    try {
      if (input.value.trim()) await saveEasyScholar(input, keyStatus);
      const result = await post("/api/metrics/lookup", {query});
      metrics = result.metrics;
      metricsView.replaceChildren(metricsPanel(metrics));
      lookupStatus.textContent = tr("已检索期刊指标", "Journal metrics found");
    } catch (error) {
      lookupStatus.textContent = "";
      throw error;
    } finally { lookup.disabled = false; lookupRunning = false; }
  }, {symbol: "search"});
  const metricInputs = formGroup(tr("期刊评价", "Journal metrics"), issn,
    el("div", "form-columns", secret, el("div", "row", saveKey, external(tr("获取密钥", "Get a key"), "https://www.easyscholar.cc/user/open"))),
    keyStatus, el("div", "row", lookup, lookupStatus), metricsView);
  const journalOptions = el("details", "catalog-form-options", el("summary", "", tr("期刊评价与密钥", "Journal metrics and key")), metricInputs);
  const metadata = el("details", "catalog-form-options", el("summary", "", tr("索引与备注", "Identifiers and notes")),
    formGroup("", field(tr("DOI、ISBN、专利号或其他编号", "DOI, ISBN, patent or other identifier"), "identifier", work?.identifier),
      field(tr("成果网页链接（可选）", "Work website (optional)"), "url", work?.url),
      field(tr("备注", "Notes"), "notes", work?.notes, "area")));
  journalOptions.open = Boolean(work?.journalMetrics);
  const selectType = kind.querySelector("select");
  const updateType = () => {
    journalOptions.hidden = selectType.value !== "journalArticle";
    patent.hidden = selectType.value !== "patent";
    suggestionList.hidden = selectType.value !== "journalArticle";
  };
  selectType.addEventListener("change", updateType);
  let requestNumber = 0;
  let suggestionTimer;
  function invalidateMetrics() {
    metrics = null;
    metricsView.replaceChildren();
    lookupStatus.textContent = "";
  }
  issn.querySelector("input").addEventListener("input", invalidateMetrics);
  const venueInput = venue.querySelector("input");
  venueInput.addEventListener("input", () => {
    invalidateMetrics();
    clearTimeout(suggestionTimer);
    const query = venueInput.value.trim();
    const current = ++requestNumber;
    suggestionList.replaceChildren();
    if (selectType.value !== "journalArticle" || query.length < 2) return;
    suggestionTimer = setTimeout(async () => {
      try {
        const {suggestions} = await post("/api/metrics/suggest", {query});
        if (!suggestionList.isConnected || requestNumber !== current) return;
        suggestionList.replaceChildren(...suggestions.slice(0, 6).map((entry) => button(
          [entry.title, entry.issn, entry.publisher].filter(Boolean).join(" · "), () => {
            venueInput.value = entry.title;
            issn.querySelector("input").value = entry.issn || "";
            invalidateMetrics();
            suggestionList.replaceChildren();
          }, {symbol: "books"})));
      } catch (error) {
        if (suggestionList.isConnected && requestNumber === current) suggestionList.textContent = error.message;
      }
    }, 350);
  });
  const persist = (values) => {
    if (lookupRunning) throw new Error(tr("请等待期刊指标查询结束。", "Wait for the journal lookup to finish."));
    const {secret: discarded, ...payload} = values;
    return post("/api/works", {...payload, id: work?.id, journalMetrics: metrics});
  };
  const form = modal(work ? tr("编辑成果", "Edit work") : tr("新建成果", "New work"), [
    formGroup(tr("成果信息", "Work information"), title, el("div", "form-columns", kind, patent,
      field(tr("完成或发表日期", "Completion or publication date"), "completedAt", dateInput(work?.completedAt), "date")),
      venue, suggestionList, el("div", "form-columns", field(tr("作者（可选）", "Authors (optional)"), "authors", work?.authors),
      selectField(tr("我的署名顺序", "My authorship position"), "authorPosition", work?.authorPosition || "",
        [["", tr("未设置 / 不适用", "Unspecified / not applicable")], ...localizedOptions(AUTHOR_POSITIONS)]))),
    journalOptions, metadata,
  ], {size: "catalog-editor",
    actions: [button(tr("保存并添加附件", "Save and add attachments"), () => saveWithAttachments("work", persist, form), {symbol: "clip"})],
    submit: async (values) => { await persist(values); closeDialog(); await refresh(); }});
  updateType();
  const settings = await api("/api/settings");
  if (keyStatus.isConnected && settings.hasEasyScholarKey && !keyStatus.textContent) keyStatus.textContent = tr("已保存在 Windows 凭据中", "A key is stored on this Windows device");
}
async function saveEasyScholar(input, status) {
  await post("/api/secrets/easyscholar", {secret: input.value});
  input.value = "";
  status.textContent = tr("密钥已保存", "Key saved");
}

function compareCertificates(left, right) {
  const key = state.certificateSort;
  const value = (record) => key === "tags" ? (record.tags || []).join(" ") : record[key] || "";
  const difference = key === "attachments" ? (left.attachments?.length || 0) - (right.attachments?.length || 0)
    : value(left).localeCompare(value(right), state.language === "en" ? "en-US" : "zh-CN", {numeric: true});
  return (state.certificateDescending ? -difference : difference) || left.name.localeCompare(right.name);
}
function sortCertificates(key) {
  state.certificateDescending = state.certificateSort === key ? !state.certificateDescending : key === "eventDate";
  state.certificateSort = key;
}
const certificateColumns = [
  ["name", ["名称", "Name"]], ["eventDate", ["日期", "Date"]],
  ["tags", ["标签", "Tags"]], ["attachments", ["附件", "Attachments"]],
];
function certificatesTable(records) {
  const head = el("thead", "", el("tr", "", certificateColumns.map(([key, label]) => {
    const sorting = state.certificateSort === key;
    const sort = button(tr(...label), async () => {
      sortCertificates(key);
      await render();
      safeFocus(document.querySelector(`[data-cert-order="${key}"]`));
    }, {style: "text-button"});
    sort.dataset.certOrder = key;
    if (sorting) {
      const direction = el("span", "catalog-sort-direction", state.certificateDescending ? "↓" : "↑");
      direction.setAttribute("aria-hidden", "true");
      sort.append(direction);
    }
    const header = el("th", "", sort);
    header.scope = "col";
    if (sorting) header.setAttribute("aria-sort", state.certificateDescending ? "descending" : "ascending");
    return header;
  }), el("th", "catalog-actions-heading", tr("操作", "Actions"))));
  const table = el("table", "catalog-certificate-table", head, el("tbody", "", records.slice().sort(compareCertificates).map((record) => {
    const count = record.attachments?.length || 0;
    const attachments = button(String(count), () => viewCertificate(record), {symbol: "clip", style: "quiet"});
    attachments.setAttribute("aria-label", tr(`查看附件（${count}）`, `View attachments (${count})`));
    const tags = record.tags || [];
    const visibleTags = tags.length ? el("div", "row", tags.slice(0, 3).map((tag) => badge(tag, "teal")),
      tags.length > 3 && el("small", "muted", "+" + (tags.length - 3))) : el("span", "muted", "—");
    const actions = popover(tr("证书操作", "Certificate actions"), "ellipsis", [
      button(tr("编辑", "Edit"), () => editCertificate(record), {symbol: "edit", disabled: !state.writable}),
      button(tr("添加附件", "Add attachments"), () => addRecordAttachments("certificate", record.id), {symbol: "clip", disabled: !state.writable}),
      button(tr("移入回收站", "Move to Trash"), () => deleteRecord("certificate", record), {symbol: "trash", style: "danger", disabled: !state.writable}),
    ], true);
    return el("tr", "",
      el("td", "catalog-cert-name", el("div", "catalog-item-name",
        el("span", "catalog-type-icon", icon("certificate")), button(record.name, () => viewCertificate(record), {style: "text-button"}))),
      el("td", "catalog-cert-date muted", formatDate(record.eventDate)), el("td", "catalog-cert-tags", visibleTags),
      el("td", "catalog-cert-attachments", attachments), el("td", "catalog-cert-actions", actions));
  })));
  return el("div", "table-wrap catalog-certificate-list", table);
}
function smallCertificateSort() {
  const ar = certificateColumns.map(([key, label]) => [key, tr(...label)]);
  const sort = selectField(tr("排序", "Sort"), "certificateSort", state.certificateSort, ar);
  sort.addEventListener("change", async (event) => {
    sortCertificates(event.target.value);
    await render();
    safeFocus(document.querySelector('[name="certificateSort"]'));
  });
  const ascending = tr("升序", "Ascending");
  const descending = tr("降序", "Descending");
  const direction = button(state.certificateDescending ? descending : ascending, async () => {
    sortCertificates(state.certificateSort);
    await render();
    safeFocus(document.querySelector("[data-certificate-direction]"));
  }, {style: "quiet"});
  direction.dataset.certificateDirection = "";
  return el("div", "catalog-small-sort row", sort, direction);
}
async function pageCertificates(_page, query) {
  const {certificates, analytics} = await api("/api/certificates?" + new URLSearchParams({q: query}));
  const info = state.overview.certificates;
  const newCertificate = () => button(tr("新建证书记录", "New certificate"), () => editCertificate(), {symbol: "plus", style: "primary", disabled: !state.writable});
  const stats = dashboard(latestLabel(info.latest, ""), [
    [info.count, tr("记录总数", "Records"), "certificate"], [info.tags, tr("标签种类", "Tags"), "tag", "teal"],
    [info.attachments, tr("附件", "Attachments"), "clip", "clay"],
  ]);
  const records = catalogViews.certificate === "records";
  const tools = [query && el("span", "catalog-result-count muted", tr(`${certificates.length} 项匹配`, `${certificates.length} matches`)),
    records && certificates.length > 0 && smallCertificateSort()].filter(Boolean);
  const body = certificates.length ? (records ? certificatesTable(certificates) : el("div", "catalog-analysis",
      chart(tr("年度趋势", "Certificates by year"), "", analytics.years),
      chart(tr("标签分布", "Certificate tags"), "", analytics.tags, {mark: "teal"})))
    : emptyState("certificate", query ? tr("没有匹配的证书", "No matching certificates") : tr("还没有证书", "No certificates yet"),
    query ? tr("试试使用其他名称、标签或附件名称。", "Try a different name, tag or attachment filename.") : "",
    ...(!query ? [newCertificate()] : []));
  return {tools: [newCertificate()], nodes: [stats, el("section", "catalog-workspace", catalogHeader("certificate", tools), body)]};
}
function editCertificate(record = null) {
  const name = field(tr("名称（必填）", "Name (required)"), "name", record?.name);
  name.querySelector("input").required = true;
  const tags = field(tr("自定义标签，可用逗号分隔", "Custom tags, separated by commas"), "tags", (record?.tags || []).join(", "));
  const choices = [["竞赛", "Competition"], ["文体", "Culture and sport"], ["任职", "Appointment"], ["荣誉", "Honor"], ["培训", "Training"], ["资质", "Qualification"]];
  const tagInput = tags.querySelector("input");
  const shortcuts = el("div", "row catalog-tag-suggestions", choices.map((entry) => button(tr(...entry), () => {
    tagInput.value = formatTags(tagInput.value + "," + tr(...entry)).join(", ");
  }, {style: "quiet"})));
  const persist = (values) => post("/api/certificates", {...values, id: record?.id, tags: formatTags(values.tags)});
  const form = modal(record ? tr("编辑证书记录", "Edit certificate") : tr("新建证书记录", "New certificate"), [
    formGroup(tr("基本信息", "Basic information"), name, field(tr("日期", "Date"), "eventDate", dateInput(record?.eventDate), "date")),
    formGroup(tr("标签", "Tags"), tags, shortcuts),
  ], {size: "catalog-editor",
    actions: [button(tr("保存并添加附件", "Save and add attachments"), () => saveWithAttachments("certificate", persist, form), {symbol: "clip"})],
    submit: async (values) => { await persist(values); closeDialog(); await refresh(); }});
}
function viewCertificate(record) {
  modal(record.name, [
    el("section", "catalog-detail-section", pairs([tr("日期", "Date"), formatDate(record.eventDate)],
      [tr("最近更新", "Last updated"), formatDate(record.updatedAt, true)]),
      record.tags?.length > 0 && el("div", "row", record.tags.map((tag) => badge(tag, "teal")))),
    recordAttachments("certificate", record, () => viewCertificate(record)),
  ], {size: "catalog-detail", actions: [
    button(tr("编辑", "Edit"), () => editCertificate(record), {symbol: "edit", disabled: !state.writable}),
    button(tr("移入回收站", "Move to Trash"), () => deleteRecord("certificate", record), {symbol: "trash", style: "danger", disabled: !state.writable}),
  ]});
}
