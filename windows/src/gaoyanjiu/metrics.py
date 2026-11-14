from __future__ import annotations

import json
from datetime import datetime
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from gaoyanjiu.errors import AppError
from gaoyanjiu.timeutil import format_iso

CROSSREF_URL = "https://api.crossref.org/journals"
EASYSCHOLAR_URL = "https://www.easyscholar.cc/open/getPublicationRank"
USER_AGENT = "GaoYanJiu/4.14 (Windows)"
IGNORED = {"", "-", "null", "undefined", "none", "false", "否", "无"}
SUMMARY_PRIORITY = (
    "sci",
    "ssci",
    "esci",
    "eii",
    "ei",
    "sciUp",
    "sciif",
    "pku",
    "cssci",
    "cscd",
    "zhongguokejihexin",
    "ami",
)

def _descriptor(label: str, group: str, order: int) -> dict:
    return {"label": label, "group": group, "order": order}


DESCRIPTORS = {
    "sci": _descriptor("SCIE / JCR 分区", "internationalIndex", 10),
    "ssci": _descriptor("SSCI / JCR 分区", "internationalIndex", 20),
    "esci": _descriptor("ESCI", "internationalIndex", 30),
    "eii": _descriptor("EI", "internationalIndex", 40),
    "ei": _descriptor("EI", "internationalIndex", 40),
    "ahci": _descriptor("A&HCI", "internationalIndex", 50),
    "scopus": _descriptor("Scopus", "internationalIndex", 60),
    "sciUp": _descriptor("大类分区", "casPartition", 10),
    "sciUpSmall": _descriptor("小类分区", "casPartition", 20),
    "sciUpTop": _descriptor("Top 期刊", "casPartition", 30),
    "sciBase": _descriptor("基础版分区", "casPartition", 40),
    "sciwarn": _descriptor("预警期刊", "casPartition", 50),
    "sciif": _descriptor("影响因子 IF", "impact", 10),
    "sciif5": _descriptor("五年影响因子", "impact", 20),
    "jci": _descriptor("JCI", "impact", 30),
    "esi": _descriptor("ESI 学科", "impact", 40),
    "pku": _descriptor("北大中文核心", "chineseCore", 10),
    "cssci": _descriptor("CSSCI 南大核心", "chineseCore", 20),
    "cscd": _descriptor("CSCD", "chineseCore", 30),
    "zhongguokejihexin": _descriptor("中国科技核心", "chineseCore", 40),
    "cstpcd": _descriptor("中国科技核心", "chineseCore", 40),
    "ami": _descriptor("AMI 核心", "chineseCore", 50),
    "rccse": _descriptor("RCCSE 武大核心", "chineseCore", 60),
    "scd": _descriptor("SCD 源期刊", "chineseCore", 70),
    "ccf": _descriptor("CCF", "other", 10),
    "ajg": _descriptor("AJG", "other", 20),
    "fms": _descriptor("FMS", "other", 30),
    "ft50": _descriptor("FT50", "other", 40),
    "utd24": _descriptor("UTD24", "other", 50),
    "swufe": _descriptor("西南财经大学", "other", 100),
    "cufe": _descriptor("中央财经大学", "other", 110),
    "uibe": _descriptor("对外经济贸易大学", "other", 120),
    "sdufe": _descriptor("山东财经大学", "other", 130),
    "xdu": _descriptor("西安电子科技大学", "other", 140),
    "swjtu": _descriptor("西南交通大学", "other", 150),
    "ruc": _descriptor("中国人民大学", "other", 160),
    "xmu": _descriptor("厦门大学", "other", 170),
    "sjtu": _descriptor("上海交通大学", "other", 180),
    "fdu": _descriptor("复旦大学", "other", 190),
    "hhu": _descriptor("河海大学", "other", 200),
    "cqu": _descriptor("重庆大学", "other", 210),
    "nju": _descriptor("南京大学", "other", 220),
    "xju": _descriptor("新疆大学", "other", 230),
    "cug": _descriptor("中国地质大学", "other", 240),
    "cpu": _descriptor("中国药科大学", "other", 250),
    "scu": _descriptor("四川大学", "other", 260),
    "zju": _descriptor("浙江大学", "other", 270),
    "cju": _descriptor("长江大学", "other", 280),
}


def clean_string(value) -> str | None:
    if value is None:
        return None
    if isinstance(value, bool):
        return "是" if value else None
    if isinstance(value, (int, float)):
        result = str(value)
    elif isinstance(value, str):
        result = value
    elif isinstance(value, list):
        result = "、".join(part for part in (clean_string(item) for item in value) if part)
    elif isinstance(value, dict):
        parts = []
        for key in sorted(value):
            child = clean_string(value[key])
            if child:
                parts.append(f"{key}：{child}")
        result = "；".join(parts)
    else:
        return None
    cleaned = result.strip()
    if cleaned.lower() in IGNORED:
        return None
    return cleaned


def display_text(item: dict) -> str:
    label = str(item.get("label") or "").strip()
    value = str(item.get("value") or "").strip()
    if value == "是" or label.casefold() == value.casefold():
        return label
    return " ".join(part for part in (label, value) if part)


def summary_items(items: list[dict]) -> list[dict]:
    def rank(item: dict) -> tuple[int, int]:
        key = str(item.get("key") or "")
        try:
            position = SUMMARY_PRIORITY.index(key)
        except ValueError:
            position = len(SUMMARY_PRIORITY) + int(item.get("order") or 0)
        return position, int(item.get("order") or 0)

    seen = set()
    rows = []
    for item in sorted(items, key=rank):
        identity = display_text(item).casefold()
        if identity in seen:
            continue
        seen.add(identity)
        rows.append(item)
    return rows


def _custom_items(payload: dict) -> list[dict]:
    custom = payload.get("customRank")
    if not isinstance(custom, dict):
        return []
    ranks = custom.get("rank")
    if not isinstance(ranks, list):
        return []
    raw_infos = custom.get("rankInfo")
    infos: dict[str, dict] = {}
    if isinstance(raw_infos, list):
        for info in raw_infos:
            if isinstance(info, dict) and clean_string(info.get("uuid")):
                infos[clean_string(info.get("uuid"))] = info
    elif isinstance(raw_infos, dict):
        for key, info in raw_infos.items():
            if isinstance(info, dict):
                copied = dict(info)
                copied.setdefault("uuid", key)
                identity = clean_string(copied.get("uuid"))
                if identity:
                    infos[identity] = copied
    level_keys = ["oneRankText", "twoRankText", "threeRankText", "fourRankText", "fiveRankText"]
    rows = []
    chinese_keywords = ("核心", "AMI", "CSSCI", "CSCD", "RCCSE", "中文", "中国科技")
    for index, raw_rank in enumerate(ranks):
        if not isinstance(raw_rank, str):
            continue
        components = raw_rank.split("&&&")
        if len(components) != 2 or components[0] not in infos:
            continue
        try:
            level = int(components[1])
        except ValueError:
            continue
        if level < 1 or level > 5:
            continue
        info = infos[components[0]]
        label = clean_string(info.get("abbName")) or clean_string(info.get("name")) or "自定义评价"
        value = clean_string(info.get(level_keys[level - 1])) or f"{level} 级"
        group = "chineseCore" if any(word.lower() in label.lower() for word in chinese_keywords) else "other"
        rows.append(
            {
                "key": f"custom:{components[0]}",
                "label": label,
                "value": value,
                "group": group,
                "order": 2000 + index,
            }
        )
    return rows


def parse_easyscholar(payload: dict, query: str, now: datetime | None = None) -> dict:
    code = payload.get("code")
    try:
        code_value = int(code)
    except (TypeError, ValueError):
        code_value = -1
    if code_value != 200:
        raise AppError("service_error", detail=clean_string(payload.get("msg")))
    data = payload.get("data")
    if not isinstance(data, dict) or not isinstance(data.get("officialRank"), dict):
        raise AppError("invalid_response")
    official = data["officialRank"]
    ranks = dict(official.get("all") or {})
    selected = official.get("select")
    if isinstance(selected, dict):
        for key, value in selected.items():
            ranks.setdefault(key, value)
    items = []
    for key, raw_value in ranks.items():
        value = clean_string(raw_value)
        if value is None:
            continue
        descriptor = DESCRIPTORS.get(key) or {"label": str(key).upper(), "group": "other", "order": 1000}
        items.append(
            {
                "key": key,
                "label": descriptor["label"],
                "value": value,
                "group": descriptor["group"],
                "order": descriptor["order"],
            }
        )
    items.extend(_custom_items(data))
    seen_keys = set()
    seen_metrics = set()
    unique = []
    for item in items:
        metric_identity = display_text(item).casefold()
        key_identity = str(item["key"]).lower()
        if key_identity in seen_keys or metric_identity in seen_metrics:
            continue
        seen_keys.add(key_identity)
        seen_metrics.add(metric_identity)
        unique.append(item)
    if not unique:
        raise AppError("no_metrics")
    matched = (
        clean_string(data.get("publicationName"))
        or clean_string(data.get("paperName"))
        or clean_string(data.get("name"))
        or query
    )
    return {
        "query": query,
        "matchedJournalName": matched,
        "source": "EasyScholar",
        "casEdition": "2025",
        "lookedUpAt": format_iso(now or datetime.now().astimezone()),
        "items": unique,
    }


def parse_crossref(payload: dict) -> list[dict]:
    message = payload.get("message") if isinstance(payload, dict) else None
    items = message.get("items") if isinstance(message, dict) else None
    if not isinstance(items, list):
        return []
    seen = set()
    rows = []
    for item in items:
        if not isinstance(item, dict):
            continue
        title = str(item.get("title") or "").strip()
        if not title:
            continue
        issns = item.get("ISSN") if isinstance(item.get("ISSN"), list) else []
        issn = str(issns[0]).strip() if issns else ""
        publisher = str(item.get("publisher") or "").strip()
        identity = f"{title.casefold()}|{issn.casefold()}"
        if identity in seen:
            continue
        seen.add(identity)
        rows.append({"title": title, "issn": issn, "publisher": publisher, "id": identity})
    return rows


def _http_json(url: str, timeout: float = 12) -> dict:
    request = Request(url, headers={"Accept": "application/json", "User-Agent": USER_AGENT})
    try:
        with urlopen(request, timeout=timeout) as response:
            status = getattr(response, "status", 200)
            raw = response.read()
    except Exception as exc:
        raise AppError("service_error") from exc
    if status < 200 or status >= 300:
        raise AppError("service_error")
    try:
        parsed = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise AppError("invalid_response") from exc
    if not isinstance(parsed, dict):
        raise AppError("invalid_response")
    return parsed


def suggest_journals(query: str, transport=None) -> list[dict]:
    text = query.strip()
    if len(text) < 2:
        return []
    url = CROSSREF_URL + "?" + urlencode({"query": text, "rows": "8"})
    payload = transport(url) if transport else _http_json(url)
    if isinstance(payload, bytes):
        payload = json.loads(payload.decode("utf-8"))
    return parse_crossref(payload)


def lookup_journal(query: str, secret_key: str, transport=None, now: datetime | None = None) -> dict:
    text = query.strip()
    key = secret_key.strip()
    if not text:
        raise AppError("invalid_query")
    if not key:
        raise AppError("missing_key")
    url = EASYSCHOLAR_URL + "?" + urlencode({"secretKey": key, "publicationName": text})
    payload = transport(url) if transport else _http_json(url, timeout=25)
    if isinstance(payload, bytes):
        payload = json.loads(payload.decode("utf-8"))
    if not isinstance(payload, dict):
        raise AppError("invalid_response")
    return parse_easyscholar(payload, text, now=now)
