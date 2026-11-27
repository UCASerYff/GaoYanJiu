import assert from "node:assert/strict";
import {spawn} from "node:child_process";
import {createHash, randomBytes, randomUUID} from "node:crypto";
import {mkdtemp, mkdir, readFile, rm, writeFile} from "node:fs/promises";
import {createServer} from "node:http";
import {setTimeout as delay} from "node:timers/promises";
import {tmpdir} from "node:os";
import path from "node:path";
import {fileURLToPath} from "node:url";

const [browser, executable, ...flags] = process.argv.slice(2);
if (!browser || !executable) {
  throw new Error("Usage: node tests/smoke_browser.mjs <Chromium.exe> <Python.exe|GaoYanJiu.exe> [--frozen] [--screenshots DIR]");
}
const windows = fileURLToPath(new URL("../", import.meta.url));
const tempRoot = path.resolve(tmpdir());
const workspace = await mkdtemp(path.join(tempRoot, "gaoyanjiu-browser-"));
const dataDir = path.join(workspace, "data");
const profile = path.join(workspace, "chromium");
const screenshotArg = flags.indexOf("--screenshots");
const screenshots = screenshotArg >= 0 ? path.resolve(flags[screenshotArg + 1]) : null;
if (screenshots) await mkdir(screenshots, {recursive: true});
const logs = [];
const errors = [];
const children = [];
const portalFixture = createServer((_request, response) => {
  response.setHeader("Content-Type", "text/html; charset=utf-8");
  response.end("<!doctype html><title>Fixture Journal</title><table><thead><tr><th>Manuscript ID</th><th>Title</th><th>Journal</th><th>Status</th></tr></thead>" +
    "<tbody><tr><td>PORTAL-2026-1</td><td>A synthetic submission title</td><td>Fixture Journal</td><td>Under review</td></tr></tbody></table>");
});
await new Promise((resolve) => portalFixture.listen(0, "127.0.0.1", resolve));
const portalURL = "http://127.0.0.1:" + portalFixture.address().port + "/journal/";

function worker(program, args) {
  const child = spawn(program, args, {stdio: ["ignore", "pipe", "pipe"], windowsHide: true});
  children.push(child);
  child.stdout.on("data", (data) => logs.push(String(data)));
  child.stderr.on("data", (data) => logs.push(String(data)));
  child.on("error", (error) => errors.push(error.message));
  return child;
}
async function poll(check, title) {
  let last;
  for (let attempt = 0; attempt < 125; attempt++) {
    try {
      const value = await check();
      if (value) return value;
    } catch (error) { last = error; }
    await delay(80);
  }
  throw new Error("Timed out waiting for " + title + (last ? ": " + last.message : ""));
}
const app = worker(executable, [
  ...(flags.includes("--frozen") ? [] : [path.join(windows, "launch.py")]),
  "--serve", "--no-browser", "--port", "0", "--data-dir", dataDir,
]);
worker(browser, [
  "--headless=new", "--no-first-run", "--no-default-browser-check", "--disable-gpu", "--disable-crash-reporter",
  "--disable-background-networking", "--disable-component-update", "--disable-sync", "--remote-debugging-port=0",
  "--user-data-dir=" + profile, "about:blank",
]);

let socket;
let session;
try {
  session = await poll(async () => JSON.parse(await readFile(path.join(dataDir, "server.json"), "utf8")), "loopback service");
  const debugging = await poll(async () => parseInt((await readFile(path.join(profile, "DevToolsActivePort"), "utf8")).split(/\r?\n/)[0], 10), "Chromium debugging port");
  const tabs = await fetch("http://127.0.0.1:" + debugging + "/json").then((response) => response.json());
  socket = new WebSocket(tabs.find((tab) => tab.type === "page").webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve, {once: true});
    socket.addEventListener("error", reject, {once: true});
  });
  let counter = 0;
  let pageDialog = null;
  const pending = new Map();
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.method === "Runtime.exceptionThrown") errors.push(message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text);
    if (message.method === "Page.javascriptDialogOpening") pageDialog = message.params;
    if (!pending.has(message.id)) return;
    const {resolve, reject} = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) reject(new Error(message.error.message));
    else resolve(message.result);
  });
  function cdp(method, params = {}) {
    return new Promise((resolve, reject) => {
      pending.set(++counter, {resolve, reject});
      socket.send(JSON.stringify({id: counter, method, params}));
    });
  }
  async function evaluate(expression) {
    const response = await cdp("Runtime.evaluate", {expression, awaitPromise: true, returnByValue: true});
    if (response.exceptionDetails) throw new Error(response.exceptionDetails.exception?.description || response.exceptionDetails.text);
    return response.result.value;
  }
  const css = (selector) => "document.querySelector(" + JSON.stringify(selector) + ")";
  const has = (selector) => poll(() => evaluate("Boolean(" + css(selector) + ")"), selector);
  const addText = (selector, value) => evaluate("(()=>{const control=" + css(selector) + ";control.value=" +
    JSON.stringify(value) + ";control.dispatchEvent(new Event('input',{bubbles:true}));control.dispatchEvent(new Event('change',{bubbles:true}));})()");
  const press = (selector) => evaluate(css(selector) + ".click()");
  const byText = (container, text) => poll(() => evaluate("(()=>{const node=[...document.querySelectorAll(" + JSON.stringify(container) +
    ")].find(n=>n.textContent.trim().includes(" + JSON.stringify(text) + "));if(!node)return false;node.click();return true;})()"), text);
  const current = (page) => has("#main[data-page='" + page + "']");
  async function screenshot(name) {
    if (!screenshots) return;
    const {data} = await cdp("Page.captureScreenshot", {format: "png"});
    await writeFile(path.join(screenshots, name + ".png"), Buffer.from(data, "base64"));
  }
  async function settings(theme) {
    await press('#utilities [aria-label="设置"]');
    await has("#editor[open] [name=appearance]");
    await addText("#editor [name=appearance]", theme);
    await press("#editor button[type=submit]");
    await poll(() => evaluate("document.body.dataset.theme===" + JSON.stringify(theme)), theme + " setting");
  }
  const navigation = {
    submissions: [1, 0], works: [1, 1], experimentData: [2, 0], summaryReports: [2, 1],
    importantLiterature: [2, 2], certificates: [2, 3], city: [3, 0],
  };
  async function openPage(page) {
    const [group, item] = navigation[page];
    await press("#nav section:nth-child(" + group + ") button:nth-of-type(" + (item + 1) + ")");
    await current(page);
  }
  async function submit() {
    await press("#editor button[type=submit]");
    await poll(() => evaluate("!document.querySelector('#editor').open"), "save to close editor");
  }
  async function request(endpoint, body) {
    const response = await fetch(new URL(endpoint, session.url), {
      method: body ? "POST" : "GET", headers: {"X-Gao-Token": session.token, "Content-Type": "application/json"},
      ...(body ? {body: JSON.stringify(body)} : {}),
    });
    const result = await response.json();
    assert.equal(response.status, 200, String(result.message || endpoint));
    return result;
  }

  await cdp("Runtime.enable");
  await cdp("Page.enable");
  await cdp("DOM.enable");
  await cdp("Emulation.setDeviceMetricsOverride", {width: 1440, height: 940, deviceScaleFactor: 1, mobile: false});
  await cdp("Page.navigate", {url: session.url});
  await has("#gate:not([hidden]) #gate-create:not([hidden])");
  assert.equal(await evaluate("document.querySelector('#shell').hidden"), true);
  await screenshot("first-run");
  await press("#gate-create");
  await current("submissions");
  assert.equal(await evaluate("document.querySelectorAll('#nav button').length"), 7);
  assert.equal(await evaluate("getComputedStyle(document.querySelector('.sidebar')).width"), "198px");
  assert.equal(await evaluate("getComputedStyle(document.querySelector('.portal-wide')).display"), "grid");
  await settings("light");

  await byText("#page-tools button", "添加稿件");
  await has("#editor [name=title]");
  const title = "隔离稿件 Alpha · 面向复杂材料微结构和热机械耦合行为的多尺度实验表征与可解释模型验证";
  await addText("#editor [name=title]", title);
  await addText("#editor [name=venue]", "Fixture Journal");
  await addText("#editor [name=manuscriptID]", "MS-101");
  await addText("#editor [name=statusSince]", "2001-01-01");
  await screenshot("submission-editor-light");
  await submit();
  await has(".paper-row");
  await press('.tabs [data-scope="followup"]');
  await has('.tabs [data-scope="followup"][aria-pressed="true"]');
  await poll(() => evaluate("document.querySelector('.paper-stage').textContent.includes('待跟进')"), "follow-up status");
  await press('.tabs [data-scope="all"]');
  await has('.tabs [data-scope="all"][aria-pressed="true"]');
  await press(".paper-row .text-button");
  await has(".submission-inspector .is-selected");
  await screenshot("submission-inspector-light");
  await byText(".paper-row button", "更新状态");
  await addText("#editor [name=status]", "审稿中");
  await addText("#editor [name=statusSince]", new Date().toISOString().slice(0, 10));
  await submit();
  await poll(() => evaluate("document.querySelector('.paper-progress').textContent.includes('已投稿 → 审稿中')"), "real manuscript transition");
  await addText('.paper-status-filter select', "审稿中");
  await poll(() => evaluate("state.paperStatus === '审稿中' && document.querySelector('#main').getAttribute('aria-busy')==='false'"), "status filter");
  await press(".paper-row .text-button");
  await byText(".paper-context button", "查看完整详情");
  await has("#editor .line-item");
  assert.match(await evaluate("document.querySelector('#editor').textContent"), /已投稿/);
  await byText("#editor .dialog-foot button", "归档");
  await poll(() => evaluate("!document.querySelector('.paper-row')"), "archived submission leaves All");
  await press('.tabs [data-scope="hidden"]');
  await has(".paper-row");
  await press(".paper-row .text-button");
  await byText(".paper-context button", "查看完整详情");
  await has("#editor .pairs");
  await byText("#editor .dialog-foot button", "恢复追踪");
  await poll(() => evaluate("!document.querySelector('#editor').open && !document.querySelector('.paper-row')"), "restore from archive");
  await press('.tabs [data-scope="all"]');
  await has(".paper-row");
  await addText("#search", "MS-101");
  await has(".paper-row");

  await press("#clear-search");
  await byText(".portal-wide button", "从投稿系统导入");
  await byText("#editor .publisher-grid button", "自定义投稿网站");
  await has("#editor [name=url]");
  await addText("#editor [name=name]", "隔离投稿门户");
  await addText("#editor [name=url]", portalURL);
  await press("#editor button[type=submit]");
  await has("#editor button[data-portal-manual]");
  await press("#editor button[data-portal-manual]");
  await has("#editor [name=capture]");
  const bookmark = await evaluate("document.querySelector('#editor a[href^=javascript]').href");
  await cdp("Page.navigate", {url: portalURL});
  await has("table tbody tr");
  await evaluate(decodeURIComponent(bookmark.slice("javascript:".length)));
  await has("textarea[readonly]");
  const captured = await evaluate("document.querySelector('textarea[readonly]').value");
  assert.equal(JSON.parse(captured).papers[0].id, "PORTAL-2026-1");
  await cdp("Page.navigate", {url: session.url});
  await has(".portal-wide .portal-line");
  await press(".portal-wide .portal-name");
  await has("#editor button[data-portal-manual]");
  await press("#editor button[data-portal-manual]");
  await has("#editor [name=capture]");
  await addText("#editor [name=capture]", captured);
  await press("#editor button[type=submit]");
  await has("#editor .line-item input:checked");
  await screenshot("portal-review-light");
  await submit();
  await poll(() => evaluate("document.querySelectorAll('.paper-row').length === 2"), "reviewed portal import");

  await openPage("works");
  assert.equal(await evaluate(css("#search") + ".value"), "");
  await press("#page-tools .primary");
  await has("#editor [name=title]");
  const workTitle = "多中心联合实验中高维时空代谢谱、表型可重复性与长期随访结果的分层分析及方法学复核";
  await addText("#editor [name=title]", workTitle);
  await addText("#editor [name=type]", "patent");
  await addText("#editor [name=patentType]", "utilityModel");
  await addText("#editor [name=authorPosition]", "second");
  await submit();
  await has(".work-row");
  assert.match(await evaluate(css(".work-row") + ".textContent"), /实用新型/);
  await press(".work-row .text-button");
  await has("#editor .pairs");
  await byText("#editor .dialog-foot button", "完成");
  await addText('[name="workTypeFilter"]', "dataset");
  await has(".catalog-workspace .empty");
  await addText('[name="workTypeFilter"]', "");
  await has(".work-row");
  await press('[data-catalog-view="analysis"]');
  await has(".catalog-analysis .chart-bars");
  assert.equal(await evaluate("document.querySelectorAll('.catalog-analysis section').length"), 3);
  await press('[data-catalog-view="records"]');
  await has(".work-row");

  const documentPath = path.join(workspace, "测试资料.txt");
  await writeFile(documentPath, "独立资料全文 searchable-token", "utf8");
  for (const kind of ["experimentData", "summaryReports", "importantLiterature"]) {
    await openPage(kind);
    await press("#page-tools .primary");
    await has("#editor [name=name]");
    await addText("#editor [name=name]", kind + " 项");
    await submit();
    await has(".folder-card");
    await press(".folder-button");
    await has(".folder-toolbar");
    await byText(".folder-toolbar summary", "资料交接");
    await byText(".folder-toolbar .popover-menu button", "从本机路径导入");
    await has("#editor [name=path]");
    await addText("#editor [name=path]", documentPath);
    await submit();
    await has(".document-row");
    await press(".document-row .text-button");
    await has("#editor .text-preview");
    assert.match(await evaluate(css("#editor .text-preview") + ".textContent"), /searchable-token/);
    await byText("#editor .dialog-foot button", "完成");
    await addText("#search", "searchable-token");
    await has(".document-row");
    await press("#clear-search");
  }

  await openPage("certificates");
  await press("#page-tools .primary");
  await has("#editor [name=name]");
  await addText("#editor [name=name]", "隔离证书 Delta");
  await addText("#editor [name=tags]", "荣誉, 遴选");
  await submit();
  await has(".table-wrap tbody tr");
  assert.match(await evaluate(css(".table-wrap tbody tr") + ".textContent"), /获奖|荣誉/);
  const cert = (await request("/api/certificates")).certificates[0];
  const imagePath = path.join(workspace, "证书.png");
  await writeFile(imagePath, Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/C7cAAAAASUVORK5CYII=", "base64"));
  const fileBody = new FormData();
  fileBody.set("ownerID", cert.id);
  fileBody.set("file", new Blob([await readFile(imagePath)], {type: "image/png"}), "证书.png");
  const attachment = await fetch(new URL("/api/certificates/attachment", session.url), {method: "POST", headers: {"X-Gao-Token": session.token}, body: fileBody});
  assert.equal(attachment.status, 200);
  await evaluate("refresh()");
  await has(".table-wrap tbody tr");
  await press(".table-wrap tbody tr td:first-child button");
  await has("#editor .line-item");
  await byText("#editor .line-item .text-button", "证书.png");
  await has("#editor img.image-preview");
  await byText("#editor .dialog-foot button", "返回记录");
  await has("#editor .line-item");
  await press('#editor .line-item button[aria-label="移入回收站"]');
  await byText("#editor .dialog-foot button", "删除");
  await poll(() => evaluate("!document.querySelector('#editor').open"), "attachment in trash");
  await press('#utilities [aria-label="回收站"]');
  await has("#editor .line-item");
  await byText("#editor .line-item button", "恢复");
  await poll(() => evaluate("!!document.querySelector('#editor .empty')"), "restore attachment from Trash");
  await byText("#editor .dialog-foot button", "完成");

  await openPage("experimentData");
  await has(".file-pane-heading");
  const lab = await request("/api/documents?kind=experimentData");
  const other = await request("/api/documents/folder", {kind: "experimentData", name: "隔离归档"});
  const otherFile = path.join(workspace, "另一个文件夹的资料.txt");
  await writeFile(otherFile, "cross-folder-index-token", "utf8");
  await request("/api/documents/import-path", {folderID: other.id, path: otherFile});
  await addText("#search", "cross-folder-index-token");
  await poll(() => evaluate("document.querySelector('.file-pane-heading')?.textContent === '隔离归档' && document.querySelector('.document-row')?.textContent.includes('另一个文件夹的资料')"),
    "full-text search reaches another folder");
  await press("#clear-search");
  await poll(() => evaluate("document.querySelector('.file-pane-heading')?.textContent === 'experimentData 项'"), "return to selected folder");

  const {document: source} = await request("/api/documents/import-path", {folderID: lab.folderID, path: imagePath});
  await evaluate("refresh()");
  await byText(".document-row .text-button", "证书");
  await byText("#editor .dialog-foot button", "送搞操作识别文字");
  await has("#editor button[type=submit]");
  await byText("#editor .dialog-foot button", "取消");
  const outbound = await request("/api/exchange/prepare", {action: "ocr.files", documentIDs: [source.id], launch: false});
  const requestManifest = JSON.parse(await readFile(path.join(outbound.path, "manifest.json"), "utf8"));
  const binding = {sourceItemID: requestManifest.items[0].id, sourceSHA256: source.sha256};
  const ocrText = "合成 OCR 搜索内容";
  const output = Buffer.from(JSON.stringify({schemaVersion: 1, sources: [{sha256: source.sha256, pages: [
    {page: 1, status: "completed", lines: [{text: ocrText}]}, {page: 2, status: "failed", lines: []},
  ]}]}));
  const replyID = randomUUID();
  const reply = {
    schemaVersion: 1, kind: "result", requestID: replyID, inReplyTo: outbound.requestID, action: requestManifest.action,
    sourceBundleID: requestManifest.targetBundleID, targetBundleID: requestManifest.sourceBundleID,
    createdAt: requestManifest.createdAt, expiresAt: requestManifest.expiresAt, nonce: randomBytes(32).toString("base64"),
    parameters: requestManifest.parameters, status: "partial", references: [],
    items: [{id: "contents", relativePath: "OCR.json", uti: "public.json",
      byteCount: output.length, sha256: createHash("sha256").update(output).digest("hex")}],
    provenance: {
      engine: "FixtureOCR",
      sources: [{...binding, outputItemIDs: ["contents"], pages: [{pageNumber: 1, status: "completed"}, {pageNumber: 2, status: "failed"}]}],
      outputs: [{...binding, resultItemID: "contents", format: "json"}],
    },
  };
  const replyPath = path.join(workspace, replyID + ".gaoaction");
  await mkdir(path.join(replyPath, "payload"), {recursive: true});
  await writeFile(path.join(replyPath, "payload", "OCR.json"), output);
  await writeFile(path.join(replyPath, "manifest.json"), JSON.stringify(reply));
  await byText(".folder-toolbar summary", "资料交接");
  await byText(".folder-toolbar .popover-menu button", "交接回执");
  await has("#editor [name=path]");
  await addText("#editor [name=path]", replyPath);
  await byText("#editor .dialog-body button", "读取并复核");
  await has('#editor [name="acceptPartial"]');
  assert.equal(await evaluate(css("#editor .ocr-page-text") + ".textContent"), ocrText);
  await press("#editor button[type=submit]");
  await has("#editor .dialog-error:not([hidden])");
  await screenshot("ocr-review-required-light");
  await press('#editor [name="acceptPartial"]');
  await press("#editor button[type=submit]");
  await poll(() => evaluate("!document.querySelector('#editor button[type=submit]')"), "reviewed OCR import");
  await byText("#editor .dialog-foot button", "完成");
  await byText(".document-row .text-button", "OCR");
  await has("#editor .text-preview");
  assert.equal(await evaluate(css("#editor .text-preview") + ".textContent"), ocrText);
  await byText("#editor .dialog-foot button", "完成");

  await openPage("city");
  await has(".city-scene-canvas");
  const canvas = () => evaluate(css(".city-scene-canvas") + ".toDataURL()");
  const beforeOrbit = await canvas();
  await press('.city-scene-tools [aria-label="向右旋转视角"]');
  await poll(async () => (await canvas()) !== beforeOrbit, "three-dimensional camera orbit");
  await byText(".city-toolbar > .city-segment button", "祈愿池");
  await has(".city-pool button:not(:disabled)");
  await press(".city-pool button:not(:disabled)");
  await has("dialog.city-result-dialog[open]");
  await press("dialog.city-result-dialog button");
  await byText(".city-toolbar > .city-segment button", "我的城市");
  await press(".city-toolbar-end > button");
  await has(".city-inventory-item");
  await press(".city-inventory-item");
  await press(".city-accessible summary");
  await addText(".city-accessible select:first-child", "3:3");
  await addText(".city-accessible select:nth-child(2)", "1:1");
  await press(".city-accessible button");
  await poll(async () => (await request("/api/reward")).placements.length === 1, "place a drawn building");

  for (const page of Object.keys(navigation)) { await openPage(page); await screenshot(page + "-light"); }
  await settings("dark");
  await cdp("Emulation.setDeviceMetricsOverride", {width: 1040, height: 720, deviceScaleFactor: 1.75, mobile: false});
  for (const page of Object.keys(navigation)) {
    await openPage(page);
    assert.equal(await evaluate("document.querySelector('.workspace').scrollWidth<=document.querySelector('.workspace').clientWidth+1"), true, page);
    await screenshot(page + "-dark-175");
  }
  await openPage("submissions");
  assert.equal(await evaluate("document.querySelector('.portal-wide').getClientRects().length"), 0);
  await byText("#page-tools button", "门户");
  await has("#editor .portal-panel");
  await byText("#editor .dialog-foot button", "完成");
  await cdp("Page.navigate", {url: session.url + "#projects"});
  await current("submissions");
  await has('.tabs [data-scope="all"][aria-pressed="true"]');
  await cdp("Emulation.setDeviceMetricsOverride", {width: 590, height: 720, deviceScaleFactor: 1.5, mobile: false});
  await has('#nav-toggle button[aria-expanded="false"]');
  await press("#nav-toggle button");
  await has('#nav-toggle button[aria-expanded="true"]');
  assert.equal(await evaluate("getComputedStyle(document.querySelector('.sidebar')).width"), "198px");
  await press("#nav-toggle button");
  await has('#nav-toggle button[aria-expanded="false"]');
  await has(".paper-row .text-button");
  assert.equal(await evaluate(css(".paper-row .text-button") + ".textContent"), title);
  for (const name of [".topbar", ".main", ".paper-row", ".paper-row .text-button"]) {
    assert.equal(await evaluate(`(()=>{const node=${css(name)};return node.scrollWidth<=node.clientWidth+1})()`), true, name);
  }
  await screenshot("submissions-narrow-dark-150");
  await press(".paper-row .text-button");
  await has("#editor[open] .pairs");
  await screenshot("submission-detail-narrow-dark-150");
  await byText("#editor .dialog-foot button", "完成");
  await press('#utilities [aria-label="设置"]');
  await has("#editor[open] .settings-grid");
  await screenshot("settings-narrow-dark-150");
  await byText("#editor .dialog-foot button", "取消");
  await openPage("experimentData");
  await has(".document-row");
  await screenshot("library-narrow-dark-150");
  await byText(".library-pane-title button", "返回文件夹");
  await has(".library-workspace:not(.has-current-folder) .folder-card");
  await byText(".folder-button", "experimentData 项");
  await has(".document-row");
  await openPage("works");
  await has(".work-row");
  assert.equal(await evaluate(css(".work-row .text-button") + ".textContent"), workTitle);
  assert.equal(await evaluate("document.querySelector('.main').scrollWidth<=document.querySelector('.main').clientWidth+1"), true);
  await screenshot("works-narrow-dark-150");
  await openPage("city");
  await screenshot("city-narrow-dark-150");
  await cdp("Page.navigate", {url: session.url + "#works"});
  await current("works");
  const reminderPaper = (await request("/api/papers?q=MS-101")).papers[0];
  const reference = createHash("sha256").update(JSON.stringify([reminderPaper.key])).digest("hex").slice(0, 40);
  await cdp("Page.navigate", {url: session.url + "#follow-up/" + reference});
  await current("submissions");
  await has("#editor[open] #dialog-heading");
  assert.match(await evaluate(css("#dialog-heading") + ".textContent"), /隔离稿件 Alpha/);
  await byText("#editor .dialog-foot button", "完成");
  await evaluate(`(() => {
    const original = window.fetch;
    window.fetch = (...args) => {
      if (!String(args[0]).startsWith("/api/works?")) return original(...args);
      window.fetch = original;
      return new Promise(resolve => {
        window.finishFixtureLoad = () => resolve(new Response(JSON.stringify({message: "隔离测试中的临时读取错误"}),
          {status: 503, headers: {"Content-Type": "application/json"}}));
      });
    };
  })()`);
  await press('#nav [data-nav-page="works"]');
  await has("#main[aria-busy=true] .page-wait");
  await screenshot("workbench-loading-dark-150");
  await evaluate("window.finishFixtureLoad()");
  await has("#main [role=alert]");
  await screenshot("workbench-error-dark-150");
  await byText("#main [role=alert] button", "重新加载");
  await current("works");

  async function quitFromSettings(confirmed) {
    const selected = byText("#editor .dialog-foot button", "退出搞研究");
    await poll(() => pageDialog?.type === "confirm", "quit confirmation");
    pageDialog = null;
    await cdp("Page.handleJavaScriptDialog", {accept: confirmed});
    await selected;
  }
  const priorFollowUp = (await request("/api/bootstrap")).settings.followUpDays;
  await press('#utilities [aria-label="设置"]');
  await has("#editor [name=followUpDays]");
  await addText("#editor [name=followUpDays]", "17");
  await quitFromSettings(false);
  assert.equal(await evaluate(css("#editor[open] [name=followUpDays]") + ".value"), "17");
  assert.equal((await request("/api/bootstrap")).settings.followUpDays, priorFollowUp);
  await screenshot("quit-canceled-unsaved-setting-dark");
  await submit();
  assert.equal((await request("/api/bootstrap")).settings.followUpDays, 17);
  await press('#utilities [aria-label="设置"]');
  await has("#editor [name=followUpDays]");
  await quitFromSettings(true);
  await poll(async () => {
    if (app.exitCode !== 0) return false;
    try {
      await readFile(path.join(dataDir, "server.json"));
      return false;
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
      return true;
    }
  }, "confirmed quit removes the running isolated service");
  assert.deepEqual(errors, []);
  console.log("Browser passed: seven pages, first-run gate, long manuscript and work titles, submission editor and follow-up, status filter and archive, reviewed portal fallback, work filter and analytics, three searchable libraries, cross-folder search, reviewed partial OCR, attachment/Trash, city orbit/draw/place, dark 175%, narrow 150%, settings and direct notification activation, canceled and confirmed quit.");
} catch (error) {
  console.error(logs.slice(-12).join("").slice(-6000));
  if (errors.length) console.error(errors);
  throw error;
} finally {
  socket?.close();
  portalFixture.close();
  if (session?.url && session.token) {
    await fetch(new URL("/api/shutdown", session.url), {method: "POST", headers: {"X-Gao-Token": session.token}}).catch(() => {});
    await Promise.race([new Promise((resolve) => app.once("exit", resolve)), delay(500)]);
  }
  for (const child of children) if (child.exitCode === null) child.kill();
  await delay(750);
  assert.equal(path.dirname(workspace), tempRoot);
  assert.match(path.basename(workspace), /^gaoyanjiu-browser-/);
  await rm(workspace, {recursive: true, force: true, maxRetries: 3, retryDelay: 200});
}
