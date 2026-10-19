import hashlib
import logging
import os
import re
import stat
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import orjson
from pypinyin import FIRST_LETTER, NORMAL, lazy_pinyin

from .config import Config
from .textnorm import fold

logger = logging.getLogger(__name__)
BOOK_NAME = re.compile(r"^(\d{1,10})_(.+)$")
VOLUME_NAME = re.compile(r"^(\d+)_(.+)\.epub$")
LABEL_SEPARATORS = "-—_:：·・、,，"


@dataclass
class BookSource:
    id: str
    directory: Path
    directory_title: str
    meta: dict
    volumes: list[tuple[str, os.stat_result]]
    cover: Path | None
    signature: str


def read_meta(path: Path) -> dict:
    try:
        value = orjson.loads(path.read_bytes())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def scan_book(entry: os.DirEntry) -> BookSource | None:
    match = BOOK_NAME.fullmatch(entry.name)
    if match is None:
        return None
    # Windows directory enumeration can retain an earlier modification time.
    directory_stat = os.stat(entry.path) if os.name == "nt" else entry.stat()
    if not stat.S_ISDIR(directory_stat.st_mode):
        return None
    directory = Path(entry.path)
    files = {}
    with os.scandir(directory) as children:
        for child in children:
            info = child.stat()
            if stat.S_ISREG(info.st_mode):
                files[child.name] = info
    volumes = sorted((name, info) for name, info in files.items() if VOLUME_NAME.fullmatch(name))
    if not volumes:
        return None
    meta_info = files.get("meta.json")
    meta = read_meta(directory / "meta.json") if meta_info else {}
    cover_name = meta.get("cover_file")
    cover_info = None
    if (isinstance(cover_name, str) and cover_name not in ("", ".", "..")
            and "/" not in cover_name and "\\" not in cover_name):
        cover_info = files.get(cover_name)
    if cover_info is None:
        cover_name = next((name for name in ("cover.jpg", "cover.jpeg", "cover.png", "cover.webp") if name in files), None)
        cover_info = files.get(cover_name)
    signature = hashlib.sha1(orjson.dumps([
        directory_stat.st_mtime_ns,
        [meta_info.st_mtime_ns, meta_info.st_size] if meta_info else "missing",
        [cover_name, cover_info.st_mtime_ns, cover_info.st_size] if cover_info else "none",
        [[name, info.st_size, info.st_mtime_ns] for name, info in volumes],
    ])).hexdigest()
    return BookSource(match[1], directory, match[2], meta, volumes,
                      directory / cover_name if cover_info else None, signature)


def scan_library(config: Config, failed_ids: set[str] | None = None) -> dict[str, BookSource]:
    sources = {}
    candidates = {}
    with os.scandir(config.library_dir) as entries:
        for entry in entries:
            match = BOOK_NAME.fullmatch(entry.name)
            if match is None:
                continue
            try:
                if not entry.is_dir():
                    continue
                source = scan_book(entry)
                if source is None:
                    continue
                candidates.setdefault(source.id, []).append(source)
            except Exception:
                if failed_ids is not None:
                    failed_ids.add(match[1])
                logger.exception("Skipping book directory %s", entry.name)
    for book_id, matches in candidates.items():
        if len(matches) > 1:
            logger.error("Duplicate book id %s; ambiguous directories skipped", book_id)
        else:
            sources[book_id] = matches[0]
    return sources


def string_field(meta: dict, name: str) -> str:
    value = meta.get(name)
    return value.strip() if isinstance(value, str) else ""


def parse_words(value) -> int:
    if not isinstance(value, str):
        return 0
    ten_thousand = re.fullmatch(r"\s*([\d.]+)\s*万\s*", value)
    try:
        if ten_thousand:
            return round(float(ten_thousand[1]) * 10000)
        if re.fullmatch(r"\s*(\d+)\s*", value):
            return int(value)
    except (ValueError, OverflowError):
        pass
    return 0


def volume_label(filename: str, n: int, title: str, directory_title: str) -> str:
    stem = VOLUME_NAME.fullmatch(filename)[2]
    for candidate in (title, directory_title):
        if fold(stem).startswith(fold(candidate)):
            stem = stem[len(candidate):]
            while stem and (stem[0].isspace() or stem[0] in LABEL_SEPARATORS):
                stem = stem[1:]
            break
    return stem or f"第{n}卷"


def parse_book(source: BookSource, config: Config) -> dict:
    meta = source.meta
    title = string_field(meta, "title") or source.directory_title
    volumes = []
    numbers = set()
    for name, info in source.volumes:
        n = int(VOLUME_NAME.fullmatch(name)[1])
        if n in numbers:
            raise ValueError(f"Duplicate volume number {n}")
        numbers.add(n)
        volumes.append({"n": n, "label": volume_label(name, n, title, source.directory_title),
                        "file": name, "size": info.st_size, "mtime": int(info.st_mtime)})
    volumes.sort(key=lambda volume: volume["n"])
    updated = meta.get("last_update")
    if not isinstance(updated, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", updated):
        updated = datetime.fromtimestamp(max(info.st_mtime for _, info in source.volumes), config.tz).strftime("%Y-%m-%d")
    try:
        chapters = int(meta.get("chapter_count", 0))
    except (ValueError, TypeError, OverflowError):
        chapters = 0
    tags = []
    if isinstance(meta.get("tags"), list):
        tags = list(dict.fromkeys(tag.strip() for tag in meta["tags"] if isinstance(tag, str) and tag.strip()))
    full = [fold(part) for part in lazy_pinyin(title, style=NORMAL, errors="default")]
    initials = [fold(part) for part in lazy_pinyin(title, style=FIRST_LETTER, errors="default")]
    status = meta.get("status")
    return {
        "id": source.id, "directory": source.directory.name, "title": title,
        **{name: string_field(meta, name) for name in ("author", "illustrator", "publisher", "description")},
        "status": "completed" if status == "完结" else "ongoing" if status == "连载" else "unknown",
        "words": parse_words(meta.get("word_count")), "chapters": chapters, "updated": updated,
        "tags": tags, "volume_count": len(volumes), "cover_key": "",
        "sort_title": " ".join(full), "pinyin_full": "".join(full).replace(" ", ""),
        "pinyin_initials": "".join(initials).replace(" ", ""),
        "volume_list": volumes,
    }
