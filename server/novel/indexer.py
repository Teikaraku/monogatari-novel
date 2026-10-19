import argparse
import hashlib
import logging
import os
import shutil
import signal
import sqlite3
import threading
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import orjson
from PIL import Image

from .config import Config
from .curation import sync_banners
from .media import atomic_bytes, decode_rgb, write_images
from .scan import parse_book, scan_library
from .toc import load_cached_toc, sync_toc

logger = logging.getLogger(__name__)
SCHEMA = """
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE books(
    id TEXT PRIMARY KEY, title TEXT, author TEXT, illustrator TEXT, publisher TEXT,
    status TEXT, words INTEGER, chapters INTEGER, updated TEXT, description TEXT,
    tags TEXT, volume_count INTEGER, cover_key TEXT, sort_title TEXT,
    pinyin_full TEXT, pinyin_initials TEXT, first_seen TEXT
);
CREATE TABLE volumes(book_id TEXT, n INTEGER, label TEXT, file TEXT, size INTEGER, mtime INTEGER,
    PRIMARY KEY(book_id, n));
CREATE TABLE volume_toc(book_id TEXT, n INTEGER, idx INTEGER, title TEXT, href TEXT, level INTEGER,
    PRIMARY KEY(book_id, n, idx));
CREATE INDEX books_updated ON books(updated);
CREATE INDEX books_status ON books(status);
CREATE INDEX books_words ON books(words);
"""
BOOK_COLUMNS = ("id", "title", "author", "illustrator", "publisher", "status", "words", "chapters",
                "updated", "description", "tags", "volume_count", "cover_key", "sort_title",
                "pinyin_full", "pinyin_initials", "first_seen")


def generate_cover(source: str, destination: str) -> tuple[str, int, str | None]:
    try:
        content = Path(source).read_bytes()
        key = hashlib.sha1(content).hexdigest()[:12]
        rgb = decode_rgb(content)
    except (OSError, ValueError, Image.DecompressionBombError) as exc:
        return "", 0, str(exc)
    write_images(rgb, Path(destination), key, (240, 480), 82)
    return key, 2, None


def cover_worker_init():
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, signal.SIG_IGN)


def prune_covers(directory: Path, key: str):
    if not directory.exists():
        return
    keep = {f"{key}-{width}.webp" for width in (240, 480)} if key else set()
    with os.scandir(directory) as entries:
        for entry in entries:
            if entry.name not in keep and not entry.is_dir(follow_symlinks=False):
                os.unlink(entry.path)


def remove_absent(root: Path, ids: set[str]):
    if not root.exists():
        return
    with os.scandir(root) as entries:
        for entry in entries:
            if entry.name not in ids:
                try:
                    if entry.is_dir(follow_symlinks=False):
                        shutil.rmtree(entry.path)
                    else:
                        os.unlink(entry.path)
                except OSError:
                    logger.exception("Could not remove stale output %s", entry.path)


def sync_links(config: Config, books: dict[str, dict]) -> int:
    root = config.data_dir / "files"
    failures = 0
    for book_id, book in books.items():
        directory = root / book_id
        failed = False
        try:
            directory.mkdir(parents=True, exist_ok=True)
            expected = {f"{volume['n']}.epub" for volume in book["volume_list"]}
            with os.scandir(directory) as entries:
                for entry in entries:
                    if entry.name not in expected:
                        os.unlink(entry.path)
            for volume in book["volume_list"]:
                link = directory / f"{volume['n']}.epub"
                target = str(config.files_link_root / book["directory"] / volume["file"])
                existing = os.readlink(link) if link.is_symlink() else None
                if os.name == "nt" and existing is not None:
                    if existing.startswith("\\\\?\\UNC\\"):
                        existing = "\\\\" + existing[8:]
                    else:
                        existing = existing.removeprefix("\\\\?\\")
                if existing == target:
                    continue
                temporary = link.with_name(f"{link.name}.tmp-{os.getpid()}")
                try:
                    temporary.unlink(missing_ok=True)
                    os.symlink(target, temporary)
                    os.replace(temporary, link)
                finally:
                    temporary.unlink(missing_ok=True)
        except OSError:
            failed = True
            logger.exception("File links failed for book %s", book_id)
        failures += int(failed)
    remove_absent(root, set(books))
    return failures


def write_catalog(path: Path, books: dict[str, dict]) -> dict[str, str]:
    temporary = path.with_name(f"{path.name}.tmp-{os.getpid()}")
    temporary.unlink(missing_ok=True)
    connection = sqlite3.connect(temporary)
    try:
        connection.executescript(SCHEMA)
        connection.execute("BEGIN")
        for book_id in list(books):
            book = books[book_id]
            connection.execute("SAVEPOINT book")
            try:
                values = [orjson.dumps(book[key]).decode() if key == "tags" else book[key] for key in BOOK_COLUMNS]
                connection.execute(f"INSERT INTO books VALUES ({','.join('?' for _ in BOOK_COLUMNS)})", values)
                connection.executemany("INSERT INTO volumes VALUES (?, ?, ?, ?, ?, ?)", [
                    (book_id, volume["n"], volume["label"], volume["file"], volume["size"], volume["mtime"])
                    for volume in book["volume_list"]
                ])
                connection.executemany("INSERT INTO volume_toc VALUES (?, ?, ?, ?, ?, ?)", [
                    (book_id, volume["n"], idx, entry["title"], entry["href"], entry["level"])
                    for volume in book["volume_list"] for idx, entry in enumerate(volume.get("toc", []))
                ])
            except Exception:
                connection.execute("ROLLBACK TO book")
                books.pop(book_id)
                logger.exception("Skipping book %s while writing catalog", book_id)
            finally:
                connection.execute("RELEASE book")
        now = datetime.now(timezone.utc)
        content = orjson.dumps([books[key] for key in sorted(books)], option=orjson.OPT_SORT_KEYS)
        meta = {
            "version": f"{now:%Y%m%d%H%M%S}-{hashlib.sha1(content).hexdigest()[:8]}",
            "built_at": now.isoformat(), "book_count": str(len(books)),
            "volume_count": str(sum(book["volume_count"] for book in books.values())),
        }
        connection.executemany("INSERT INTO meta VALUES (?, ?)", meta.items())
        connection.commit()
    except BaseException:
        connection.close()
        temporary.unlink(missing_ok=True)
        raise
    else:
        connection.close()
    try:
        with temporary.open("r+b") as stream:
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
    return meta


@dataclass
class BuildStats:
    elapsed: float = 0
    books: int = 0
    volumes: int = 0
    changed: int = 0
    covers: int = 0
    link_failures: int = 0
    rebuilt: bool = False


def state_without_toc(state: dict) -> dict:
    return {key: {**value, "book": {
        **value["book"], "volume_list": [
            {name: item for name, item in volume.items() if name != "toc"}
            for volume in value["book"]["volume_list"]
        ],
    }} for key, value in state.items()}


class Indexer:
    def __init__(self, config: Config):
        self.config = config
        self.first_round = True
        self.state_needs_cleanup = False

    def _state(self) -> dict:
        self.state_needs_cleanup = False
        try:
            state = orjson.loads((self.config.data_dir / "state.json").read_bytes())
            if not isinstance(state, dict) or not all(
                isinstance(value, dict) and isinstance(value.get("signature"), str)
                and isinstance(value.get("book"), dict)
                and isinstance(value["book"].get("volume_list"), list)
                and all(isinstance(volume, dict) for volume in value["book"]["volume_list"])
                for value in state.values()
            ):
                raise ValueError("Invalid state")
            for value in state.values():
                for volume in value["book"]["volume_list"]:
                    if "toc" in volume:
                        del volume["toc"]
                        self.state_needs_cleanup = True
            return state
        except FileNotFoundError:
            return {}
        except (OSError, ValueError):
            logger.warning("Could not read index state; rebuilding", exc_info=True)
            return {}

    def run_once(self, full: bool = False) -> BuildStats:
        start = time.perf_counter()
        config = self.config
        config.data_dir.mkdir(parents=True, exist_ok=True)
        state = self._state()
        today = datetime.now(timezone.utc).date().isoformat()
        missing_first_seen = {key for key, value in state.items() if "first_seen" not in value["book"]}
        schema_upgrade = False
        if self.first_round and config.catalog_path.exists():
            connection = sqlite3.connect(config.catalog_path.resolve().as_uri() + "?mode=ro", uri=True)
            try:
                schema_upgrade = "first_seen" not in {row[1] for row in connection.execute("PRAGMA table_info(books)")}
                schema_upgrade |= connection.execute(
                    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='volume_toc'").fetchone() is None
            finally:
                connection.close()
        failed = set()
        sources = scan_library(config, failed)
        changed = {key for key, source in sources.items() if state.get(key, {}).get("signature") != source.signature}
        stats = BuildStats()
        books = {}
        next_state = {}
        to_parse = set(sources) if full or not config.catalog_path.exists() else changed
        covers = {}
        for book_id, source in sources.items():
            try:
                if book_id in to_parse:
                    stats.changed += 1
                    books[book_id] = parse_book(source, config)
                    if source.cover:
                        covers[book_id] = source.cover
                else:
                    books[book_id] = state[book_id]["book"]
            except Exception:
                failed.add(book_id)
                logger.exception("Skipping book %s while parsing", book_id)
        if covers:
            with ProcessPoolExecutor(max_workers=config.cover_workers, initializer=cover_worker_init) as pool:
                futures = {pool.submit(generate_cover, str(source), str(config.data_dir / "covers" / key)): key
                           for key, source in covers.items()}
                for future in as_completed(futures):
                    book_id = futures[future]
                    try:
                        key, count, warning = future.result()
                        books[book_id]["cover_key"] = key
                        stats.covers += count
                        if warning:
                            logger.warning("Cannot decode cover for book %s: %s", book_id, warning)
                    except Exception:
                        failed.add(book_id)
                        logger.exception("Skipping book %s after cover failure", book_id)
        for book_id in failed:
            books.pop(book_id, None)
            if book_id in state:
                books[book_id] = state[book_id]["book"]
                next_state[book_id] = state[book_id]
        for book_id, book in books.items():
            book["first_seen"] = state.get(book_id, {}).get("book", {}).get("first_seen", today)
            if book_id not in failed:
                next_state[book_id] = {"signature": sources[book_id].signature, "book": book}
        toc_changed = sync_toc(config, books, {key: source for key, source in sources.items() if key not in failed})
        build_needed = (schema_upgrade or toc_changed or not config.catalog_path.exists() or set(next_state) != set(state)
                        or bool(missing_first_seen & books.keys())
                        or any(value["signature"] != state[key]["signature"]
                               for key, value in next_state.items() if key in state))
        if build_needed:
            load_cached_toc(config, books)
            write_catalog(config.catalog_path, books)
            stats.rebuilt = True
        if build_needed or self.state_needs_cleanup:
            clean_state = state_without_toc({key: next_state[key] for key in books})
            atomic_bytes(config.data_dir / "state.json", orjson.dumps(clean_state))
        if build_needed or full:
            for book_id in (to_parse & books.keys()) - failed:
                try:
                    prune_covers(config.data_dir / "covers" / book_id, books[book_id]["cover_key"])
                except OSError:
                    logger.exception("Could not remove old covers for book %s", book_id)
            remove_absent(config.data_dir / "covers", set(books))
        if build_needed or full or self.first_round:
            stats.link_failures = sync_links(config, books)
        try:
            sync_banners(config)
        except Exception:
            logger.exception("Could not synchronize banners")
        self.first_round = False
        stats.books = len(books)
        stats.volumes = sum(book["volume_count"] for book in books.values())
        stats.elapsed = time.perf_counter() - start
        logger.info("Round %s: elapsed=%.3fs books=%d volumes=%d changed=%d covers=%d link_failures=%d",
                    "built" if stats.rebuilt else "unchanged", stats.elapsed, stats.books, stats.volumes,
                    stats.changed, stats.covers, stats.link_failures)
        return stats


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--full", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    stop = threading.Event()
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, lambda *_: stop.set())
    indexer = Indexer(Config())
    full = args.full
    while True:
        try:
            indexer.run_once(full=full)
        except Exception:
            logger.exception("Index round failed")
            if args.once:
                return 1
        full = False
        if args.once or stop.wait(indexer.config.index_interval):
            return 0


if __name__ == "__main__":
    raise SystemExit(main())
