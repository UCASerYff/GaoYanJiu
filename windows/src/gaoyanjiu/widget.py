from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

from gaoyanjiu.analytics import AUTHOR_LABELS, AUTHOR_POSITIONS, label, work_categories
from gaoyanjiu.errors import AppError
from gaoyanjiu.fsutil import read_regular_bytes, sha256_bytes
from gaoyanjiu.status import is_terminal
from gaoyanjiu.timeutil import format_iso, parse_date, utcnow

SNAPSHOT_NAME = "widget-snapshot.json"
PAGES = ("submissions", "works")
SNAPSHOT_LIMIT = 128 * 1024 * 1024


def read_snapshot(path: Path) -> dict:
    try:
        document = json.loads(read_regular_bytes(path, SNAPSHOT_LIMIT))
    except (AppError, OSError, ValueError):
        return {}
    if not isinstance(document, dict) or document.get("schema") != 1 or document.get("platform") != "windows":
        return {}
    if document.get("statisticsRevision"):
        if not isinstance(document.get("dataChangedAt"), str) or not isinstance(document.get("papers"), list):
            return {}
        for key in ("categories", "authors"):
            rows = document.get(key)
            if not isinstance(rows, list) or any(
                not isinstance(row, dict) or not isinstance(row.get("label"), str)
                or type(row.get("count")) is not int or row["count"] < 0 for row in rows
            ):
                return {}
    return document


def statistics_projection(data: dict, language: str) -> dict:
    works = data.get("existingWorks") or []
    categories = work_categories(works, language)
    authors = [
        {"id": position, "label": label(AUTHOR_LABELS, language, position),
         "count": sum(work.get("authorPosition") == position for work in works)}
        for position in AUTHOR_POSITIONS
    ]
    unassigned = sum(not work.get("authorPosition") for work in works)
    if unassigned:
        authors.append({"id": "unassigned", "label": "Unassigned" if language == "en" else "未填写",
                        "count": unassigned})
    papers = [
        {"id": str(paper.get("id") or paper.get("key") or ""), "title": str(paper.get("title") or ""),
         "since": str(paper.get("statusSince") or ""),
         "terminal": is_terminal(str(paper.get("status") or ""))}
        for paper in data.get("papers") or [] if not paper.get("hidden")
    ]
    papers.sort(key=lambda row: row["id"])
    distribution = [[(row["id"], row["count"]) for row in rows] for rows in (categories, authors)]
    revision = sha256_bytes(json.dumps([papers, distribution, len(works)], ensure_ascii=False).encode("utf-8"))
    return {"papers": papers, "categories": categories, "authors": authors, "statisticsRevision": revision}


def snapshot_metadata(current: dict, previous: dict, source_changed: datetime, settings: dict) -> dict:
    same = previous.get("statisticsRevision") == current["statisticsRevision"]
    return {
        "dataChangedAt": previous.get("dataChangedAt") if same else format_iso(source_changed),
        "dataChangedAtBasis": previous.get("dataChangedAtBasis") if same else (
            "observed-projection" if previous.get("statisticsRevision") else "source-write-baseline"
        ),
        "language": settings.get("language", "zh-Hans"),
        "appearance": settings.get("appearance", "system"),
    }


def paper_rows(document: dict, now: datetime) -> list[dict]:
    valid = []
    for paper in document.get("papers") or []:
        if not isinstance(paper, dict):
            continue
        try:
            since = parse_date(str(paper.get("since") or ""))
        except ValueError:
            continue
        days = max(0, (now.astimezone().date() - since.astimezone().date()).days)
        valid.append((since, str(paper.get("id") or ""), {**paper, "days": days}))
    valid.sort(key=lambda item: (-item[0].timestamp(), item[1]))
    return [row for _, _, row in valid]


def _dark_mode(appearance: str) -> bool:
    if appearance in {"light", "dark"}:
        return appearance == "dark"
    if sys.platform == "win32":
        import winreg

        try:
            key = r"SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key) as handle:
                return winreg.QueryValueEx(handle, "AppsUseLightTheme")[0] == 0
        except OSError:
            pass
    return False


def _launch(data_dir: Path, *arguments: str) -> None:
    command = [sys.executable]
    if not getattr(sys, "frozen", False):
        command.append(str(Path(__file__).resolve().parents[2] / "launch.py"))
    flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
    subprocess.Popen(command + ["--data-dir", str(data_dir), *arguments], creationflags=flags,
                     env={**os.environ, "PYINSTALLER_RESET_ENVIRONMENT": "1"})


def launch_widget(data_dir: Path, page: str) -> None:
    if page not in PAGES:
        raise AppError("invalid_field")
    _launch(data_dir, "--widget", page)


def show_widget(data_dir: Path, initial_page: str, *, inspect: bool = False) -> dict | None:
    import tkinter as tk
    from tkinter import font, ttk

    if sys.platform == "win32":
        import ctypes

        try:
            ctypes.windll.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
        except AttributeError:
            pass
    window = tk.Tk()
    if inspect:
        window.withdraw()
    window.title("搞研究")
    scaling = float(window.tk.call("tk", "scaling"))
    dpi_factor = scaling / (96 / 72)

    def px(value):
        return max(1, round(value * dpi_factor))

    window.geometry(f"{px(500)}x{px(320)}")
    window.minsize(px(340), px(235))
    if getattr(sys, "frozen", False):
        icon = Path(sys._MEIPASS) / "gaoyanjiu_assets" / "AcademicAchievementManagerIcon.png"
    else:
        icon = Path(__file__).resolve().parents[3] / "Resources" / "AcademicAchievementManagerIcon.png"
    if icon.is_file():
        window.iconphoto(True, tk.PhotoImage(file=icon))
    available_families = {family.casefold() for family in font.families(window)}
    family = next((name for name in ("Microsoft YaHei UI", "Microsoft YaHei", "DengXian", "SimHei")
                   if name.casefold() in available_families), "TkDefaultFont")
    headings = font.Font(family=family, size=12, weight="bold")
    normal = font.Font(family=family, size=10)
    bold = font.Font(family=family, size=10, weight="bold")
    footnote = font.Font(family=family, size=9)
    style = ttk.Style(window)
    style.theme_use("clam")
    canvas = tk.Canvas(window, highlightthickness=0, takefocus=True, relief="flat")
    toolbar = tk.Frame(window)
    toolbar.pack(fill="x", padx=px(10), pady=(px(9), 0))
    canvas.pack(expand=True, fill="both", padx=px(10), pady=(px(8), px(10)))
    state = {"page": initial_page, "document": {}, "readAt": "", "cached": False}

    def select(page: str) -> None:
        state["page"] = page
        paint()

    buttons = [ttk.Button(toolbar, command=lambda page=page: select(page), takefocus=True)
               for page in PAGES]
    for button in buttons:
        button.pack(side="left", padx=(0, px(4)))

    def open_page(_event=None) -> None:
        _launch(data_dir, "gaoyanjiu://" + state["page"])

    open_button = ttk.Button(toolbar, command=open_page, takefocus=True)
    open_button.pack(side="right")
    canvas.bind("<Double-1>", open_page)
    canvas.bind("<Return>", open_page)

    def paint(_event=None, *, dimensions=None) -> None:
        document = state["document"]
        english = document.get("language") == "en"
        dark = _dark_mode(document.get("appearance", "system"))
        bg, card, raised, fg, muted, selected, line, accent, accent_text, note, urgent = (
            ("#131b21", "#1d2931", "#24323a", "#eef5f6", "#aebfc7", "#24423f", "#3a4a53", "#7bd6c2", "#102a28", "#f3bd74", "#ffaaa5") if dark
            else ("#eef2f4", "#ffffff", "#f5f8f8", "#1f2c33", "#52646e", "#e0f0ec", "#d4dfe1", "#12665a", "#ffffff", "#8b5413", "#a93136")
        )
        secondary = "#84bbe6" if dark else "#256b96"
        labels = ("Submissions", "Achievements", "Open app") if english else ("在投状态", "成果统计", "打开工作台")
        window.configure(bg=bg)
        toolbar.configure(bg=bg)
        canvas.configure(bg=card, highlightbackground=line, highlightcolor=accent, highlightthickness=px(1))
        for key, surface, color, border, hover in (
            ("WidgetTab.TButton", bg, muted, bg, raised),
            ("WidgetSelected.TButton", selected, accent, line, selected),
            ("WidgetOpen.TButton", accent, accent_text, accent, accent),
        ):
            style.configure(key, width=0, font=normal, padding=(px(9), px(4)), relief="flat", foreground=color,
                            background=surface, bordercolor=border, lightcolor=surface, darkcolor=surface, focuscolor=color)
            style.map(key, background=[("active", hover)], bordercolor=[("focus", accent), ("active", line)])
        for button, text, active in zip([*buttons, open_button], labels, [
            state["page"] == "submissions", state["page"] == "works", False,
        ]):
            kind = "WidgetOpen.TButton" if button is open_button else "WidgetSelected.TButton" if active else "WidgetTab.TButton"
            button.configure(text=text, style=kind)
        canvas.delete("all")
        width, height = dimensions or (canvas.winfo_width(), canvas.winfo_height())
        margin = px(11)
        right = width - margin - px(1)
        if width <= margin * 2 or height <= margin * 2:
            return

        def text(x, y, value, color=fg, face=normal, anchor="nw", limit=None):
            value = str(value)[:512].replace("\n", " ")
            if limit is not None and face.measure(value) > limit:
                if limit < face.measure("…"):
                    return
                lower, upper = 0, len(value)
                while lower < upper:
                    cursor = (lower + upper + 1) // 2
                    if face.measure(value[:cursor] + "…") <= limit:
                        lower = cursor
                    else:
                        upper = cursor - 1
                value = value[:lower] + "…"
            canvas.create_text(x, y, text=value, fill=color, font=face, anchor=anchor)

        def bar(x, y, span, fraction, color):
            thickness = px(3)
            canvas.create_rectangle(x, y, x + span, y + thickness, fill=line, width=0)
            if fraction:
                canvas.create_rectangle(x, y, x + max(2, span * fraction), y + thickness, fill=color, width=0)

        submissions = state["page"] == "submissions"
        title = (("Submission duration" if english else "在投状态持续时间") if submissions
                 else ("Research achievements" if english else "成果与署名分布"))
        total = len(document.get("papers", [])) if submissions else document.get("works", 0)
        quantity = (f"{total} papers" if submissions else f"{total} items") if english else f"{total} {'篇' if submissions else '项'}"
        text(margin, margin, title, face=headings, limit=right - margin - bold.measure(quantity) - px(14))
        text(right, margin + px(1), quantity, color=accent, face=bold, anchor="ne")
        offset = margin + headings.metrics("linespace") + px(12)
        footer_y = height - px(8) - footnote.metrics("linespace")
        canvas.create_line(margin, offset - px(5), right, offset - px(5), fill=line)
        available = max(0, footer_y - offset - px(9))
        line_height = normal.metrics("linespace")
        row_min = line_height + px(11)
        footer_extra = ""
        if not document.get("statisticsRevision"):
            text(width / 2, height / 2, "打开工作台以同步数据。" if not english else
                 "Open the app to sync statistics.", color=muted, anchor="center", limit=right - margin)
        elif submissions:
            rows = paper_rows(document, utcnow())
            maximum = max([1, *(row["days"] for row in rows)])
            visible = rows[:available // row_min]
            if not rows:
                text(width / 2, height / 2, "No submissions" if english else "暂无在投论文", color=muted, anchor="center", limit=right - margin)
            if visible and len(visible) < len(rows):
                footer_extra = f"Newest {len(visible)}/{len(rows)}" if english else f"最新 {len(visible)}/{len(rows)} 篇"
            row_height = min(px(46), available / max(1, len(visible)))
            for index, row in enumerate(visible):
                y = offset + index * row_height
                days = row["days"]
                duration = f"{days} {'d' if english else '天'}"
                color = muted if row.get("terminal") else urgent if days >= 90 else note if days >= 60 else accent
                if not row.get("terminal") and days >= 60:
                    flag = ("Overdue" if days >= 90 else "Watch") if english else ("超期" if days >= 90 else "关注")
                    duration = f"{flag} · {duration}"
                duration_width = bold.measure(duration)
                text(margin, y, row.get("title", ""), limit=max(0, right - margin - duration_width - px(11)))
                text(right, y, duration, color=color, face=bold, anchor="ne")
                bar(margin, y + line_height + px(3), right - margin, days / maximum, color)
        else:
            gap = px(18)
            span = (right - margin - gap) / 2
            canvas.create_line(margin + span + gap / 2, offset, margin + span + gap / 2,
                               max(offset, footer_y - px(8)), fill=line)
            for index, (key, heading, color) in enumerate((
                ("categories", "Categories" if english else "成果类别", accent),
                ("authors", "Authorship" if english else "我的署名", secondary),
            )):
                x = margin + index * (span + gap)
                text(x, offset, heading, face=bold, limit=span)
                rows = document.get(key, [])
                row_space = max(0, available - line_height - px(7))
                visible = rows[:row_space // row_min]
                maximum = max([1, *(row["count"] for row in rows)])
                if not rows:
                    text(x + span / 2, height / 2, "—", color=muted, anchor="center")
                if len(visible) < len(rows):
                    footer_extra = "Enlarge to see all" if english else "放大查看全部"
                for row_index, row in enumerate(visible):
                    y = offset + line_height + px(7) + row_index * min(px(44), row_space / len(visible))
                    text(x, y, row["label"], limit=max(0, span - normal.measure(f'{row["count"]}  ')))
                    text(x + span, y, row["count"], color=color, face=bold, anchor="ne")
                    bar(x, y + line_height + px(3), span, row["count"] / maximum, color)
        if document.get("dataChangedAt"):
            baseline = document.get("dataChangedAtBasis") == "source-write-baseline"
            prefix = (("Baseline" if baseline else "Stats") if english else ("统计基准" if baseline else "统计更新"))
            read_prefix = (("Saved read" if state["cached"] else "Read") if english
                           else ("缓存读取" if state["cached"] else "读取"))
            canvas.create_line(margin, footer_y - px(4), right, footer_y - px(4), fill=line)
            text(margin, footer_y, f'{prefix} {document["dataChangedAt"][:10]}  ·  {read_prefix} {state["readAt"]}',
                 color=muted, face=footnote, limit=max(0, right - margin - footnote.measure(footer_extra) - px(6)))
            text(right, footer_y, footer_extra, color=muted, face=footnote, anchor="ne")

    def refresh() -> None:
        document = read_snapshot(data_dir / SNAPSHOT_NAME)
        if document.get("statisticsRevision"):
            state.update(document=document, readAt=datetime.now().strftime("%m-%d %H:%M"), cached=False)
        elif state["document"]:
            state["cached"] = True
        paint()
        window.after(30_000, refresh)

    canvas.bind("<Configure>", paint)
    if inspect:
        try:
            data = read_snapshot(data_dir / SNAPSHOT_NAME)
            state.update(document=data, readAt=datetime.now().strftime("%m-%d %H:%M"))
            layouts = []
            for page in PAGES:
                state["page"] = page
                for appearance in ("light", "dark"):
                    state["document"]["appearance"] = appearance
                    for size in ((340, 200), (500, 280), (750, 420)):
                        paint(dimensions=tuple(px(value) for value in size))
                        layouts.append({"page": page, "appearance": appearance, "size": size,
                                        "color": canvas.cget("bg"), "items": len(canvas.find_all())})
            return {"tk": tk.TkVersion, "scaling": scaling, "layouts": layouts}
        finally:
            window.destroy()
    window.after_idle(refresh)
    window.mainloop()
    return None
