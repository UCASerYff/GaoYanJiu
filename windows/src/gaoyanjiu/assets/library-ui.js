"use strict";

const FOLDER_PROMPTS = {
  experimentData: ["按项目创建文件夹，集中管理实验与分析文件", "Organize experiment and analysis files in project folders"],
  summaryReports: ["按主题或周期创建文件夹，整理周报、月报与汇报材料", "Organize reports and presentation materials by topic or period"],
  importantLiterature: ["按研究主题创建文件夹，保存重要参考资料", "Keep important references in folders by research topic"],
};
const libraryLanding = new Map();
function countLabel(count) { return tr(count + " 个文件", count + " files"); }
function exchangeContext(extra = {}) { return {api, refresh, folderID: state.folder, language: state.language, ...extra}; }
function newFolderButton(kind) {
  return button(tr("新建文件夹", "New folder"), () => editFolder(kind), {symbol: "folder", style: "primary", disabled: !state.writable});
}
function editFolder(kind, folder = null) {
  const name = field(tr("文件夹名称", "Folder name"), "name", folder?.name);
  name.querySelector("input").required = true;
  modal(folder ? tr("重命名文件夹", "Rename folder") : tr("新建文件夹", "New folder"), [name], {size: "compact",
    submit: async (values) => {
      await post("/api/documents/folder", {kind, id: folder?.id, name: values.name});
      closeDialog(); await refresh();
    }});
}
function deleteFolder(folder) {
  confirmTrash(tr("删除文件夹及其中的文件？", "Delete this folder and its files?"),
    tr("文件夹和文件会移入回收站，可在 30 天内恢复。", "The folder and its files can be recovered from Trash for 30 days."),
    async () => {
      await post("/api/documents/folder/trash", {id: folder.id});
      if (state.folder === folder.id) {
        libraryLanding.set(folder.libraryKind, "");
        state.folder = "";
        state.tag = "";
      }
    });
}
function folderActions(kind, folder) {
  return popover(tr("文件夹操作", "Folder actions"), "ellipsis", [
    button(tr("重命名", "Rename"), () => editFolder(kind, folder), {symbol: "edit", disabled: !state.writable}),
    button(tr("删除文件夹", "Delete folder"), () => deleteFolder(folder), {symbol: "trash", style: "danger", disabled: !state.writable}),
  ], true);
}
async function enterFolder(folder) {
  libraryLanding.set(folder.libraryKind, folder.id);
  state.folder = folder.id;
  state.tag = "";
  state.documentSort = "uploadedAt";
  $("main").scrollTop = 0;
  await render();
  safeFocus(document.querySelector(".file-pane-heading"));
}
function folderIndex(kind, folders, query, selectedFolder) {
  if (!folders.length) return emptyState("folder", query ? tr("没有匹配的文件夹", "No matching folders") : tr("还没有文件夹", "No folders yet"),
    query ? tr("试试其他名称、标签或正文关键词。", "Try another name, tag or full-text term.") : tr(...FOLDER_PROMPTS[kind]),
    ...(!query ? [newFolderButton(kind)] : []));
  return el("section", "library-folders",
    el("header", "library-pane-head",
      el("h2", "", tr("文件夹", "Folders")),
      query && !selectedFolder && el("span", "muted", tr(`${folders.length} 项匹配`, `${folders.length} matches`))),
    el("div", "library-folder-list", folders.map((folder) => {
      const selected = folder.id === selectedFolder;
      const enter = button(folder.name, () => enterFolder(folder), {symbol: "folder", style: "folder-button"});
      enter.title = folder.name;
      if (selected) enter.setAttribute("aria-current", "true");
      const row = el("article", "folder-card library-folder-row", enter,
        el("span", "folder-file-count muted", countLabel(folder.fileCount)),
        el("span", "folder-last-edit muted", formatDate(folder.updatedAt)),
        selected ? el("span", "folder-selected-mark", icon("arrow")) : folderActions(kind, folder));
      row.classList.toggle("is-selected", selected);
      return reorderItem(row, "folder", folder.id, !query);
    })));
}
async function importDocuments(folder, files) {
  if (!files.length) return;
  toast(tr(`正在导入 ${files.length} 个文件…`, `Importing ${files.length} files…`));
  let imported = 0;
  let existing = 0;
  const failures = [];
  for (const file of files) {
    try {
      const result = await uploadFile("/api/documents/import", file, {folderID: folder.id});
      imported += result.imported; existing += result.existing;
    } catch (error) { failures.push(file.name + " · " + error.message); }
  }
  await refresh();
  if (failures.length) throw new Error(failures.join("\n"));
  toast(tr("已导入 " + imported + " 项，已有 " + existing + " 项", imported + " imported, " + existing + " already present"));
}
function uploadDocumentButton(folder) {
  return button(tr("上传文件", "Upload files"), () => chooseFiles((files) => importDocuments(folder, files)),
    {symbol: "upload", style: "primary", disabled: !state.writable});
}
function importFromPath(folder) {
  const path = field(tr("本机文件的完整路径", "Full path to a local file"), "path");
  path.querySelector("input").required = true;
  modal(tr("从本机路径导入", "Import from local path"), [path], {size: "compact", submit: async (values) => {
    const result = await post("/api/documents/import-path", {folderID: folder.id, path: values.path.trim()});
    closeDialog(); await refresh();
    toast(result.existing ? tr("这个文件已在此文件夹中。", "This file is already in the folder.") : tr("文件已导入。", "File imported."));
  }});
}
function editDocument(document) {
  const name = field(tr("显示名称", "Display name"), "displayName", document.displayName);
  name.querySelector("input").required = true;
  modal(tr("编辑文件信息", "Edit file information"), [
    name, field(tr("标签，可用逗号分隔", "Tags, separated by commas"), "tags", (document.tags || []).join(", ")),
  ], {size: "compact", subtitle: document.originalName, submit: async (values) => {
    await post("/api/documents/update", {id: document.id, displayName: values.displayName, tags: formatTags(values.tags)});
    closeDialog(); await refresh();
  }});
}
function deleteDocument(document) {
  confirmTrash(tr("删除此文件？", "Delete this file?"),
    tr("「" + document.displayName + "」会移入回收站，可在 30 天内恢复。", document.displayName + " can be recovered from Trash for 30 days."),
    () => post("/api/documents/trash", {id: document.id}));
}
function fileSize(value) {
  const bytes = Number(value || 0);
  if (bytes < 1024) return bytes.toLocaleString() + " B";
  if (bytes < 1024 ** 2) return (bytes / 1024).toFixed(1) + " KiB";
  return (bytes / 1024 ** 2).toFixed(1) + " MiB";
}
async function previewDocument(document) {
  const media = storedPreview("document", document.folderID, document);
  const {text} = await api("/api/documents/text?" + new URLSearchParams({id: document.id}));
  const detail = el("div", "document-preview-content",
    el("div", "document-preview-metadata",
      el("span", "muted", document.originalName),
      el("span", "", fileSize(document.byteCount)),
      el("span", "", formatDate(document.uploadedAt, true))),
    document.tags?.length > 0 && el("div", "row", document.tags.map((tag) => badge(tag, "teal"))));
  if (media) detail.append(media);
  if (text) {
    const indexedText = el("details", "catalog-form-options", el("summary", "", tr("全文索引", "Indexed text")),
      el("p", "text-preview", text));
    indexedText.open = !media;
    detail.append(indexedText);
  }
  if (!media && !text) detail.append(el("p", "muted", tr("此文件可下载到本机打开。", "Download this file to open it on your computer.")));
  const pages = document.windowsProvenance?.pages || [];
  const source = document.windowsProvenance?.targetRecordID || document.windowsProvenance?.sourceDocumentID;
  if (source && pages.length && /\.pdf$/i.test(document.windowsProvenance?.sourceName || "")) {
    const originals = el("div", "row document-ocr-pages");
    const query = state.query.toLowerCase();
    for (const page of pages.filter((page) => !query || String(page.text || "").toLowerCase().includes(query))) {
      if (!Number.isSafeInteger(page.pageNumber) || page.pageNumber < 1) continue;
      originals.append(button(tr("原件第 " + page.pageNumber + " 页", "Original page " + page.pageNumber), async () => {
        const {original} = await api("/api/documents/ocr-source?" + new URLSearchParams({id: document.id}));
        modal(original.originalName, [
          storedPreview("document", original.folderID, original, page.pageNumber),
          page.text && el("p", "text-preview", page.text),
        ], {size: "wide", actions: [button(tr("返回 OCR 结果", "Back to OCR result"), () => previewDocument(document))]});
      }, {symbol: "document"}));
    }
    if (originals.childElementCount) detail.append(el("section", "catalog-detail-section",
      el("h3", "", tr("OCR 对应原件", "OCR source pages")), originals));
  }
  const actions = el("div", "row", downloadLink("document", document.folderID, document),
    button(tr("在文件资源管理器中显示", "Show in File Explorer"), () => post("/api/files/reveal", {kind: "document", ownerID: document.folderID, name: document.storedName}), {symbol: "folder"}));
  window.researchExchange?.document(actions, exchangeContext({document}));
  modal(document.displayName, [detail], {size: "wide", actions: [actions]});
}
function documentRow(document, manualOrder) {
  const buttons = el("div", "exchange-menu-staging");
  window.researchExchange?.document(buttons, exchangeContext({document}));
  const name = button(document.displayName, () => previewDocument(document), {style: "text-button"});
  const quickDownload = downloadLink("document", document.folderID, document);
  quickDownload.replaceChildren(icon("download"));
  quickDownload.classList.add("icon-button", "document-download");
  quickDownload.title = tr("下载", "Download");
  quickDownload.setAttribute("aria-label", quickDownload.title);
  const extension = document.fileExtension || "";
  const currentFilename = extension ? document.displayName + "." + extension : document.displayName;
  const originalLabel = document.originalName && document.originalName.toLowerCase() !== currentFilename.toLowerCase() && document.originalName;
  const imageFile = /^(png|jpe?g|gif|tiff?|webp|heic)$/i.test(extension);
  const tags = document.tags || [];
  const showOcr = document.windowsProvenance?.pages?.length > 0 && !tags.some((tag) => /^ocr\b/i.test(tag));
  const fileType = el("span", "library-document-type muted", extension.toUpperCase() || "—");
  if (extension) fileType.title = extension.toUpperCase();
  const orderMark = manualOrder && state.writable && el("span", "grip", icon("grip"));
  if (orderMark) orderMark.title = tr("拖动调整顺序", "Drag to reorder");
  return reorderItem(el("article", "document-row library-document-row",
    el("div", "catalog-item-name",
      el("span", "catalog-type-icon", icon(imageFile ? "image" : "document")),
      el("div", "record-summary", name, originalLabel && el("small", "muted", originalLabel),
      el("div", "record-meta", tags.map((tag) => badge(tag, "teal")), showOcr && badge("OCR")))),
    fileType,
    el("span", "library-document-size muted", fileSize(document.byteCount)),
    el("span", "library-document-date muted", formatDate(document.uploadedAt)),
    el("div", "catalog-row-actions", orderMark, quickDownload, popover(tr("文件操作", "File actions"), "ellipsis", [
      downloadLink("document", document.folderID, document),
      button(tr("在文件资源管理器中显示", "Show in File Explorer"), () => post("/api/files/reveal", {kind: "document", ownerID: document.folderID, name: document.storedName}), {symbol: "folder"}),
      button(tr("编辑文件信息", "Edit file information"), () => editDocument(document), {symbol: "edit", disabled: !state.writable}),
      ...buttons.children,
      button(tr("删除文件", "Delete file"), () => deleteDocument(document), {style: "danger", symbol: "trash", disabled: !state.writable}),
    ], true))), "document", document.id, manualOrder);
}
function folderContents(kind, folder, documents, tags, query) {
  const gears = el("div", "");
  window.researchExchange?.toolbar(gears, exchangeContext({folderID: folder.id}));
  const sort = selectField(tr("排序", "Sort"), "sort", state.documentSort, [
    ["uploadedAt", tr("上传时间", "Upload time")], ["tags", tr("标签", "Tags")],
  ]);
  sort.addEventListener("change", async (event) => {
    state.documentSort = event.target.value;
    await render();
    safeFocus(document.querySelector('.folder-toolbar [name="sort"]'));
  });
  const filter = selectField(tr("筛选标签", "Filter tags"), "tag", state.tag, [
    ["", tr("全部标签", "All tags")], ...tags.map(({label}) => [label, label]),
  ]);
  filter.querySelector("select").disabled = !tags.length;
  filter.addEventListener("change", async (event) => {
    state.tag = event.target.value;
    await render();
    safeFocus(document.querySelector('.folder-toolbar [name="tag"]'));
  });
  const displayed = (state.tag ? documents.filter((document) => document.tags?.includes(state.tag)) : documents).slice();
  if (state.documentSort === "tags") displayed.sort((a, b) => (a.tags?.[0] || "").localeCompare(b.tags?.[0] || "") || a.displayName.localeCompare(b.displayName));
  const heading = el("h2", "file-pane-heading", folder.name);
  heading.tabIndex = -1;
  const back = button(tr("返回文件夹", "Back to folders"), async () => {
    libraryLanding.set(kind, "");
    state.folder = "";
    state.tag = "";
    await render();
    safeFocus(document.querySelector(".folder-button"));
  }, {symbol: "back", style: "quiet"});
  const toolbar = el("header", "folder-toolbar library-pane-toolbar",
    el("div", "library-pane-title",
      back, el("div", "library-active-name", heading,
        el("small", "muted", displayed.length === folder.fileCount ? countLabel(folder.fileCount)
          : tr(`${displayed.length} / ${folder.fileCount} 个文件`, `${displayed.length} of ${folder.fileCount} files`)))),
    el("div", "library-primary-tools row", folderActions(kind, folder),
      popover(tr("资料交接", "Document handoff"), "link", [
      ...gears.children, button(tr("从本机路径导入", "Import from local path"), () => importFromPath(folder), {symbol: "folder", disabled: !state.writable}),
      ]), uploadDocumentButton(folder)),
    el("div", "library-file-filters row", sort, filter));
  const manualOrder = !query && !state.tag && state.documentSort === "uploadedAt";
  const contents = displayed.length ? el("div", "library-files-list",
    el("div", "library-file-columns", el("span", "", tr("文件名", "Filename")), el("span", "", tr("类型", "Type")),
      el("span", "", tr("大小", "Size")), el("span", "", tr("导入日期", "Imported"))),
    displayed.map((document) => documentRow(document, manualOrder)))
    : emptyState("document", query || state.tag ? tr("没有找到匹配的文件", "No matching files") : tr("文件夹中还没有文件", "This folder is empty"),
      query || state.tag ? tr("请更改搜索词或标签。", "Change the search term or tag.") : tr("可上传文件或将本机文件拖到这里。", "Upload files or drag local files here."),
      ...(!query && !state.tag ? [uploadDocumentButton(folder)] : []));
  const wrapper = el("section", "document-drop library-files", toolbar, contents);
  if (state.writable) {
    wrapper.addEventListener("dragover", (event) => {
      if (!event.dataTransfer.types.includes("Files")) return;
      event.preventDefault(); event.dataTransfer.dropEffect = "copy"; wrapper.classList.add("drop-target");
    });
    wrapper.addEventListener("dragleave", (event) => {
      if (!wrapper.contains(event.relatedTarget)) wrapper.classList.remove("drop-target");
    });
    wrapper.addEventListener("drop", (event) => {
      if (!event.dataTransfer.files.length) return;
      event.preventDefault(); wrapper.classList.remove("drop-target");
      importDocuments(folder, Array.from(event.dataTransfer.files)).catch(report);
    });
  }
  return wrapper;
}
async function pageDocuments(kind, query) {
  const requested = state.folder;
  const fetchContents = (folder) => api("/api/documents?" + new URLSearchParams({kind, folder, q: query, view: "folders"}));
  let data = await fetchContents(query ? "" : requested);
  const matches = query ? data.folders : null;
  if (query && requested && matches.length) {
    const matchedFolder = matches.find((entry) => entry.id === requested) || matches[0];
    data = await fetchContents(matchedFolder.id);
  } else if (!query && !data.folderID && data.folders.length && libraryLanding.get(kind) !== "") {
    const preferred = data.folders.find((entry) => entry.id === libraryLanding.get(kind));
    const first = preferred || data.folders.find((entry) => entry.fileCount > 0) || data.folders[0];
    data = await fetchContents(first.id);
  }
  const folder = data.folders.find((entry) => entry.id === data.folderID);
  if (state.page === kind && state.folder === requested && state.query === query) {
    if (!query) state.folder = folder?.id || "";
    if ((!query || folder) && state.tag && !data.tags.some((tag) => tag.label === state.tag)) state.tag = "";
  }
  const info = state.overview[kind];
  const tools = el("div", "row");
  if (!folder) window.researchExchange?.toolbar(tools, exchangeContext({folderID: ""}));
  tools.append(newFolderButton(kind));
  return {tools: [...tools.children], nodes: [
    dashboard(latestLabel(info.latest, ""), [
      [info.folders, tr("文件夹", "Folders"), "folder"], [info.count, tr("文件", "Files"), "document", "teal"], [info.tags, tr("标签", "Tags"), "tag", "clay"],
    ]),
    el("div", `library-workspace${folder ? " has-current-folder" : ""}`,
      folderIndex(kind, matches || data.folders, query, data.folderID),
      folder && folderContents(kind, folder, data.documents, data.tags, query)),
  ]};
}
