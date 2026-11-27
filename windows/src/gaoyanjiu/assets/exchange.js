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
  async function prepared(ctx, action, parameters) {
    const result = await send(ctx, "prepare", {action, ...parameters});
    toast(errorMessage(result));
    modal(label(ACTIONS, action), [
      el("p", "", errorMessage(result)), displayPath(result.path),
      el("p", "muted", tr("有效期至 ", "Expires at ") + localDate(result.expiresAt)),
    ], {actions: [button(tr("在资源管理器中显示", "Show in Explorer"), () => send(ctx, "reveal", {id: result.requestID}), {symbol: "folder"})]});
  }
  function launch(ctx, action, parameters, title) {
    const description = action === "ocr.files"
      ? tr("发送所选原件的副本。识别范围、语种和导出须在搞操作中确认。", "Send a copy of the selected file. Confirm scope, languages, and export in GaoCaoZuo.")
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
        await review(ctx, result.id, overview.folders);
      }, {symbol: "open", style: "primary"})),
      details(tr("收到的交接", "Incoming"), incoming.length ? incoming : el("p", "muted", tr("暂无收件", "No incoming handoffs"))),
      details(tr("发出的请求", "Outgoing Requests"), outgoing.length ? outgoing : el("p", "muted", tr("暂无请求", "No outgoing requests"))),
    ], {size: "wide"});
    document.querySelector("#editor details")?.setAttribute("open", "");
  }
  function pageRows(pages) {
    return pages.map((page) => el("div", "form-group stack",
      el("span", "", tr(`第 ${page.pageNumber} 页`, `Page ${page.pageNumber}`) + " · " + label(STATUS, page.status)
        + (page.confidence === undefined ? "" : ` · ${Math.round(page.confidence * 100)}%`)),
      page.failureReason && el("span", "muted", page.failureReason),
      page.text && el("pre", "ocr-page-text", page.text)));
  }
  async function review(ctx, id, folders) {
    const item = await ctx.api("/api/exchange/review?id=" + encodeURIComponent(id));
    const folderValues = [["", tr("选择资料夹", "Select a Folder")], ...folders.map((folder) => [folder.id, `${PAGE_LABELS[folder.libraryKind] ? pageLabel(folder.libraryKind) + " / " : ""}${folder.name}`])];
    const locked = folders.some((folder) => folder.id === item.folderID);
    const selected = locked ? item.folderID : folders.find((folder) => folder.id === ctx.folderID)?.id || "";
    const folderField = selectField(tr("导入到资料夹", "Import into Folder"), "folderID", selected, folderValues);
    if (locked) folderField.querySelector("select").disabled = true;
    const requiresExtra = !item.resuming && (item.providerStatus === "partial" || item.warnings.length > 0);
    const chosen = item.references.map((reference) => field(reference.name, "file-" + reference.id));
    const actions = [button(tr("返回交接", "Back to Handoffs"), () => open(ctx), {symbol: "back"})];
    if (item.canReject) actions.push(button(tr("拒绝并取消…", "Reject and Cancel…"), () => {
      modal(tr("拒绝此交接？", "Reject This Handoff?"), [el("p", "", tr("发送方可收到取消回执。", "The sender can receive a cancelled receipt."))], {
        submitLabel: tr("确认拒绝", "Confirm Rejection"), submit: async () => {
          await send(ctx, "reject", {id, confirm: true});
          await review(ctx, id, folders);
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
        ], {actions: [button(tr("返回复核", "Back to Review"), () => review(ctx, id, folders))]});
      }});
    }, {symbol: "upload"}));
    const body = [
      el("p", "muted", `${item.sourceBundleID} · ${label(STATUS, item.status)}${item.providerStatus ? " · " + label(STATUS, item.providerStatus) : ""}`),
      item.errorCode && el("p", "muted", item.errorCode),
      item.action === "documents.open" && el("p", "", tr("这是打开副本的回执。导出后，请在原条目中选择「导入编辑新版本…」。", "This receipt describes opening the copy. After export, choose Import Edited Version on the original record.")),
      item.warnings.map((warning) => el("p", "muted", warning)),
      item.sources.map((source) => details(
        tr("原件 ", "Source ") + source.sourceName,
        [el("code", "", source.sha256), ...pageRows(source.pages)])),
      item.items.map((entry) => {
        const output = item.outputs.find((row) => row.itemID === entry.id);
        return el("div", "form-group stack", el("strong", "", entry.name),
          el("span", "muted", entry.byteCount.toLocaleString() + " B"),
          output && el("span", "", `${output.sourceName} · ${output.engine || "—"}${output.engineVersion ? " " + output.engineVersion : ""}${output.languages.length ? " · " + output.languages.join(", ") : ""}`),
          el("code", "", entry.sha256));
      }),
      item.references.map((reference, index) => el("div", "form-group stack",
        el("strong", "", reference.name), el("span", "muted", reference.fileURL), item.canApply && !item.resuming && chosen[index])),
      item.canApply && item.action !== "ocr.files" && folderField,
      item.canApply && requiresExtra && check(tr("我已复核部分结果及缺失来源", "I Reviewed Partial Results and Missing Metadata"), "acceptPartial"),
      item.counts && el("p", "", tr(`导入 ${item.counts.imported} 项，已有 ${item.counts.existing} 项`, `Imported ${item.counts.imported}, existing ${item.counts.existing}`)),
    ];
    modal(label(ACTIONS, item.action), body, {
      size: "wide", actions, submitLabel: item.resuming ? tr("恢复已批准导入", "Resume Approved Import") : tr("确认导入", "Confirm Import"),
      submit: item.canApply ? async (values) => {
        if (requiresExtra && !values.acceptPartial) throw new Error(tr("请先复核并确认部分结果或缺失来源。", "Review and acknowledge partial results or missing metadata."));
        const target = item.action === "ocr.files" ? "" : locked ? item.folderID : values.folderID;
        if (item.action !== "ocr.files" && !target) throw new Error(tr("请选择导入资料夹。", "Select a destination folder."));
        const references = item.resuming ? {} : Object.fromEntries(item.references.map((reference) => [reference.id, values["file-" + reference.id].trim()]));
        const result = await send(ctx, "apply", {id, confirm: true, folderID: target, references, acceptPartial: Boolean(values.acceptPartial)});
        await ctx.refresh();
        toast(tr(`已导入 ${result.imported} 项`, `Imported ${result.imported}`));
        await review(ctx, id, folders);
      } : undefined,
    });
    for (const detail of document.querySelectorAll("#editor details")) detail.open = true;
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

  window.researchExchange = {toolbar: documentFolder, document: documentActions, open};
})();
