import hashlib
import logging
import random
import re
import sqlite3
import threading
import time
import weakref
from collections import OrderedDict, defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

import orjson

from .config import Config
from .curation import read_banners, read_themes, read_tv, tv_status
from .textnorm import fold, query

logger = logging.getLogger(__name__)
FEATURED_EXCLUDED_PHRASES = ("机翻", "机润", "润色", "请返回", "介意者", "语言模型")


def current_date(config: Config) -> str:
    return datetime.now(config.tz).date().isoformat()


class LRU:
    def __init__(self, capacity: int):
        self.capacity = capacity
        self.items = OrderedDict()
        self.lock = threading.Lock()

    def get(self, key):
        with self.lock:
            if key not in self.items:
                return None
            self.items.move_to_end(key)
            return self.items[key]

    def put(self, key, value):
        with self.lock:
            self.items[key] = value
            self.items.move_to_end(key)
            if len(self.items) > self.capacity:
                self.items.popitem(last=False)


class Catalog:
    def __init__(self, config: Config, meta: dict, books: dict[str, dict], *, banners=None, tv=None, themes=None, content_hash=None):
        self.config = config
        self.version = meta.get("version", "")
        self.content_version = self.version + "." + (content_hash or hashlib.sha1(b"").hexdigest()[:8])
        self.banners = banners or []
        self.tv_data = tv or {"upcoming": [], "completed": []}
        self.themes = themes or []
        self.meta = {"version": self.version, "built_at": meta.get("built_at", ""),
                     "content_version": self.content_version,
                     "books": int(meta.get("book_count", 0)), "volumes": int(meta.get("volume_count", 0))}
        self.books = books
        self._toc_connection = None
        self._toc_lock = threading.Lock()
        self._has_toc = False
        self.summaries = {}
        self.by_tag = defaultdict(set)
        self.by_status = defaultdict(set)
        self.random_cache = LRU(64)
        base = config.public_base
        for book_id, book in books.items():
            key = book["cover_key"]
            self.summaries[book_id] = {
                **{field: book[field] for field in ("id", "title", "author", "status", "words", "updated")},
                "tags": book["tags"][:5], "volumes": book["volume_count"],
                "cover": f"{base}/covers/{book_id}/{key}-240.webp" if key else None,
                "cover_large": f"{base}/covers/{book_id}/{key}-480.webp" if key else None,
            }
            for tag in book["tags"]:
                self.by_tag[tag].add(book_id)
            self.by_status[book["status"]].add(book_id)
        updated = sorted(books, key=lambda key: (books[key]["updated"], int(key)), reverse=True)
        self.sorted_ids = {
            "updated": updated,
            "title": sorted(books, key=lambda key: (books[key]["sort_title"], int(key))),
            "words": sorted(updated, key=lambda key: (books[key]["words"], books[key]["updated"]), reverse=True),
            "volumes": sorted(updated, key=lambda key: (books[key]["volume_count"], books[key]["updated"]), reverse=True),
        }
        self.tags = [{"name": name, "count": len(ids)} for name, ids in
                     sorted(self.by_tag.items(), key=lambda item: (-len(item[1]), item[0]))]
        self.theme_candidates = []
        for theme in self.themes:
            groups = [self.by_tag.get(tag, set()) for tag in theme["tags"]]
            allowed = set.intersection(*groups) if theme["match"] == "all" else set.union(*groups)
            ids = [key for key in updated if key in allowed and books[key]["cover_key"]]
            self.theme_candidates.append((theme, ids))
        self.search_keys = []
        for book_id in updated:
            book = books[book_id]
            title, author, illustrator, publisher = (
                fold(book[field]) for field in ("title", "author", "illustrator", "publisher")
            )
            tags = tuple(fold(tag) for tag in book["tags"])
            labels = fold(" ".join(volume["label"] for volume in book["volume_list"]))
            full_text = " ".join((title, author, illustrator, publisher, *tags, labels))
            self.search_keys.append((book_id, title, author, illustrator, publisher, tags, labels,
                                     book["pinyin_full"], book["pinyin_initials"], full_text))

    @classmethod
    def empty(cls, config: Config):
        return cls(config, {}, {})

    @classmethod
    def load(cls, config: Config):
        meta, books = {}, {}
        connection = None
        has_toc = False
        try:
            if config.catalog_path.exists():
                connection = sqlite3.connect(config.catalog_path.resolve().as_uri() + "?mode=ro", uri=True,
                                             check_same_thread=False)
                connection.row_factory = sqlite3.Row
                meta = dict(connection.execute("SELECT key, value FROM meta"))
                for row in connection.execute("SELECT * FROM books"):
                    book = dict(row)
                    book["tags"] = orjson.loads(book["tags"])
                    book["volume_list"] = []
                    books[book["id"]] = book
                for row in connection.execute("SELECT * FROM volumes ORDER BY book_id, n"):
                    volume = dict(row)
                    volume["chapters"] = 0
                    books[volume.pop("book_id")]["volume_list"].append(volume)
                has_toc = connection.execute(
                    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='volume_toc'").fetchone() is not None
                if has_toc:
                    volumes = {(key, volume["n"]): volume for key, book in books.items()
                               for volume in book["volume_list"]}
                    for row in connection.execute(
                            "SELECT book_id, n, COUNT(*) AS chapters FROM volume_toc GROUP BY book_id, n"):
                        volumes[row["book_id"], row["n"]]["chapters"] = row["chapters"]
            banners, banner_bytes = read_banners(config.data_dir / "banners.json", generated=True)
            tv, tv_bytes = read_tv(config.curation_dir / "tv.json")
            themes, theme_bytes = read_themes(config.curation_dir / "themes.json")
            catalog = cls(config, meta, books, banners=banners, tv=tv, themes=themes,
                          content_hash=hashlib.sha1(banner_bytes + tv_bytes + theme_bytes).hexdigest()[:8])
            catalog._toc_connection = connection
            catalog._has_toc = has_toc
            if connection is not None:
                # Requests retain their Catalog snapshot, so its connection stays
                # open until the last request/reference has released that snapshot.
                weakref.finalize(catalog, connection.close)
            return catalog
        except BaseException:
            if connection is not None:
                connection.close()
            raise

    def detail(self, book_id: str, date: str | None = None) -> dict | None:
        book = self.books.get(book_id)
        if book is None:
            return None
        return {
            **self.summaries[book_id], "tags": book["tags"],
            **{key: book[key] for key in ("illustrator", "publisher", "description", "chapters")},
            "tv": self.tv_detail(book_id, date or current_date(self.config)),
            "volume_list": [
                {**{key: volume[key] for key in ("n", "label", "size", "mtime")},
                 "chapters": volume.get("chapters", 0),
                 "url": f"{self.config.public_base}/files/{book_id}/{volume['n']}.epub"}
                for volume in book["volume_list"]
            ],
        }

    def volume_toc(self, book_id: str, n: int) -> dict | None:
        book = self.books.get(book_id)
        if book is None or not any(volume["n"] == n for volume in book["volume_list"]):
            return None
        items = []
        if self._has_toc:
            with self._toc_lock:
                items = [dict(row) for row in self._toc_connection.execute(
                    "SELECT title, href, level FROM volume_toc WHERE book_id=? AND n=? ORDER BY idx", (book_id, n))]
        return {"book_id": book_id, "n": n, "items": items}

    def listing(self, tags=(), status=None, sort="updated", seed=None, offset=0, limit=30,
                *, min_volumes=None, max_volumes=None, with_description=False, use_cache=True) -> dict:
        cache_key = (self.version, seed, tuple(sorted(tags)), status, min_volumes, max_volumes)
        ids = self.random_cache.get(cache_key) if sort == "random" and use_cache else None
        if ids is None:
            filters = [self.by_tag.get(tag, set()) for tag in tags]
            if status:
                filters.append(self.by_status.get(status, set()))
            allowed = set.intersection(*filters) if filters else None
            base = self.sorted_ids["updated" if sort == "random" else sort]
            ids = [key for key in base if key in allowed] if allowed is not None else base
            if min_volumes is not None:
                ids = [key for key in ids if self.books[key]["volume_count"] >= min_volumes]
            if max_volumes is not None:
                ids = [key for key in ids if self.books[key]["volume_count"] <= max_volumes]
            if sort == "random":
                ids = list(ids)
                random.Random(f"{self.version}:{seed}").shuffle(ids)
                if use_cache:
                    self.random_cache.put(cache_key, ids)
        items = [{**self.summaries[key], "description": self.books[key]["description"][:80]}
                 if with_description else self.summaries[key] for key in ids[offset:offset + limit]]
        return {"total": len(ids), "offset": offset, "limit": limit, "items": items}

    def tag_listing(self, covers=0, rankings=None):
        if not covers:
            return {"tags": self.tags}
        totals = rankings.counts.get("total", {}) if rankings is not None else {}
        ids = [key for key in self.sorted_ids["updated"] if self.books[key]["cover_key"]]
        ids.sort(key=lambda key: totals.get(key, 0), reverse=True)
        previews = {tag["name"]: [] for tag in self.tags}
        for key in ids:
            for tag in self.books[key]["tags"]:
                if len(previews[tag]) < covers:
                    previews[tag].append(self.summaries[key]["cover"])
        return {"tags": [{**tag, "covers": previews[tag["name"]]} for tag in self.tags]}

    def discover(self, date: str):
        candidates = [key for key in self.sorted_ids["updated"]
                      if self.books[key]["cover_key"] and self.books[key]["volume_count"] >= 2
                      and len(self.books[key]["description"]) >= 60
                      and not any(phrase in self.books[key]["description"][:120] for phrase in FEATURED_EXCLUDED_PHRASES)]
        pick = None
        if candidates:
            key = random.Random(f"{self.version}:{date}:pick").choice(candidates)
            pick = {**self.summaries[key], "description": self.books[key]["description"][:160]}
        themes = []
        available = [(theme, ids) for theme, ids in self.theme_candidates if ids]
        for theme, ids in random.Random(f"{self.version}:{date}:themes").sample(available, min(6, len(available))):
            selected = random.Random(f"{self.version}:{date}:theme:{theme['key']}").sample(ids, min(10, len(ids)))
            themes.append({**{key: theme[key] for key in ("key", "title", "tags")}, "total": len(ids),
                           "items": [self.summaries[key] for key in selected]})
        return {"version": self.version, "date": date, "pick": pick, "themes": themes}

    def theme_listing(self, key: str, sort="updated", seed=None, offset=0, limit=30):
        (theme, candidates), = [(theme, ids) for theme, ids in self.theme_candidates if theme["key"] == key]
        cache_key = ("theme", self.version, key, seed)
        ids = self.random_cache.get(cache_key) if sort == "random" else None
        if ids is None:
            allowed = set(candidates)
            ids = [book_id for book_id in self.sorted_ids["updated" if sort == "random" else sort] if book_id in allowed]
            if sort == "random":
                random.Random(f"{self.version}:{seed}").shuffle(ids)
                self.random_cache.put(cache_key, ids)
        return {**{name: theme[name] for name in ("key", "title", "tags")}, "total": len(ids),
                "offset": offset, "limit": limit, "items": [self.summaries[book_id] for book_id in ids[offset:offset + limit]]}

    def search(self, raw_query: str, offset=0, limit=30) -> dict:
        q = query(raw_query)
        pinyin = len(q) >= 2 and re.fullmatch("[a-z]+", q) is not None
        words = q.split(" ") if " " in q else ()
        buckets = [[] for _ in range(8)]
        for key, title, author, illustrator, publisher, tags, labels, full, initials, text in self.search_keys:
            if q == title:
                bucket = 0
            elif title.startswith(q):
                bucket = 1
            elif q in title:
                bucket = 2
            elif pinyin and (initials.startswith(q) or q in full):
                bucket = 3
            elif q in author or q in illustrator:
                bucket = 4
            elif q in tags:
                bucket = 5
            elif q in publisher or q in labels:
                bucket = 6
            elif words and all(word in text for word in words):
                bucket = 7
            else:
                continue
            buckets[bucket].append(key)
        ids = [key for bucket in buckets for key in bucket]
        return {"q": raw_query, "total": len(ids), "offset": offset, "limit": limit,
                "items": [self.summaries[key] for key in ids[offset:offset + limit]]}

    def tv_sections(self, date: str) -> dict[str, list[dict]]:
        sections = {"airing": [], "upcoming": [], "completed": []}
        for source in ("upcoming", "completed"):
            for item in self.tv_data[source]:
                if item["book_id"] not in self.summaries:
                    continue
                status = tv_status(item, source, date)
                sections[status].append({**self.summaries[item["book_id"]], "tv_status": status,
                                         **{key: item[key] for key in ("season", "badge", "studio")}})
        return sections

    def tv_listing(self, section: str, date: str, offset=0, limit=30):
        items = self.tv_sections(date)[section]
        return {"section": section, "total": len(items), "offset": offset, "limit": limit,
                "items": items[offset:offset + limit]}

    def tv_detail(self, book_id: str, date: str):
        for source in ("upcoming", "completed"):
            for item in self.tv_data[source]:
                if item["book_id"] == book_id:
                    return {**{key: item[key] for key in ("season", "badge", "studio")},
                            "tv_status": tv_status(item, source, date)}
        return None

    def banner_items(self):
        return [{"key": item["key"],
                 "image": f"{self.config.public_base}/banners/{item['key']}-{item['hash']}-1200.webp",
                 "image_small": f"{self.config.public_base}/banners/{item['key']}-{item['hash']}-600.webp",
                 "book": self.summaries[item["book_id"]]} for item in self.banners if item["book_id"] in self.books]

    def home(self, date: str, rankings=None) -> dict:
        used = set()
        sections = []
        for key, count in (("featured", 6), ("picks", 6), ("rank", 10), ("recent", 12),
                           ("tv", 12), ("completed", 6), ("long", 6)):
            if key == "rank":
                if rankings is None:
                    from .rank import Rankings
                    rankings = Rankings(self, "", {}, date)
                sections.append({"key": key, "items": rankings.items["week"][:count]})
                continue
            if key == "tv":
                tv = self.tv_sections(date)
                sections.append({"key": key, "items": (tv["airing"] + tv["upcoming"] + tv["completed"])[:count]})
                continue
            candidates = []
            for book_id in self.sorted_ids["updated"]:
                if book_id in used:
                    continue
                book = self.books[book_id]
                has_cover = bool(book["cover_key"])
                if ((key == "featured" and has_cover and len(book["description"]) >= 40 and book["volume_count"] >= 2
                     and not any(phrase in book["description"][:120] for phrase in FEATURED_EXCLUDED_PHRASES))
                    or key == "recent" or (key == "picks" and has_cover)
                    or (key == "completed" and has_cover and book["status"] == "completed")
                    or (key == "long" and has_cover and book["volume_count"] >= 8)):
                    candidates.append(book_id)
            selected = candidates[:count] if key == "recent" else random.Random(
                f"{self.version}:{date}:{key}"
            ).sample(candidates, min(count, len(candidates)))
            used.update(selected)
            items = [self.summaries[book_id] for book_id in selected]
            if key == "featured":
                items = [{**item, "description": self.books[item["id"]]["description"][:80]} for item in items]
            sections.append({"key": key, "items": items})
        return {"version": self.version, "date": date, "banners": self.banner_items(),
                "sections": sections, "tags": self.tags[:24]}


class CatalogStore:
    def __init__(self, config: Config):
        self.config = config
        self.catalog = Catalog.empty(config)
        self.stamp = None
        self.last_check = time.monotonic()
        self.lock = threading.Lock()
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="catalog-reload")
        self.future = None
        try:
            stamp = self._stamp()
            if stamp is not None:
                self.catalog = Catalog.load(config)
                self.stamp = stamp
        except Exception:
            logger.exception("Could not load catalog at startup")

    def _stamp(self):
        stamps = []
        for path in (self.config.catalog_path, self.config.data_dir / "banners.json",
                     self.config.curation_dir / "tv.json", self.config.curation_dir / "themes.json"):
            try:
                info = path.stat()
                stamps.append((info.st_ino, info.st_mtime_ns))
            except FileNotFoundError:
                stamps.append(None)
        return tuple(stamps)

    def snapshot(self) -> Catalog:
        now = time.monotonic()
        with self.lock:
            if now - self.last_check >= self.config.reload_check_seconds:
                self.last_check = now
                if self.future is None or self.future.done():
                    try:
                        stamp = self._stamp()
                        if stamp != self.stamp:
                            self.future = self.executor.submit(self._reload, stamp)
                    except OSError:
                        logger.exception("Could not check catalog")
            return self.catalog

    def _reload(self, stamp):
        try:
            if stamp[0] is None and self.stamp is not None and self.stamp[0] is not None:
                raise FileNotFoundError(self.config.catalog_path)
            catalog = Catalog.load(self.config)
            with self.lock:
                self.catalog = catalog
                self.stamp = stamp
        except Exception:
            logger.exception("Could not reload catalog; keeping previous data")

    def close(self):
        self.executor.shutdown(wait=True)
