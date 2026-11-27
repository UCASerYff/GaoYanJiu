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
    from tkinter import font

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
    window.geometry(f"{round(500 * dpi_factor)}x{round(310 * dpi_factor)}")
    window.minsize(round(340 * dpi_factor), round(230 * dpi_factor))
    if getattr(sys, "frozen", False):
        icon = Path(sys._MEIPASS) / "gaoyanjiu_assets" / "AcademicAchievementManagerIcon.png"
    else:
        icon = Path(__file__).resolve().parents[3] / "Resources" / "AcademicAchievementManagerIcon.png"
    if icon.is_file():
        window.iconphoto(True, tk.PhotoImage(file=icon))
    canvas = tk.Canvas(window, highlightthickness=0, takefocus=True, relief="flat")
    toolbar = tk.Frame(window)
    toolbar.pack(fill="x", padx=round(12 * dpi_factor), pady=(round(8 * dpi_factor), 0))
    canvas.pack(expand=True, fill="both", padx=round(12 * dpi_factor),
                pady=(round(3 * dpi_factor), round(8 * dpi_factor)))
    headings = font.Font(family="Microsoft YaHei UI", size=11, weight="bold")
    normal = font.Font(family="Microsoft YaHei UI", size=9)
    footnote = font.Font(family="Microsoft YaHei UI", size=8)
    state = {"page": initial_page, "document": {}, "readAt": "", "cached": False}

    def select(page: str) -> None:
        state["page"] = page
        paint()

    buttons = [tk.Button(toolbar, command=lambda page=page: select(page), relief="flat", padx=8, pady=4)
               for page in PAGES]
    for button in buttons:
        button.pack(side="left")
    def open_page(_event=None) -> None:
        _launch(data_dir, "gaoyanjiu://" + state["page"])

    open_button = tk.Button(toolbar, command=open_page,
                            relief="flat", padx=8, pady=4)
    open_button.pack(side="right")
    canvas.bind("<Double-1>", open_page)
    canvas.bind("<Return>", open_page)

    def paint(_event=None, *, dimensions=None) -> None:
        document = state["document"]
        english = document.get("language") == "en"
        dark = _dark_mode(document.get("appearance", "system"))
        bg, card, fg, muted, selected, line = (
            ("#202023", "#27272b", "#f3f3f3", "#b8b8c1", "#343b51", "#373a45") if dark
            else ("#f0f1f4", "#fbfbfd", "#23252a", "#5c5e66", "#dbe8ff", "#e5e9f2")
        )
        blue, teal = ("#85b7ff", "#53d4ce") if dark else ("#1474d4", "#007d79")
        labels = ("Submissions", "Achievements", "Open") if english else ("在投状态", "成果统计", "打开")
        window.configure(bg=bg)
        toolbar.configure(bg=bg)
        canvas.configure(bg=card)
        for button, text, active in zip([*buttons, open_button], labels, [
            state["page"] == "submissions", state["page"] == "works", False,
        ]):
            button.configure(text=text, font=normal, bg=selected if active else bg, fg=fg,
                             activebackground=selected, activeforeground=fg)
        canvas.delete("all")
        width, height = dimensions or (canvas.winfo_width(), canvas.winfo_height())
        margin = max(10, round(headings.metrics("linespace") * .68))
        offset = margin
        right = width - margin

        def text(x, y, value, color=fg, face=normal, anchor="nw", limit=None):
            value = str(value)[:512].replace("\n", " ")
            if limit is not None and face.measure(value) > limit:
                while value and face.measure(value + "…") > limit:
                    value = value[:-1]
                value += "…"
            canvas.create_text(x, y, text=value, fill=color, font=face, anchor=anchor)

        def bar(x, y, span, fraction, color):
            thickness = max(3, round(normal.metrics("linespace") / 4))
            canvas.create_rectangle(x, y, x + span, y + thickness, fill=line, width=0)
            if fraction:
                canvas.create_rectangle(x, y, x + max(2, span * fraction), y + thickness, fill=color, width=0)

        submissions = state["page"] == "submissions"
        title = (("Submission duration" if english else "在投状态持续时间") if submissions
                 else ("Research achievements" if english else "成果与署名分布"))
        text(margin, offset, title, face=headings, limit=max(0, width - margin * 4))
        total = len(document.get("papers", [])) if submissions else document.get("works", 0)
        text(right, offset, total, color=blue, face=headings, anchor="ne")
        offset += headings.metrics("linespace") + margin // 2
        footer_y = height - margin - footnote.metrics("linespace")
        available = max(0, footer_y - offset - margin // 2)
        line_height = normal.metrics("linespace")
        row_min = line_height + max(7, line_height // 2)
        footer_extra = ""
        if not document.get("statisticsRevision"):
            text(width / 2, height / 2, "请先打开搞研究，同步小组件数据。" if not english else
                 "Open the app to sync statistics.", color=muted, anchor="center")
        elif submissions:
            rows = paper_rows(document, utcnow())
            maximum = max([1, *(row["days"] for row in rows)])
            visible = rows[:available // row_min]
            if not rows:
                text(width / 2, height / 2, "No submissions" if english else "暂无在投论文", color=muted, anchor="center")
            if visible and len(visible) < len(rows):
                footer_extra = f"Newest {len(visible)}/{len(rows)}" if english else f"最新 {len(visible)}/{len(rows)} 篇"
            row_height = available / max(1, len(visible))
            for index, row in enumerate(visible):
                y = offset + index * row_height
                days = row["days"]
                color = muted if row.get("terminal") else "#d95352" if days >= 90 else "#d88323" if days >= 60 else blue
                duration = f"{days}{'d' if english else '天'}"
                span = right - margin - normal.measure(duration) - margin
                text(margin, y, row.get("title", ""), limit=max(0, span))
                text(right, y, duration, color=color, anchor="ne")
                bar(margin, y + line_height + 2, span, days / maximum, color)
        else:
            gap = margin
            span = (right - margin - gap) / 2
            for index, (key, heading, color) in enumerate((
                ("categories", "Categories" if english else "成果类别", blue),
                ("authors", "Authorship" if english else "我的署名", teal),
            )):
                x = margin + index * (span + gap)
                text(x, offset, heading, face=normal)
                rows = document.get(key, [])
                row_space = max(0, available - line_height - 4)
                visible = rows[:row_space // row_min]
                maximum = max([1, *(row["count"] for row in rows)])
                if not rows:
                    text(x + span / 2, height / 2, "—", color=muted, anchor="center")
                if len(visible) < len(rows):
                    footer_extra = "Enlarge to see all" if english else "放大查看全部"
                for row_index, row in enumerate(visible):
                    y = offset + line_height + 4 + row_index * row_space / len(visible)
                    text(x, y, row["label"], limit=max(0, span - normal.measure(f'{row["count"]}  ')))
                    text(x + span, y, row["count"], color=color, anchor="ne")
                    bar(x, y + line_height + 2, span, row["count"] / maximum, color)
        if document.get("dataChangedAt"):
            baseline = document.get("dataChangedAtBasis") == "source-write-baseline"
            prefix = (("Baseline" if baseline else "Stats") if english else ("统计基准" if baseline else "统计更新"))
            read_prefix = (("Saved read" if state["cached"] else "Read") if english
                           else ("缓存读取" if state["cached"] else "读取"))
            text(margin, footer_y, f'{prefix} {document["dataChangedAt"][:10]}   {read_prefix} {state["readAt"]}',
                 color=muted, face=footnote, limit=max(0, width - 2 * margin - footnote.measure(footer_extra) - 6))
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
                        paint(dimensions=size)
                        layouts.append({"page": page, "appearance": appearance, "size": size,
                                        "color": canvas.cget("bg"), "items": len(canvas.find_all())})
            return {"tk": tk.TkVersion, "scaling": scaling, "layouts": layouts}
        finally:
            window.destroy()
    window.after_idle(refresh)
    window.mainloop()
    return None
