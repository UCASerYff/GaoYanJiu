from __future__ import annotations

import re
import zipfile
from pathlib import Path
from xml.etree import ElementTree

from gaoyanjiu.errors import AppError
from gaoyanjiu.fsutil import is_regular_file

MAX_INDEX_CHARS = 200_000
MAX_PDF_BYTES = 128 * 1024 * 1024
MAX_PAGE_CONTENT_BYTES = 6 * 1024 * 1024
MAX_OOXML_BYTES = 20 * 1024 * 1024
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
            chosen = [
                entry for entry in archive.infolist()
                if not entry.is_dir()
                and any(entry.filename == prefix or (prefix.endswith("/") and entry.filename.startswith(prefix)) for prefix in prefixes)
                and not entry.filename.startswith("__MACOSX/")
                and ".." not in entry.filename.split("/")
            ]
            chunks = []
            remaining_bytes = MAX_OOXML_BYTES
            remaining_chars = MAX_INDEX_CHARS
            for entry in chosen:
                if entry.file_size > remaining_bytes or remaining_chars <= 0:
                    break
                text = _xml_text(archive.read(entry))[:remaining_chars]
                chunks.append(text)
                remaining_bytes -= entry.file_size
                remaining_chars -= len(text)
    except (zipfile.BadZipFile, RuntimeError, OSError):
        return None
    return _collapse(" ".join(chunks))


def _plain_text(path: Path) -> str | None:
    if not is_regular_file(path):
        raise AppError("unsafe_file")
    with path.open("rb") as stream:
        raw = stream.read(2 * MAX_INDEX_CHARS)
    for encoding in ("utf-8-sig", "utf-16", "gb18030"):
        try:
            return _collapse(raw.decode(encoding))
        except UnicodeError:
            continue
    return None


def _pdf_text(path: Path) -> str | None:
    """Index a bounded prefix of the pages of a PDF with a text layer."""
    if not is_regular_file(path):
        raise AppError("unsafe_file")
    if path.stat().st_size > MAX_PDF_BYTES:
        return None
    try:
        from pypdf import PdfReader
    except ImportError:
        return None

    chunks = []
    remaining = MAX_INDEX_CHARS
    try:
        with path.open("rb") as stream:
            if not stream.read(5).startswith(b"%PDF-"):
                return None
            stream.seek(0)
            reader = PdfReader(stream, strict=False)
            if reader.is_encrypted:
                return None
            for page in reader.pages[:300]:
                try:
                    contents = page.get_contents()
                    if contents is None or len(contents.get_data()) > MAX_PAGE_CONTENT_BYTES:
                        continue
                    text = page.extract_text()[:remaining]
                except Exception:
                    continue
                chunks.append(text)
                remaining -= len(text)
                if remaining <= 0:
                    break
    except Exception:
        return None
    return _collapse(" ".join(chunks))


def extract_text(path: Path) -> str | None:
    extension = path.suffix.lower().lstrip(".")
    if extension in TEXT_EXTENSIONS:
        return _plain_text(path)
    if extension in OOXML:
        return _ooxml_text(path, OOXML[extension])
    if extension == "pdf":
        return _pdf_text(path)
    return None
