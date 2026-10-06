(function installExtractor() {
 function createExtractor(document) {
  const location = document.location; 
  const clean = (value) => String(value ?? "").replace(/\s+/g, " ").trim();

  const invalidPaperWords = /^(label|login|log in|sign in|logout|password|username|user name|action|action links?|menu|home|dashboard|editorial manager|submissions?|manuscripts?|author center|author centre)$/i;
  const workflowPageTitle = /^(submissions?|manuscripts?)\s+(being|with|requiring|sent|assigned|processed)|author\s+(main menu|dashboard|center|centre)|my\s+(submissions?|manuscripts?)$/i;

  function isAuthenticationPage(ownerDocument = document) {
    const password = ownerDocument.querySelector('input[type="password"]');
    if (!password) return false;
    const bodyText = clean(ownerDocument.body?.innerText || ownerDocument.body?.textContent).toLowerCase();
    return /\b(log\s*in|sign\s*in|password|forgot password|username|user name)\b/.test(bodyText);
  }

  // A newly submitted manuscript can legitimately have no assigned number.
  // Keep a deterministic internal identity until the journal assigns one.
  function provisionalID(title) {
    const normalized = clean(title).normalize("NFKC").toLowerCase();
    let hash = 2166136261;
    for (const character of normalized) hash = Math.imul(hash ^ character.codePointAt(0), 16777619);
    return `pending:${(hash >>> 0).toString(16).padStart(8, "0")}`;
  }

  function plausiblePaper(paper, kind = "") {
    const id = clean(paper?.id);
    const title = clean(paper?.title);
    const status = clean(paper?.status);
    if (!id || !title || !status) return false;
    if (invalidPaperWords.test(id) || invalidPaperWords.test(title) || invalidPaperWords.test(status)) return false;
    if (/\.(aspx?|php|html?)($|[?#])/i.test(id) || /^(default|login|signin|home|dashboard)\b/i.test(id)) return false;
    if (/editorial manager|sign in|log in|login|forgot password/i.test(title)) return false;
    if (workflowPageTitle.test(title)) return false;
    if (/^(label|button|link|menu|navigation|unknown|n\/a)$/i.test(status)) return false;
    if (title.length < 5 || title.length > 1200 || status.length > 300) return false;
    if (kind === "editorial-manager" && !/^pending:[0-9a-f]{8}$/.test(id)) {
      if (id === title || id.length < 4 || id.length > 160 || !/\d/.test(id)) return false;
      if (!/[A-Za-z\u4e00-\u9fff]/.test(id) && !/^\d{4,}$/.test(id)) return false;
    }
    return true;
  }

  function parsePortalDate(value) {
    const text = clean(value);
    const months = {
      jan: 0, feb: 1, mar: 2, apr: 3, may: 4, jun: 5,
      jul: 6, aug: 7, sep: 8, oct: 9, nov: 10, dec: 11,
    };
    const english = text.match(/(\d{1,2})[\s/-]+([A-Za-z]{3,9})[\s/-]+(\d{4})/);
    if (english) {
      const month = months[english[2].slice(0, 3).toLowerCase()];
      if (month !== undefined) {
        return new Date(Date.UTC(Number(english[3]), month, Number(english[1]))).toISOString();
      }
    }
    const monthFirst = text.match(/([A-Za-z]{3,9})\s+(\d{1,2}),?\s+(\d{4})/);
    if (monthFirst && months[monthFirst[1].slice(0, 3).toLowerCase()] !== undefined) {
      return new Date(Date.UTC(Number(monthFirst[3]), months[monthFirst[1].slice(0, 3).toLowerCase()], Number(monthFirst[2]))).toISOString();
    }
    const numeric = text.match(/(20\d{2})[/-](\d{1,2})[/-](\d{1,2})/);
    if (numeric) {
      return new Date(Date.UTC(Number(numeric[1]), Number(numeric[2]) - 1, Number(numeric[3]))).toISOString();
    }
    return "";
  }

  function textAfterLabel(root, label) {
    const labels = [...root.querySelectorAll("div, p, span, dt, th, strong")];
    const element = labels.find((item) => clean(item.textContent).replace(/:$/, "").toLowerCase() === label.toLowerCase());
    if (!element) return "";
    if (element.tagName === "DT" || element.tagName === "TH") {
      return clean(element.nextElementSibling?.textContent);
    }
    const sibling = element.nextElementSibling;
    if (sibling && clean(sibling.textContent)) return clean(sibling.textContent);
    const children = [...(element.parentElement?.children ?? [])];
    return clean(children[children.indexOf(element) + 1]?.textContent);
  }

  function springerTiming() {
    const entries = [...document.querySelectorAll(".c-details-history__description")]
      .map((element) => ({
        text: clean(element.innerText || element.textContent),
        date: parsePortalDate(element.querySelector("time")?.textContent || element.textContent),
      }))
      .filter((entry) => entry.date)
      .sort((a, b) => new Date(a.date) - new Date(b.date));
    const latest = entries.at(-1);
    return latest ? { statusSince: latest.date, statusSinceSource: latest.text } : {};
  }

  function extractSpringer() {
    const main = document.querySelector("main") ?? document.body;
    const label = [...main.querySelectorAll("p, span, div")]
      .find((element) => clean(element.textContent) === "Current status");
    const status = clean(label?.nextElementSibling?.textContent || label?.parentElement?.querySelector("h1")?.textContent);
    const title = textAfterLabel(main, "Title") || clean(main.querySelector("h2")?.textContent);
    const id = textAfterLabel(main, "Submission ID") || location.pathname.split("/").filter(Boolean).at(-1) || title;
    const journal = textAfterLabel(main, "Journal") || clean(document.querySelector("header")?.textContent) || "Springer Nature";
    return status ? [{ id, title, journal, status, ...springerTiming() }] : [];
  }

  function extractScholarOne() {
    return [...document.querySelectorAll('tr[id^="queue_"]')].flatMap((row) => {
      const id = clean(row.querySelector(':scope > td[data-label="ID"]')?.textContent);
      const titleCell = row.querySelector(':scope > td[data-label="title"]');
      const title = clean(titleCell?.childNodes[0]?.textContent) || clean(titleCell?.textContent).split("View Submission")[0];
      const statusCell = row.querySelector(':scope > td[data-label="status"]');
      const status = clean(statusCell?.querySelector(".pagecontents")?.textContent || statusCell?.textContent)
        .replace(/^Contact Journal\s*/i, "")
        .replace(/^EIC:\s*Not Assigned\s*/i, "");
      if (!id || !title || !status) return [];
      return [{
        id,
        title,
        journal: clean(document.querySelector("header")?.textContent) || document.title,
        status,
      }];
    });
  }

  async function prepareTaylorFrancis() {
    for (const submission of document.querySelectorAll("app-submission")) {
      if (submission.querySelector(".step-progress-item.current-status .date")) continue;
      const more = [...submission.querySelectorAll("button, [role='button'], div, span")]
        .find((element) => clean(element.textContent) === "More details");
      more?.click();
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
  }

  function extractTaylorFrancis() {
    return [...document.querySelectorAll(".submission-detail")].flatMap((card) => {
      const id = clean(card.querySelector(".submission-id span")?.textContent);
      const title = clean(card.querySelector(".title .info")?.textContent);
      const journal = clean(card.querySelector(".journal .info")?.textContent);
      const status = clean(card.querySelector(".status .info")?.textContent);
      if (!id || !title || !status) return [];
      const submission = card.closest("app-submission") ?? card.closest(".submission.card") ?? card.parentElement;
      const dateText = clean(submission?.querySelector(".step-progress-item.current-status .date")?.textContent);
      const statusSince = parsePortalDate(dateText);
      return [{
        id,
        title,
        journal,
        status,
        ...(statusSince ? { statusSince, statusSinceSource: `${status} on ${dateText}` } : {}),
      }];
    });
  }

  function extractWiley() {
    return [...document.querySelectorAll('[data-testid="article-card-content"]')].flatMap((card) => {
      const id = clean(card.querySelector('[data-testid="metadata-value-manuscriptId"]')?.textContent);
      const title = clean(card.querySelector('[data-testid="article-title-link"]')?.textContent).replace(/<\/?fc>/gi, "");
      const journal = clean(card.querySelector('[data-testid="article-metadata-publication"]')?.textContent)
        .replace(/^Publication:\s*/i, "");
      const status = clean(card.querySelector('[data-testid="article-status-container"]')?.textContent);
      if (!id || !title || !status) return [];
      return [{
        id,
        title,
        journal: journal || "Wiley",
        status,
      }];
    });
  }

  function columnIndex(headers, expressions) {
    return headers.findIndex((header) => expressions.some((expression) => expression.test(header)));
  }

  function accessibleDocuments() {
    const documents = [document];
    const seen = new Set(documents);
    for (let index = 0; index < documents.length; index += 1) {
      for (const frame of documents[index].querySelectorAll("iframe, frame")) {
        try {
          const child = frame.contentDocument;
          if (child?.documentElement && !seen.has(child)) {
            seen.add(child);
            documents.push(child);
          }
        } catch (_) {
          // Cross-origin sign-in frames cannot be inspected and are skipped.
        }
      }
    }
    return documents;
  }

  function ownedRowCells(row) {
    const selector =
      ":scope > th, :scope > td, :scope > [role='columnheader'], :scope > [role='rowheader'], "
      + ":scope > [role='cell'], :scope > [role='gridcell'], :scope > [data-label]";
    const direct = [...row.querySelectorAll(selector)];
    if (direct.length) return direct;
    return [...row.querySelectorAll(
      "th, td, [role='columnheader'], [role='rowheader'], [role='cell'], [role='gridcell'], [data-label]"
    )].filter((cell) => cell.closest("tr, [role='row']") === row);
  }

  function logicalCellValues(cells, valueForCell) {
    const values = [];
    let cursor = 0;
    for (const cell of cells) {
      const explicitIndex = Number(cell.getAttribute("aria-colindex"));
      const start = Number.isFinite(explicitIndex) && explicitIndex > 0 ? explicitIndex - 1 : cursor;
      const spanValue = Number(cell.getAttribute("aria-colspan") || cell.getAttribute("colspan") || 1);
      const span = Number.isFinite(spanValue) && spanValue > 0 ? spanValue : 1;
      for (let offset = 0; offset < span; offset += 1) values[start + offset] = valueForCell(cell);
      cursor = Math.max(cursor, start + span);
    }
    return values;
  }

  function headerText(cell) {
    return clean(cell.innerText || cell.textContent)
      .replace(/[▲▼△▽↑↓]+/g, " ")
      .replace(/\s+/g, " ")
      .trim()
      .toLowerCase();
  }

  function cellLabels(cell, ownerDocument) {
    const labels = [
      cell.getAttribute("data-label"),
      cell.getAttribute("aria-label"),
      cell.getAttribute("title"),
      cell.id,
      typeof cell.className === "string" ? cell.className : "",
    ];
    for (const id of clean(cell.getAttribute("headers")).split(/\s+/).filter(Boolean)) {
      labels.push(ownerDocument.getElementById(id)?.textContent);
    }
    return labels.map((label) => clean(label).toLowerCase()).filter(Boolean);
  }

  function editorialManagerJournal(ownerDocument, source) {
    const journalCode = (ownerDocument.location?.pathname || location.pathname)
      .split("/").filter(Boolean)[0]?.toLowerCase();
    const knownJournals = {
      ksas: "International Journal of Aeronautical & Space Sciences",
      eswa: "Expert Systems with Applications",
      isatrans: "ISA Transactions",
    };
    // Editorial Manager paths identify the journal more reliably than page
    // headings, which often contain workflow labels rather than journal names.
    if (knownJournals[journalCode]) return knownJournals[journalCode];

    const candidates = [
      ownerDocument.querySelector("#journalName"),
      ownerDocument.querySelector("#journalTitle"),
      ownerDocument.querySelector('[id*="journalName" i]'),
      ownerDocument.querySelector('[id*="journalTitle" i]'),
      ownerDocument.querySelector('[class*="journal-name" i]'),
      ownerDocument.querySelector('[class*="journal-title" i]'),
      ownerDocument.querySelector('[class*="publication-title" i]'),
      ownerDocument.querySelector('[data-testid*="journal" i]'),
      ownerDocument.querySelector("header h1"),
      ownerDocument.querySelector("header h2"),
      ownerDocument.querySelector('[role="banner"] h1'),
      ownerDocument.querySelector('[role="banner"] h2'),
    ];
    const rawCandidates = [
      ...candidates.map((element) => clean(element?.innerText || element?.textContent)),
      ...[...ownerDocument.querySelectorAll('img[alt], img[title]')]
        .filter((element) => /journal|banner|masthead|logo/i.test([element.id, element.className, element.src].join(" ")))
        .map((element) => clean(element.alt || element.title))
        .filter((value) => !/^(elsevier|springer|logo|banner|journal logo|editorial manager)[®™\s]*$/i.test(value)),
      clean(ownerDocument.querySelector('meta[property="og:site_name"]')?.content),
      ...[...ownerDocument.querySelectorAll("header, [role=\"banner\"]")].map((element) => clean(element.textContent)).filter((value) => value.length < 240),
      clean(ownerDocument.title),
    ];
    const normalize = (value) => clean(value)
      .replace(/\s*[|·•:-]\s*Editorial Manager(?:®|™)?\s*$/i, "")
      .replace(/^Editorial Manager(?:®|™)?\s*[|·•:-]\s*/i, "")
      .replace(/\s*[|·•:-]\s*(Author|Reviewer|Editor)\s+(Main Menu|Login|Sign In).*$/i, "")
      .replace(/^\s*(Login|Sign In)\s*[|·•:-]\s*/i, "")
      .trim();
    for (const raw of rawCandidates) {
      const candidate = normalize(raw);
      if (!candidate || candidate.length < 5 || candidate.length > 240) continue;
      if (/^(editorial manager|author main menu|login|sign in|dashboard)$/i.test(candidate)) continue;
      if (/submissions?\s+(being|with|requiring|sent|assigned|processed)/i.test(candidate)) continue;
      if (/(author|reviewer|editor)\s+(main menu|dashboard|workspace)/i.test(candidate)) continue;
      if (/default\d*\.aspx/i.test(candidate)) continue;
      return candidate;
    }
    // Legacy EM layouts put the journal masthead in a sibling frame. Only
    // inspect same-origin frame documents; never treat the manuscript heading
    // or a workflow menu as a journal title.
    if (ownerDocument !== document) return editorialManagerJournal(document, source);
    return "";
  }

  function extractEditorialManager(source) {
    const results = [];
    const seen = new Set();
    const titleExpressions = [/^title$/, /manuscript title/, /article title/];
    const statusExpressions = [/^current status$/, /^manuscript status$/, /^status$/];
    const idExpressions = [/^manuscript (number|id|no\.?|#)$/, /^submission (number|id|no\.?|#)$/];
    const statusDateExpressions = [/^status date$/, /current status date/, /date status changed/];
    const submittedDateExpressions = [/^initial date submitted$/, /^date submitted$/, /submission date/];

    function matchingIndex(headers, expressions) {
      return headers.findIndex((value) => expressions.some((expression) => expression.test(value)));
    }

    function valueFor(row, cells, logicalValues, logicalHeaders, expressions) {
      const labelledCell = cells.find((cell) => cellLabels(cell, row.ownerDocument).some(
        (label) => expressions.some((expression) => expression.test(label))
      ));
      if (labelledCell) return clean(labelledCell.innerText || labelledCell.textContent);
      const index = matchingIndex(logicalHeaders, expressions);
      return index >= 0 ? clean(logicalValues[index]) : "";
    }

    for (const ownerDocument of accessibleDocuments()) {
      const containers = [...ownerDocument.querySelectorAll("table, [role='table'], [role='grid']")];
      for (const container of containers) {
        const rowSelector = container.tagName === "TABLE" ? "tr" : "[role='row']";
        const rows = [...container.querySelectorAll(rowSelector)].filter((row) => {
          if (container.tagName === "TABLE") return row.closest("table") === container;
          return row.closest("[role='table'], [role='grid']") === container;
        });

        const headerRow = rows.find((row) => {
          const cells = ownedRowCells(row);
          const headers = logicalCellValues(cells, headerText);
          return matchingIndex(headers, titleExpressions) >= 0
            && matchingIndex(headers, statusExpressions) >= 0;
        });
        if (!headerRow) continue;

        const headerCells = ownedRowCells(headerRow);
        const logicalHeaders = logicalCellValues(headerCells, headerText);
        const startIndex = rows.indexOf(headerRow) + 1;
        for (const row of rows.slice(startIndex)) {
          const cells = ownedRowCells(row);
          if (!cells.length || cells.some((cell) => cell.matches("th, [role='columnheader']"))) continue;
          const logicalValues = logicalCellValues(cells, (cell) => clean(cell.innerText || cell.textContent));
          const title = valueFor(row, cells, logicalValues, logicalHeaders, titleExpressions);
          const status = valueFor(row, cells, logicalValues, logicalHeaders, statusExpressions);
          if (!title || !status) continue;

          const id = valueFor(row, cells, logicalValues, logicalHeaders, idExpressions) || provisionalID(title);
          const statusDateText = valueFor(
            row, cells, logicalValues, logicalHeaders, statusDateExpressions
          );
          const submittedDateText = valueFor(
            row, cells, logicalValues, logicalHeaders, submittedDateExpressions
          );
          const statusSince = parsePortalDate(statusDateText || submittedDateText);
          if (!plausiblePaper({ id, title, status }, "editorial-manager")) continue;
          const key = `${id}:${title}:${status}`;
          if (seen.has(key)) continue;
          seen.add(key);
          results.push({
            id,
            title,
            journal: editorialManagerJournal(ownerDocument, source),
            status,
            ...(statusSince ? {
              statusSince,
              statusSinceSource: statusDateText
                ? `Status Date ${statusDateText}`
                : `Initial Date Submitted ${submittedDateText}`,
            } : {}),
          });
        }
      }

      // Responsive Editorial Manager layouts sometimes expose rows without a
      // table/grid wrapper, but keep data-label or ARIA labels on every cell.
      const labelledRows = [...ownerDocument.querySelectorAll("tr, [role='row']")];
      for (const row of labelledRows) {
        const cells = ownedRowCells(row);
        if (!cells.length) continue;
        const emptyHeaders = [];
        const logicalValues = logicalCellValues(cells, (cell) => clean(cell.innerText || cell.textContent));
        const title = valueFor(row, cells, logicalValues, emptyHeaders, titleExpressions);
        const status = valueFor(row, cells, logicalValues, emptyHeaders, statusExpressions);
        if (!title || !status) continue;
        const id = valueFor(row, cells, logicalValues, emptyHeaders, idExpressions) || provisionalID(title);
        const statusDateText = valueFor(row, cells, logicalValues, emptyHeaders, statusDateExpressions);
        const submittedDateText = valueFor(row, cells, logicalValues, emptyHeaders, submittedDateExpressions);
        const statusSince = parsePortalDate(statusDateText || submittedDateText);
        if (!plausiblePaper({ id, title, status }, "editorial-manager")) continue;
        const key = `${id}:${title}:${status}`;
        if (seen.has(key)) continue;
        seen.add(key);
        results.push({
          id,
          title,
          journal: editorialManagerJournal(ownerDocument, source),
          status,
          ...(statusSince ? {
            statusSince,
            statusSinceSource: statusDateText
              ? `Status Date ${statusDateText}`
              : `Initial Date Submitted ${submittedDateText}`,
          } : {}),
        });
      }
    }
    return results;
  }

  function extractDashboardTable(source) {
    for (const table of document.querySelectorAll("table")) {
      const rows = [...table.querySelectorAll("tr")];
      const headerRow = rows.find((row) => row.querySelectorAll("th").length >= 2);
      if (!headerRow) continue;
      const headers = [...headerRow.querySelectorAll("th")].map((cell) => clean(cell.textContent).toLowerCase());
      const titleIndex = columnIndex(headers, [/title/, /manuscript name/, /article/]);
      const statusIndex = columnIndex(headers, [/current status/, /^status$/, /decision/]);
      if (titleIndex < 0 || statusIndex < 0) continue;
      const idIndex = columnIndex(headers, [/manuscript (number|id|no)/, /^id$/, /reference/, /submission/]);
      const journalIndex = columnIndex(headers, [/journal/, /publication/, /venue/]);
      const papers = rows.slice(rows.indexOf(headerRow) + 1).flatMap((row) => {
        const cells = [...row.querySelectorAll(":scope > td")].map((cell) => clean(cell.textContent));
        const title = cells[titleIndex];
        const status = cells[statusIndex];
        if (!title || !status) return [];
        const paper = {
          id: cells[idIndex] || provisionalID(title),
          title,
          journal: cells[journalIndex] || source.name || document.title,
          status,
        };
        return plausiblePaper(paper, source.kind) ? [paper] : [];
      });
      if (papers.length) return papers;
    }
    return [];
  }

  function findLabelValue(root, expression) {
    const label = [...root.querySelectorAll("dt, div, p, span, strong, label")]
      .find((element) => expression.test(clean(element.textContent)));
    if (!label) return "";
    return clean(label.nextElementSibling?.textContent || label.parentElement?.querySelector("dd")?.textContent);
  }

  function extractSubmissionCards(source) {
    const candidates = [...document.querySelectorAll(
      'article, [data-testid*="submission" i], [class*="manuscript" i], [class*="submission" i]'
    )].filter((element) => clean(element.textContent).length < 5000);
    const results = [];
    const seen = new Set();
    for (const card of candidates) {
      const status = findLabelValue(card, /^(current\s+)?(manuscript\s+)?status:?$/i)
        || clean(card.querySelector('[data-testid*="status" i], [class*="status" i]')?.textContent);
      const title = findLabelValue(card, /^title:?$/i)
        || clean(card.querySelector("h1, h2, h3, [data-testid*='title' i]")?.textContent);
      if (!status || !title || status.length > 300 || title.length > 1000) continue;
      const id = findLabelValue(card, /^(manuscript|submission)?\s*(id|number|no|reference):?$/i)
        || clean(card.querySelector('[data-testid*="id" i], [class*="submission-id" i]')?.textContent)
        || provisionalID(title);
      const paper = {
        id,
        title,
        journal: findLabelValue(card, /^(journal|publication|venue):?$/i) || source.name || document.title,
        status,
      };
      if (!plausiblePaper(paper, source.kind)) continue;
      const key = `${id}:${status}`;
      if (seen.has(key)) continue;
      seen.add(key);
      results.push(paper);
    }
    return results;
  }

  function extractGeneric(source) {
    if (isAuthenticationPage(document)) return [];
    const main = document.querySelector("main") ?? document.body;
    // Custom portals are accepted only when the page exposes an explicit
    // manuscript id, title and current-status label. A generic CSS class such
    // as `.status` is common on login/home pages and must never create a paper.
    const id = findLabelValue(main, /^(manuscript|submission)\s*(id|number|no|reference):?$/i);
    const title = findLabelValue(main, /^(manuscript\s+|article\s+)?title:?$/i);
    const status = findLabelValue(main, /^(current\s+)?(manuscript\s+)?status:?$/i);
    const paper = { id, title, journal: source.name || location.hostname, status };
    return plausiblePaper(paper, "custom") ? [paper] : [];
  }

  async function extract(source = {}) {
    const host = location.hostname.toLowerCase();
    let papers = [];
    if (host === "rp.tandfonline.com") await prepareTaylorFrancis();

    if (host === "submission.springernature.com" || source.kind === "springer") {
      papers = extractSpringer();
    } else if (host === "mc.manuscriptcentral.com" || host.endsWith(".manuscriptcentral.com") || source.kind === "scholarone") {
      papers = extractScholarOne();
    } else if (host === "rp.tandfonline.com" || source.kind === "taylor-francis") {
      papers = extractTaylorFrancis();
    } else if (host === "authors.wiley.com" || source.kind === "wiley") {
      papers = extractWiley();
    } else if (host.endsWith("editorialmanager.com") || source.kind === "editorial-manager") {
      papers = extractEditorialManager(source);
    } else if ([
      "ieee", "acs", "openreview", "mdpi", "nature", "aip", "frontiers",
      "editorial-express", "copernicus", "ejournalpress", "benchpress",
      "manuscript-manager", "scholastica", "kriyadocs", "ojs", "janeway",
    ].includes(source.kind)) {
      papers = extractDashboardTable(source);
      if (!papers.length) papers = extractSubmissionCards(source);
    } else {
      papers = extractDashboardTable(source);
      if (!papers.length) papers = extractSubmissionCards(source);
      if (!papers.length) papers = extractGeneric(source);
    }

    if (!papers.length && !isAuthenticationPage(document)) {
      papers = extractDashboardTable(source);
      if (!papers.length) papers = extractSubmissionCards(source);
      if (!papers.length) papers = extractGeneric(source);
    }
    return {
      site: source.name || host,
      url: location.href,
      checkedAt: new Date().toISOString(),
      papers: papers.filter((paper) => plausiblePaper(paper, source.kind)).map((paper) => ({
        id: clean(paper.id),
        title: clean(paper.title),
        journal: clean(paper.journal),
        status: clean(paper.status),
        statusSince: paper.statusSince || null,
        statusSinceSource: clean(paper.statusSinceSource) || null,
        submissionHistory: clean(paper.submissionHistory) || null,
      })),
    };
  }

  return { extract, accessibleDocuments, editorialManagerJournal };
 }
 const root = createExtractor(document);
 globalThis.PaperSignalExtractor = {
   async extract(source = {}) {
     const results = await Promise.all(root.accessibleDocuments().map((doc) => createExtractor(doc).extract(source)));
     const result = results[0];
     const seen = new Set();
     result.papers = results.flatMap((item) => item.papers).filter((paper) => {
       const key = `${paper.id}:${paper.title}:${paper.status}`;
       if (seen.has(key)) return false;
       seen.add(key);
       if (!paper.journal && source.kind === "editorial-manager") paper.journal = root.editorialManagerJournal(document, source);
       return true;
     });
     return result;
   }
 };
})();
