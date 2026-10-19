import argparse
import hashlib
import logging
import math
import os
import re
import secrets
import signal
import sqlite3
import threading
import time
from collections import Counter
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from functools import lru_cache

from .config import Config

logger = logging.getLogger(__name__)
URI = re.compile(r"/files/(\d{1,10})/(\d{1,4})\.epub")
BOOK_ID = re.compile(r"\d{1,10}")
INSTALL = re.compile(rb"[A-Za-z0-9-]{8,64}")
SCHEMA = """
CREATE TABLE IF NOT EXISTS cursor(id INTEGER PRIMARY KEY CHECK(id IN (1,2)), inode INTEGER, offset INTEGER);
CREATE TABLE IF NOT EXISTS salt(day TEXT PRIMARY KEY, salt TEXT);
CREATE TABLE IF NOT EXISTS seen(day TEXT, book_id TEXT, reader TEXT, PRIMARY KEY(day, book_id, reader)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS daily(day TEXT, book_id TEXT, readers INTEGER, PRIMARY KEY(day, book_id)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS total(book_id TEXT PRIMARY KEY, readers INTEGER) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS shelf(installer TEXT, book_id TEXT, PRIMARY KEY(installer, book_id)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS shelf_total(book_id TEXT PRIMARY KEY, count INTEGER) WITHOUT ROWID;
"""


def migrate_cursor(connection):
    sql = connection.execute("SELECT sql FROM sqlite_master WHERE name='cursor' AND type='table'").fetchone()[0]
    if "check(id=1)" in re.sub(r"\s+", "", sql).lower():
        connection.execute("CREATE TABLE cursor_new(id INTEGER PRIMARY KEY CHECK(id IN (1,2)), inode INTEGER, offset INTEGER)")
        connection.execute("INSERT INTO cursor_new SELECT id, inode, offset FROM cursor")
        connection.execute("DROP TABLE cursor")
        connection.execute("ALTER TABLE cursor_new RENAME TO cursor")


def consume_log(connection, directory, name, cursor_id, consume):
    previous = connection.execute("SELECT inode, offset FROM cursor WHERE id=?", (cursor_id,)).fetchone()
    try:
        current = (directory / name).open("rb")
    except FileNotFoundError:
        logger.warning("Log is missing: %s", name)
        return
    with current:
        info = os.fstat(current.fileno())
        offset = 0
        if previous:
            inode, offset = previous
            if inode != info.st_ino:
                try:
                    rotated = (directory / (name + ".1")).open("rb")
                except FileNotFoundError:
                    rotated = None
                if rotated is not None:
                    with rotated:
                        if os.fstat(rotated.fileno()).st_ino == inode:
                            consume(rotated, offset)
                offset = 0
            elif info.st_size < offset:
                offset = 0
        offset = consume(current, offset)
        connection.execute("INSERT INTO cursor VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET "
                           "inode=excluded.inode, offset=excluded.offset", (cursor_id, info.st_ino, offset))


def increment_version(connection):
    row = connection.execute("SELECT value FROM meta WHERE key='stats_version'").fetchone()
    version = str(int(row[0]) + 1) if row else "1"
    connection.execute("INSERT INTO meta VALUES ('stats_version', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                       (version,))


@dataclass
class StatsResult:
    lines: int = 0
    added: int = 0
    shelf_changes: int = 0
    elapsed: float = 0


class Stats:
    def __init__(self, config: Config, date_provider=None):
        self.config = config
        self.date_provider = date_provider or (lambda: datetime.now(config.tz).date().isoformat())

    def run_once(self) -> StatsResult:
        start = time.perf_counter()
        self.config.data_dir.mkdir(parents=True, exist_ok=True)
        result = StatsResult()
        connection = sqlite3.connect(self.config.stats_path)
        try:
            connection.execute("PRAGMA journal_mode=DELETE")
            connection.execute("PRAGMA cache_size=-32768")
            connection.executescript(SCHEMA)
            connection.execute("BEGIN IMMEDIATE")
            migrate_cursor(connection)
            salts = {day: salt.encode("ascii") for day, salt in connection.execute("SELECT day, salt FROM salt")}
            daily = Counter()
            total = Counter()
            recent = set()
            tz = self.config.tz
            seen_cursor = connection.cursor()

            @lru_cache(maxsize=4096)
            def log_day(second):
                return datetime.fromtimestamp(second, tz).date().isoformat()

            def consume(stream, offset):
                stream.seek(offset)
                for line in stream:
                    if not line.endswith(b"\n"):
                        break
                    offset += len(line)
                    result.lines += 1
                    fields = line[:-1].split(b"|")
                    if len(fields) != 4 or fields[3] not in (b"200", b"206"):
                        continue
                    try:
                        match = URI.fullmatch(fields[2].decode("utf-8"))
                    except UnicodeError:
                        continue
                    if match is None:
                        continue
                    try:
                        day = log_day(math.floor(float(fields[0])))
                    except (ValueError, OverflowError, OSError, UnicodeError):
                        continue
                    book_id = match[1]
                    salt = salts.get(day)
                    if salt is None:
                        value = secrets.token_hex(16)
                        connection.execute("INSERT INTO salt VALUES (?, ?)", (day, value))
                        salt = value.encode("ascii")
                        salts[day] = salt
                    reader = hashlib.sha1(salt + fields[1]).hexdigest()[:16]
                    key = day, book_id, reader
                    if key in recent:
                        continue
                    if len(recent) >= 8192:
                        recent.clear()
                    recent.add(key)
                    seen_cursor.execute("INSERT OR IGNORE INTO seen VALUES (?, ?, ?)", key)
                    if seen_cursor.rowcount == 1:
                        daily[day, book_id] += 1
                        total[book_id] += 1
                        result.added += 1
                return offset

            consume_log(connection, self.config.log_dir, "files.log", 1, consume)
            shelf_totals = dict(connection.execute("SELECT book_id, count FROM shelf_total"))
            changed_shelves = set()
            shelf_cursor = connection.cursor()
            salt_row = connection.execute("SELECT value FROM meta WHERE key='install_salt'").fetchone()
            install_salt = salt_row[0].encode("ascii") if salt_row else None

            @lru_cache(maxsize=8192)
            def installer_hash(install):
                nonlocal install_salt
                if install_salt is None:
                    value = secrets.token_hex(16)
                    connection.execute("INSERT INTO meta VALUES ('install_salt', ?)", (value,))
                    install_salt = value.encode("ascii")
                return hashlib.sha1(install_salt + install).hexdigest()[:16]

            def consume_events(stream, offset):
                stream.seek(offset)
                for line in stream:
                    if not line.endswith(b"\n"):
                        break
                    offset += len(line)
                    result.lines += 1
                    fields = line[:-1].split(b"|")
                    if (len(fields) != 4 or fields[1] not in (b"shelf:add", b"shelf:remove")
                            or INSTALL.fullmatch(fields[3]) is None):
                        continue
                    try:
                        book_id = fields[2].decode("utf-8")
                    except UnicodeError:
                        continue
                    if BOOK_ID.fullmatch(book_id) is None:
                        continue
                    key = installer_hash(fields[3]), book_id
                    adding = fields[1] == b"shelf:add"
                    if adding:
                        shelf_cursor.execute("INSERT OR IGNORE INTO shelf VALUES (?, ?)", key)
                    else:
                        shelf_cursor.execute("DELETE FROM shelf WHERE installer=? AND book_id=?", key)
                    if shelf_cursor.rowcount:
                        shelf_totals[book_id] = max(0, shelf_totals.get(book_id, 0) + (1 if adding else -1))
                        changed_shelves.add(book_id)
                        result.shelf_changes += 1
                return offset

            consume_log(connection, self.config.log_dir, "events.log", 2, consume_events)
            connection.executemany(
                "INSERT INTO shelf_total VALUES (?, ?) ON CONFLICT(book_id) DO UPDATE SET count=excluded.count",
                [(book_id, shelf_totals[book_id]) for book_id in changed_shelves],
            )
            connection.executemany(
                "INSERT INTO daily VALUES (?, ?, ?) ON CONFLICT(day, book_id) DO UPDATE SET readers=readers+excluded.readers",
                [(day, book_id, readers) for (day, book_id), readers in daily.items()],
            )
            connection.executemany(
                "INSERT INTO total VALUES (?, ?) ON CONFLICT(book_id) DO UPDATE SET readers=readers+excluded.readers",
                total.items(),
            )
            cutoff = (date.fromisoformat(self.date_provider()) - timedelta(days=35)).isoformat()
            for table in ("seen", "salt", "daily"):
                connection.execute(f"DELETE FROM {table} WHERE day < ?", (cutoff,))
            if result.added or result.shelf_changes:
                increment_version(connection)
            connection.commit()
        except BaseException:
            connection.rollback()
            raise
        finally:
            connection.close()
        result.elapsed = time.perf_counter() - start
        logger.info("Stats round: elapsed=%.3fs lines=%d added=%d shelf_changes=%d",
                    result.elapsed, result.lines, result.added, result.shelf_changes)
        return result


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    stop = threading.Event()
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, lambda *_: stop.set())
    stats = Stats(Config())
    while True:
        try:
            stats.run_once()
        except Exception:
            logger.exception("Stats round failed")
            if args.once:
                return 1
        if args.once or stop.wait(stats.config.stats_interval):
            return 0


if __name__ == "__main__":
    raise SystemExit(main())
