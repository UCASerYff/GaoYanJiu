"use strict";

(() => {
  const ACTIONS = {
    "ocr.files": ["文字识别（OCR）", "Text Recognition (OCR)"],
    "files.choose": ["选择文件", "Choose Files"],
    "documents.open": ["打开编辑副本", "Open an Editing Copy"],
    "research.importDocuments": ["导入资料", "Import Documents"],
  };
  const STATUS = {
    pending: ["待审核", "Needs Review"], expired: ["已过期", "Expired"], received: ["已接收", "Received"],
    completed: ["完成", "Completed"], partial: ["部分完成", "Partial"], failed: ["失败", "Failed"],
    cancelled: ["已取消", "Cancelled"], unsupported: ["不支持", "Unsupported"],
    lowConfidence: ["低置信度", "Low Confidence"], interrupted: ["可以恢复导入", "Import Can Resume"],
  };
  const IMAGE = new Set(["png", "jpg", "jpeg", "tif", "tiff", "gif", "webp", "heic", "heif"]);
  const EDITABLE = new Set(["pdf", "txt", "md", "json"]);
  let pendingOcr = [];

  function label(dictionary, key) {
    return dictionary[key] ? tr(...dictionary[key]) : key || "—";
  }
  function send(ctx, action, body) {
    return ctx.api("/api/exchange/" + action, {
      method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(body),
    });
  }
  function upload(ctx, action, body) {
    return ctx.api("/api/exchange/" + action, {method: "POST", body});
  }
  function details(title, content) {
    return el("details", "form-group", el("summary", "", title), el("div", "stack", content));
  }
  function displayPath(path) {
    const control = el("input");
    control.readOnly = true;
    control.value = path;
    control.addEventListener("focus", () => control.select());
    return el("label", "field", el("span", "field-label", tr("交接包路径", "Package Path")), control);
  }
  function localDate(value) {
    return new Date(value).toLocaleString(state.language === "en" ? "en" : "zh-CN");
  }
  function check(labelText, name) {
    const input = el("input");
    input.type = "checkbox";
    input.name = name;
    return el("label", "row", input, el("span", "", labelText));
  }
  function errorMessage(result) {
    if (state.language !== "en") return result.message;
    if (result.message.startsWith("已将交接包")) return "Package opened in its provider for review.";
    if (result.message.startsWith("提供方未安装")) return "The provider is missing. The request package is still available.";
    if (result.message.startsWith("提供方版本")) return "The provider's capabilities do not match. The request package is still available.";
    if (result.message.startsWith("未能启动")) return "Could not open the provider. The request package is still available.";
    if (result.message.startsWith("已导出")) return "The receipt was exported.";
    return result.message;
  }
  function setPending(items) {
    const next = Array.isArray(items) ? items : [];
    const changed = JSON.stringify(next) !== JSON.stringify(pendingOcr);
    pendingOcr = next;
    return changed;
  }
  function pendingForDocument(id) {
    return pendingOcr.filter((item) => item.sourceDocumentIDs?.includes(id));
  }
  function pendingButton(ctx, row) {
    const items = pendingForDocument(row.id);
    if (!items.length) return null;
    const caption = items.length === 1 ? tr("OCR 待审核", "OCR to review")
      : tr(`OCR 待审核（${items.length}）`, `OCR to review (${items.length})`);
    const show = () => {
      const current = pendingForDocument(row.id);
      if (current.length === 1) return review(ctx, current[0].id, [], {
        back: ctx.returnToDocument,
        backLabel: tr("返回原件", "Back to original"),
      });
      return openPending({...ctx, document: row}, current);
    };
    const action = button(caption, show, {style: "ocr-pending-button", symbol: "document"});
    action.dataset.pendingOcrDocument = row.id;
    return action;
  }
  async function openPending(ctx, items) {
    if (!items) {
      const result = await ctx.api("/api/exchange/ocr-returns");
      setPending(result.pending);
      items = ctx.document ? pendingForDocument(ctx.document.id) : pendingOcr;
    }
    const rows = items.map((item) => {
      const heading = item.sourceNames?.join("、") || ctx.document?.displayName || tr("OCR 结果", "OCR result");
      const action = button(tr("审核结果", "Review result"), () => review(ctx, item.id, [], {
        back: () => openPending(ctx), backLabel: tr("返回待审核", "Back to pending review"),
      }), {symbol: "open"});
      action.dataset.ocrReview = item.id;
      return el("article", "ocr-queue-row",
        el("div", "ocr-queue-title", el("strong", "", heading),
          el("small", "muted", [localDate(item.createdAt), label(STATUS, item.providerStatus || item.status)].filter(Boolean).join(" · "))),
        action);
    });
    modal(tr("OCR 待审核", "OCR pending review"), [
      rows.length ? el("div", "ocr-queue-list", rows)
        : emptyState("document", tr("暂无待审核的 OCR 结果", "No OCR results to review"), ""),
    ], {size: "wide", actions: ctx.returnToDocument
      ? [button(tr("返回原件", "Back to original"), ctx.returnToDocument, {symbol: "back"})] : []});
  }
  async function prepared(ctx, action, parameters) {
    const result = await send(ctx, "prepare", {action, ...parameters, ...(action === "ocr.files" ? {autoReturn: true} : {})});
    if (action === "ocr.files") await ctx.refresh();
    toast(errorMessage(result));
    modal(label(ACTIONS, action), [
      el("p", "", errorMessage(result)), displayPath(result.path),
      el("p", "muted", tr("有效期至 ", "Expires at ") + localDate(result.expiresAt)),
      action === "ocr.files" && el("p", "muted", result.autoReturn
        ? tr("搞操作导出后，可在原件和「OCR 待审核」中核对结果。",
          "After export in GaoCaoZuo, review the result on the original or in OCR pending review.")
        : tr("请在「资料交接」中载入搞操作导出的结果包。", "Load the result package from GaoCaoZuo in Document Handoffs.")),
    ], {actions: [button(tr("在资源管理器中显示", "Show in Explorer"), () => send(ctx, "reveal", {id: result.requestID}), {symbol: "folder"})]});
  }
  function launch(ctx, action, parameters, title) {
    const description = action === "ocr.files"
      ? tr("发送原件副本。在搞操作内选择识别范围和语种并导出。回传结果在原件处审核，确认后才导入。",
        "Send a copy of the original. Choose the scope and languages in GaoCaoZuo and export. Review the returned result on the original before importing it.")
      : tr("发送所选原件的副本。在搞文件中打开并导出编辑副本后，回到此条目导入。", "Send a copy of the selected file. After editing and exporting it in GaoWenJian, return here to import it.");
    modal(title, [el("p", "", description)], {
      submitLabel: tr("发送请求", "Send Request"), submit: () => prepared(ctx, action, parameters),
    });
  }
  async function open(ctx) {
    const overview = await ctx.api("/api/exchange/overview");
    const path = field(tr("交接目录的完整路径", "Full Path to Handoff Folder"), "path");
    const zip = field(tr("或选择交接 ZIP 文件", "Or Choose a Handoff ZIP"), "file", "", "file");
    zip.querySelector("input").accept = ".zip,.gaoaction";
    const incoming = overview.incoming.map((item) =>
      el("div", "form-group stack", el("strong", "", label(ACTIONS, item.action)),
        el("span", "muted", `${item.sourceBundleID} · ${localDate(item.createdAt)} · ${label(STATUS, item.status)}`),
        button(tr("查看交接…", "View Handoff…"), () => review(ctx, item.id, overview.folders), {symbol: "open"})));
    const outgoing = overview.outgoing.map((item) => el("div", "form-group stack", el("strong", "", label(ACTIONS, item.action)),
      el("span", "muted", `${item.targetBundleID} · ${localDate(item.createdAt)}`),
      displayPath(item.path),
      button(tr("在资源管理器中显示", "Show in Explorer"), () => send(ctx, "reveal", {id: item.id}), {symbol: "folder"})));
    modal(tr("资料交接与回执", "Document Handoffs & Receipts"), [
      path, zip,
      el("div", "row", button(tr("读取并复核…", "Open for Review…"), async () => {
        const selected = zip.querySelector("input").files[0];
        const localPath = path.querySelector("input").value.trim();
        if (Boolean(selected) === Boolean(localPath)) throw new Error(tr("请指定一个交接目录或 ZIP。", "Choose one handoff folder or ZIP."));
        let result;
        if (selected) {
          const body = new FormData();
          body.append("file", selected);
          result = await upload(ctx, "receive", body);
        } else {
          result = await send(ctx, "receive", {path: localPath});
        }
        if (result.action === "ocr.files") await ctx.refresh();
        await review(ctx, result.id, overview.folders);
      }, {symbol: "open", style: "primary"})),
      pendingOcr.length > 0 && button(tr("OCR 待审核", "OCR pending review"), () => openPending(ctx), {symbol: "document"}),
      details(tr("收到的交接", "Incoming"), incoming.length ? incoming : el("p", "muted", tr("暂无收件", "No incoming handoffs"))),
      details(tr("发出的请求", "Outgoing Requests"), outgoing.length ? outgoing : el("p", "muted", tr("暂无请求", "No outgoing requests"))),
    ], {size: "wide"});
    document.querySelector("#editor details")?.setAttribute("open", "");
  }
  function pageRows(pages, sourceButton) {
    return pages.map((page) => {
      const number = tr(`第 ${page.pageNumber} 页`, `Page ${page.pageNumber}`);
      const status = label(STATUS, page.status) + (page.confidence === undefined ? "" : ` · ${Math.round(page.confidence * 100)}%`);
      const row = el("article", "ocr-review-page",
        el("div", "ocr-review-page-head", el("strong", "", number), el("small", "muted", status), sourceButton?.(page, number)),
        page.failureReason && el("p", "muted", page.failureReason),
        page.text && el("pre", "ocr-page-text", page.text));
      row.dataset.ocrPage = String(page.pageNumber);
      return row;
    });
  }
  function reviewSource(ctx, id, source) {
    const preview = el("section", "ocr-review-preview");
    const pages = source.pages || [];
    let request = 0;
    let previousButton;
    const closePreview = () => {
      ++request;
      preview.hidden = true;
      preview.replaceChildren();
      safeFocus(previousButton);
    };
    preview.hidden = true;
    const sourceButton = source.sourceItemID && ((page, number) => {
      const open = button(tr("查看原件", "View original"), async () => {
        const current = ++request;
        previousButton = open;
        const query = new URLSearchParams({id, sourceItemID: source.sourceItemID});
        open.closest(".ocr-review-page").append(preview);
        preview.replaceChildren(el("p", "muted", tr("正在读取原件…", "Loading original…")));
        preview.hidden = false;
        let original;
        try {
          ({original} = await ctx.api("/api/exchange/ocr-source?" + query));
        } catch (error) {
          if (current !== request || !preview.isConnected) return;
          const alert = el("p", "muted", error.message);
          alert.setAttribute("role", "alert");
          preview.replaceChildren(alert, button(tr("收起原件", "Hide original"), closePreview, {style: "quiet"}));
          return;
        }
        if (current !== request || !preview.isConnected) return;
        const file = {...original, ocrReview: id, ocrItem: source.sourceItemID};
        const media = storedPreview("document", file.folderID, file, page.pageNumber);
        const title = el("h4", "", tr("原件", "Original") + " · " + number);
        title.tabIndex = -1;
        preview.replaceChildren(el("div", "ocr-review-page-head", title,
          button(tr("收起原件", "Hide original"), closePreview, {style: "quiet", symbol: "close"})),
          media || el("p", "muted", tr("此格式可从资料库下载查看。", "Download this format from the library to view it.")));
        preview.scrollIntoView({block: "nearest"});
        safeFocus(title);
      }, {style: "quiet", symbol: "open"});
      open.dataset.ocrOpenPage = String(page.pageNumber);
      open.setAttribute("aria-label", tr("查看原件", "View original") + " · " + number);
      return open;
    });
    return el("section", "ocr-review-source",
      el("header", "ocr-review-source-head",
        el("h3", "", source.sourceName || tr("原件", "Original")),
        el("small", "muted", tr(`${pages.length} 页`, `${pages.length} pages`))),
      ...pageRows(pages, sourceButton || undefined),
      details(tr("原件校验值", "Original checksum"), el("code", "", source.sha256)));
  }
  async function review(ctx, id, folders, navigation = {}) {
    const item = await ctx.api("/api/exchange/review?id=" + encodeURIComponent(id));
    const isOcr = item.action === "ocr.files";
    const folderValues = [["", tr("选择资料夹", "Select a Folder")], ...folders.map((folder) => [folder.id, `${PAGE_LABELS[folder.libraryKind] ? pageLabel(folder.libraryKind) + " / " : ""}${folder.name}`])];
    const locked = folders.some((folder) => folder.id === item.folderID);
    const selected = locked ? item.folderID : folders.find((folder) => folder.id === ctx.folderID)?.id || "";
    const folderField = selectField(tr("导入到资料夹", "Import into Folder"), "folderID", selected, folderValues);
    if (locked) folderField.querySelector("select").disabled = true;
    const requiresExtra = !item.resuming && (item.providerStatus === "partial" || item.warnings.length > 0);
    const chosen = item.references.map((reference) => field(reference.name, "file-" + reference.id));
    const actions = [button(navigation.backLabel || tr("返回交接", "Back to Handoffs"),
      navigation.back || (() => open(ctx)), {symbol: "back"})];
    if (item.canReject) actions.push(button(tr("拒绝并取消…", "Reject and Cancel…"), () => {
      modal(tr("拒绝此交接？", "Reject This Handoff?"), [el("p", "", tr("发送方可收到取消回执。", "The sender can receive a cancelled receipt."))], {
        submitLabel: tr("确认拒绝", "Confirm Rejection"), submit: async () => {
          await send(ctx, "reject", {id, confirm: true});
          await review(ctx, id, folders, navigation);
        },
      });
    }, {style: "danger"}));
    if (item.canExportReceipt) actions.push(button(tr("回执…", "Receipt…"), () => {
      modal(tr("研究资料交接回执", "Research Document Receipt"), [
        el("p", "", tr("当前业务状态", "Current Business Status") + " · " + label(STATUS, ["expired", "interrupted"].includes(item.status) ? "pending" : item.status)),
        field(tr("导出目录，可留空使用应用目录", "Export Folder, or Leave Blank"), "directory"),
        check(tr("交给搞文件打开回执", "Open Receipt in GaoWenJian"), "launch"),
      ], {submitLabel: tr("导出回执", "Export Receipt"), submit: async (values) => {
        const result = await send(ctx, "receipt", {id, directory: values.directory.trim(), launch: Boolean(values.launch)});
        modal(tr("研究资料交接回执", "Research Document Receipt"), [
          el("p", "", errorMessage(result)), displayPath(result.path),
        ], {actions: [button(tr("返回复核", "Back to Review"), () => review(ctx, id, folders, navigation))]});
      }});
    }, {symbol: "upload"}));
    const files = item.items.map((entry) => {
      const output = item.outputs.find((row) => row.itemID === entry.id);
      return el("div", "form-group stack", el("strong", "", entry.name),
        el("span", "muted", entry.byteCount.toLocaleString() + " B"),
        output && el("span", "", `${output.sourceName} · ${output.engine || "—"}${output.engineVersion ? " " + output.engineVersion : ""}${output.languages?.length ? " · " + output.languages.join(", ") : ""}`),
        el("code", "", entry.sha256));
    });
    const acknowledgment = item.canApply && requiresExtra
      && check(tr("我已复核部分结果及缺失来源", "I Reviewed Partial Results and Missing Metadata"), "acceptPartial");
    const body = [
      el("p", "muted", `${item.sourceBundleID} · ${label(STATUS, item.status)}${item.providerStatus ? " · " + label(STATUS, item.providerStatus) : ""}`),
      item.errorCode && el("p", "muted", item.errorCode),
      isOcr && item.canApply && !item.resuming && el("p", "ocr-review-note",
        tr("请核对原件和识别文字。确认导入后，识别文字才会进入资料库和搜索索引。",
          "Review the original and its recognized text. Confirmation adds the result to the library and search index.")),
      item.action === "documents.open" && el("p", "", tr("这是打开副本的回执。导出后，请在原条目中选择「导入编辑新版本…」。", "This receipt describes opening the copy. After export, choose Import Edited Version on the original record.")),
      item.warnings.map((warning) => el("p", "muted", warning)),
      item.sources.map((source) => reviewSource(ctx, id, source)),
      isOcr && files.length ? details(tr("导出文件及校验值", "Output files and checksums"), files) : files,
      item.references.map((reference, index) => el("div", "form-group stack",
        el("strong", "", reference.name), el("span", "muted", reference.fileURL), item.canApply && !item.resuming && chosen[index])),
      item.canApply && item.action !== "ocr.files" && folderField,
      acknowledgment,
      item.counts && el("p", "", tr(`导入 ${item.counts.imported} 项，已有 ${item.counts.existing} 项`, `Imported ${item.counts.imported}, existing ${item.counts.existing}`)),
    ];
    modal(isOcr && item.canApply ? tr("审核 OCR 结果", "Review OCR result") : label(ACTIONS, item.action), body, {
      size: "wide", actions, submitLabel: item.resuming ? tr("恢复已批准导入", "Resume Approved Import") : tr("确认导入", "Confirm Import"),
      submit: item.canApply ? async (values) => {
        if (requiresExtra && !values.acceptPartial) {
          acknowledgment.scrollIntoView({block: "nearest"});
          safeFocus(acknowledgment.querySelector("input"));
          throw new Error(tr("请先复核并确认部分结果或缺失来源。", "Review and acknowledge partial results or missing metadata."));
        }
        const target = item.action === "ocr.files" ? "" : locked ? item.folderID : values.folderID;
        if (item.action !== "ocr.files" && !target) throw new Error(tr("请选择导入资料夹。", "Select a destination folder."));
        const references = item.resuming ? {} : Object.fromEntries(item.references.map((reference) => [reference.id, values["file-" + reference.id].trim()]));
        const result = await send(ctx, "apply", {id, confirm: true, folderID: target, references, acceptPartial: Boolean(values.acceptPartial)});
        await ctx.refresh();
        toast(tr(`已导入 ${result.imported} 项`, `Imported ${result.imported}`));
        await review(ctx, id, folders, navigation);
      } : undefined,
    });
  }
  function importEdit(ctx, row) {
    const local = field(tr("编辑副本的完整路径", "Full Path to the Edited Copy"), "path");
    const file = field(tr("或选择文件", "Or Choose a File"), "file", "", "file");
    file.querySelector("input").accept = "." + row.fileExtension;
    const mode = selectField(tr("保存方式", "Save As"), "mode", "version", [
      ["version", tr("同一资料的新版本", "New Version")], ["attachment", tr("关联的新附件", "Related Attachment")],
    ]);
    modal(tr("导入编辑新版本…", "Import Edited Version…"), [el("p", "muted", row.displayName), local, file, mode], {
      submitLabel: tr("确认导入", "Confirm Import"), submit: async (values) => {
        const selected = file.querySelector("input").files[0];
        const path = values.path.trim();
        if (Boolean(selected) === Boolean(path)) throw new Error(tr("请指定一个编辑副本。", "Choose one copy to import."));
        if (selected) {
          const body = new FormData();
          body.append("file", selected);
          body.append("id", row.id);
          body.append("mode", values.mode);
          body.append("confirm", "true");
          await upload(ctx, "edited", body);
        } else await send(ctx, "edited-path", {id: row.id, path, mode: values.mode, confirm: true});
        closeDialog();
        await ctx.refresh();
        toast(tr("已导入编辑副本。", "Edited copy imported."));
      },
    });
  }
  function documentFolder(container, ctx) {
    if (ctx.folderID && state.writable) container.append(button(tr("从搞文件选择资料…", "Choose in GaoWenJian…"),
      () => prepared(ctx, "files.choose", {folderID: ctx.folderID}), {symbol: "search"}));
    container.append(button(tr("交接回执…", "Handoff Receipts…"), () => open(ctx), {symbol: "archive"}));
    return container;
  }
  function documentActions(container, ctx) {
    const row = ctx.document;
    if (state.writable && (IMAGE.has(row.fileExtension) || row.fileExtension === "pdf")) {
      const title = tr("送搞操作识别文字（OCR）…", "Recognize Text in GaoCaoZuo…");
      container.append(button(title, () => launch(ctx, "ocr.files", {documentIDs: [row.id]}, title), {symbol: "paperplane"}));
    }
    if (state.writable && EDITABLE.has(row.fileExtension)) {
      const title = tr("在搞文件中编辑…", "Edit in GaoWenJian…");
      container.append(button(title, () => launch(ctx, "documents.open", {documentIDs: [row.id]}, title), {symbol: "edit"}));
      container.append(button(tr("导入编辑新版本…", "Import Edited Version…"), () => importEdit(ctx, row), {symbol: "upload"}));
    }
    if (row.windowsVersions?.length) container.append(button(tr("原件与版本…", "Original and Versions…"), () =>
      modal(tr("原件与版本", "Original and Versions"), Array.from(row.windowsVersions).reverse().map((version) => {
        const link = el("a", "button", icon("download"), version.originalName);
        link.href = "/api/download?" + new URLSearchParams({kind: "document", owner: row.folderID, name: version.storedName, token});
        return el("div", "row", link, el("span", "muted", localDate(version.updatedAt)));
      })), {symbol: "archive"}));
    if (row.windowsProvenance?.pages?.length) container.append(button(tr("OCR 页码来源…", "OCR Page Sources…"), () =>
      modal(tr("OCR 页码来源", "OCR Page Sources"), pageRows(row.windowsProvenance.pages), {size: "wide"}), {symbol: "document"}));
    return container;
  }

  window.researchExchange = {toolbar: documentFolder, document: documentActions, open, openPending, setPending, pendingForDocument, pendingButton};
})();
