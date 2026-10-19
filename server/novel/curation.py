import hashlib
import logging
import os
import re
from datetime import date
from pathlib import Path

import orjson

from .config import Config
from .media import atomic_bytes, decode_rgb, write_images

logger = logging.getLogger(__name__)
KEY = re.compile(r"[a-z0-9-]{1,32}")
BOOK_ID = re.compile(r"\d{1,10}")
SEASON = re.compile(r"(?:(\d{4})年([冬春夏秋])?|剧场版)?")


def read_json(path: Path) -> tuple[dict, bytes]:
    raw = b""
    try:
        raw = path.read_bytes()
        value = orjson.loads(raw)
        if not isinstance(value, dict):
            raise ValueError("Expected object")
        return value, raw
    except (OSError, ValueError) as exc:
        logger.warning("Skipping curation file %s: %s", path, exc)
        return {}, raw


def entries(value: dict, name: str, path: Path):
    items = value.get(name)
    if not isinstance(items, list):
        if value:
            logger.warning("Invalid %s list in %s", name, path)
        return []
    return items


def valid_book_id(item) -> bool:
    return (isinstance(item, dict) and isinstance(item.get("book_id"), str)
            and BOOK_ID.fullmatch(item["book_id"]) is not None)


def read_banners(path: Path, *, generated=False) -> tuple[list[dict], bytes]:
    value, raw = read_json(path)
    result = []
    for item in entries(value, "banners", path):
        valid = valid_book_id(item) and isinstance(item.get("key"), str) and KEY.fullmatch(item["key"])
        if valid and generated:
            valid = isinstance(item.get("hash"), str) and re.fullmatch("[a-f0-9]{12}", item["hash"])
        elif valid:
            image = item.get("image")
            valid = (isinstance(image, str) and "/" not in image and "\\" not in image
                     and Path(image).suffix.lower() in (".jpg", ".png", ".webp"))
        if not valid:
            logger.warning("Skipping invalid banner entry in %s", path)
            continue
        field = "hash" if generated else "image"
        result.append({name: item[name] for name in ("key", "book_id", field)})
    return result, raw


def read_tv(path: Path) -> tuple[dict[str, list[dict]], bytes]:
    value, raw = read_json(path)
    result = {"upcoming": [], "completed": []}
    for section in result:
        for item in entries(value, section, path):
            valid = valid_book_id(item) and all(isinstance(item.get(key), str) for key in ("season", "badge", "studio"))
            if not valid or SEASON.fullmatch(item["season"]) is None:
                logger.warning("Skipping invalid TV entry in %s", path)
                continue
            result[section].append({key: item[key] for key in ("book_id", "season", "badge", "studio")})
    return result, raw


def read_themes(path: Path) -> tuple[list[dict], bytes]:
    value, raw = read_json(path)
    result = []
    seen = set()
    for item in entries(value, "themes", path):
        valid = (isinstance(item, dict) and isinstance(item.get("key"), str) and KEY.fullmatch(item["key"])
                 and isinstance(item.get("title"), str) and bool(item["title"])
                 and item.get("match") in ("all", "any") and isinstance(item.get("tags"), list)
                 and 1 <= len(item["tags"]) <= 5
                 and all(isinstance(tag, str) and bool(tag) for tag in item["tags"]))
        if not valid:
            logger.warning("Skipping invalid theme entry in %s", path)
            continue
        if item["key"] in seen:
            logger.warning("Skipping duplicate theme key %s in %s", item["key"], path)
            continue
        seen.add(item["key"])
        result.append({key: item[key] for key in ("key", "title", "match", "tags")})
    return result, raw


def sync_banners(config: Config):
    source, _ = read_banners(config.curation_dir / "banners.json")
    result = []
    keep = set()
    directory = config.data_dir / "banners"
    for item in source:
        try:
            content = (config.curation_dir / "banners" / item["image"]).read_bytes()
            key = hashlib.sha1(content).hexdigest()[:12]
            prefix = f"{item['key']}-{key}"
            if not all((directory / f"{prefix}-{width}.webp").is_file() for width in (1200, 600)):
                write_images(decode_rgb(content), directory, prefix, (1200, 600), 85)
            result.append({"key": item["key"], "book_id": item["book_id"], "hash": key})
            keep.update(f"{prefix}-{width}.webp" for width in (1200, 600))
        except Exception as exc:
            logger.warning("Skipping banner %s: %s", item["key"], exc)
    payload = orjson.dumps({"banners": result})
    path = config.data_dir / "banners.json"
    try:
        unchanged = path.read_bytes() == payload
    except FileNotFoundError:
        unchanged = False
    if not unchanged:
        atomic_bytes(path, payload)
    if directory.exists():
        with os.scandir(directory) as files:
            for file in files:
                if file.name not in keep and not file.is_dir(follow_symlinks=False):
                    os.unlink(file.path)


def tv_status(item: dict, source: str, today: str) -> str:
    if source == "completed":
        return "completed"
    current = date.fromisoformat(today)
    match = SEASON.fullmatch(item["season"])
    if match[1] is None:
        return "upcoming"
    year = int(match[1])
    if match[2] is None:
        return "completed" if year < current.year else "upcoming"
    season = (year, "冬春夏秋".index(match[2]) + 1)
    quarter = current.year, (current.month - 1) // 3 + 1
    return "airing" if season == quarter else "completed" if season < quarter else "upcoming"
