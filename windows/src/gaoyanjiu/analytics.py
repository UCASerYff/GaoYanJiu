from __future__ import annotations

WORK_TYPES = (
    "journalArticle",
    "conferencePaper",
    "graduationThesis",
    "book",
    "bookChapter",
    "patent",
    "dataset",
    "software",
    "other",
)

WORK_TYPE_LABELS = {
    "zh-Hans": {
        "journalArticle": "期刊论文",
        "conferencePaper": "会议论文",
        "graduationThesis": "毕业论文",
        "book": "专著",
        "bookChapter": "书籍章节",
        "patent": "专利",
        "dataset": "数据集",
        "software": "软件成果",
        "other": "其他成果",
        "patent-invention": "发明专利",
        "patent-utilityModel": "实用新型",
        "patent-design": "外观设计",
        "patent-unspecified": "未细分专利",
    },
    "en": {
        "journalArticle": "Journal article",
        "conferencePaper": "Conference paper",
        "graduationThesis": "Thesis",
        "book": "Book",
        "bookChapter": "Book chapter",
        "patent": "Patent",
        "dataset": "Dataset",
        "software": "Software",
        "other": "Other",
        "patent-invention": "Invention patent",
        "patent-utilityModel": "Utility model",
        "patent-design": "Design patent",
        "patent-unspecified": "Unspecified patent",
    },
}

PATENT_TYPES = ("invention", "utilityModel", "design")
AUTHOR_POSITIONS = ("first", "corresponding", "second", "third", "fourth", "fifth", "beyondFifth")
AUTHOR_LABELS = {
    "zh-Hans": {
        "first": "一作",
        "corresponding": "通讯作者",
        "second": "二作",
        "third": "三作",
        "fourth": "四作",
        "fifth": "五作",
        "beyondFifth": "五作+",
    },
    "en": {
        "first": "First author",
        "corresponding": "Corresponding author",
        "second": "Second author",
        "third": "Third author",
        "fourth": "Fourth author",
        "fifth": "Fifth author",
        "beyondFifth": "Beyond fifth",
    },
}

DOCUMENT_KINDS = ("experimentData", "summaryReports", "importantLiterature")
DOCUMENT_KIND_LABELS = {
    "zh-Hans": {
        "experimentData": "实验数据",
        "summaryReports": "总结报告",
        "importantLiterature": "重要文献",
    },
    "en": {
        "experimentData": "Experiment data",
        "summaryReports": "Reports",
        "importantLiterature": "Key literature",
    },
}


def label(table: dict[str, dict[str, str]], language: str, key: str) -> str:
    return (table.get(language) or table["zh-Hans"]).get(key, table["zh-Hans"].get(key, key))


def work_categories(works: list[dict], language: str = "zh-Hans") -> list[dict]:
    rows: list[dict] = []
    for work_type in WORK_TYPES:
        if work_type == "patent":
            for patent_type in PATENT_TYPES:
                count = sum(
                    1
                    for work in works
                    if work.get("type") == "patent" and work.get("patentType") == patent_type
                )
                if count:
                    key = f"patent-{patent_type}"
                    rows.append({"id": key, "label": label(WORK_TYPE_LABELS, language, key), "count": count})
            unspecified = sum(1 for work in works if work.get("type") == "patent" and not work.get("patentType"))
            if unspecified:
                rows.append(
                    {
                        "id": "patent-unspecified",
                        "label": label(WORK_TYPE_LABELS, language, "patent-unspecified"),
                        "count": unspecified,
                    }
                )
            continue
        count = sum(1 for work in works if work.get("type") == work_type)
        if count:
            rows.append(
                {"id": work_type, "label": label(WORK_TYPE_LABELS, language, work_type), "count": count}
            )
    return rows


def chart_height(category_count: int) -> int:
    return max(215, max(0, category_count) * 30 + 35)


def stack_cards(width: float) -> bool:
    return width < 860


def author_positions(works: list[dict], language: str = "zh-Hans") -> list[dict]:
    rows = []
    articles = [work for work in works if work.get("type") == "journalArticle"]
    for position in AUTHOR_POSITIONS:
        count = sum(1 for work in articles if work.get("authorPosition") == position)
        if count:
            rows.append(
                {"id": position, "label": label(AUTHOR_LABELS, language, position), "count": count}
            )
    missing = sum(1 for work in articles if not work.get("authorPosition"))
    if missing:
        rows.append({"id": "unspecified", "label": "未署名位置" if language != "en" else "Unspecified", "count": missing})
    return rows


def certificate_years(records: list[dict]) -> list[dict]:
    counts: dict[str, int] = {}
    for record in records:
        event = str(record.get("eventDate") or "")
        year = event[:4] if len(event) >= 4 and event[:4].isdigit() else "未知"
        counts[year] = counts.get(year, 0) + 1
    return [{"id": year, "label": year, "count": counts[year]} for year in sorted(counts)]
