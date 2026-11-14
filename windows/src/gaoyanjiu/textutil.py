from __future__ import annotations

import re
import zipfile
from pathlib import Path
from xml.etree import ElementTree

from gaoyanjiu.errors import AppError
from gaoyanjiu.fsutil import is_regular_file

MAX_INDEX_CHARS = 200_000
TEXT_EXTENSIONS = {"txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml", "rtf"}
OOXML = {
    "docx": ("word/document.xml",),
    "pptx": ("ppt/slides/",),
    "xlsx": ("xl/sharedStrings.xml", "xl/worksheets/"),
}


def _collapse(text: str) -> str | None:
    cleaned = re.sub(r"\s+", " ", text).strip()
    if not cleaned:
        return None
    return cleaned[:MAX_INDEX_CHARS]


def _xml_text(payload: bytes) -> str:
    try:
        root = ElementTree.fromstring(payload)
    except ElementTree.ParseError:
        return ""
    return " ".join(piece for piece in root.itertext() if piece and piece.strip())


def _ooxml_text(path: Path, prefixes: tuple[str, ...]) -> str | None:
    if not is_regular_file(path):
        raise AppError("unsafe_file")
    try:
        with zipfile.ZipFile(path) as archive:
            names = [name for name in archive.namelist() if not name.endswith("/")]
            chosen = [
                name
                for name in names
                if any(name == prefix or name.startswith(prefix) for prefix in prefixes)
                and not name.startswith("__MACOSX/")
                and ".." not in name.split("/")
            ]
            chunks = []
            for name in chosen:
                chunks.append(_xml_text(archive.read(name)))
    except (zipfile.BadZipFile, OSError):
        return None
    return _collapse(" ".join(chunks))


def _plain_text(path: Path) -> str | None:
    if not is_regular_file(path):
        raise AppError("unsafe_file")
    raw = path.read_bytes()[: 2 * MAX_INDEX_CHARS]
    for encoding in ("utf-8", "utf-16"):
        try:
            return _collapse(raw.decode(encoding))
        except UnicodeError:
            continue
    return None


def _pdf_text(path: Path) -> str | None:
    """提取未压缩 PDF 里的可见文字。扫描件和压缩流不会被猜成正文。"""
    if not is_regular_file(path):
        raise AppError("unsafe_file")
    raw = path.read_bytes()[: 8 * 1024 * 1024]
    if not raw.startswith(b"%PDF"):
        return None
    pieces = []
    for match in re.finditer(rb"\((?:\\.|[^\\\)])*\)", raw):
        token = match.group(0)[1:-1]
        token = token.replace(b"\\n", b"\n").replace(b"\\r", b"\r").replace(b"\\t", b"\t")
        token = token.replace(b"\\(", b"(").replace(b"\\)", b")").replace(b"\\\\", b"\\")
        try:
            pieces.append(token.decode("utf-8"))
        except UnicodeError:
            try:
                pieces.append(token.decode("latin-1"))
            except UnicodeError:
                continue
    return _collapse(" ".join(pieces))


def extract_text(path: Path) -> str | None:
    extension = path.suffix.lower().lstrip(".")
    if extension in TEXT_EXTENSIONS:
        return _plain_text(path)
    if extension in OOXML:
        return _ooxml_text(path, OOXML[extension])
    if extension == "pdf":
        return _pdf_text(path)
    return None
