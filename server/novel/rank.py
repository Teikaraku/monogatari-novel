import logging
import sqlite3
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import date, timedelta

from .config import Config

logger = logging.getLogger(__name__)
PERIODS = ("day", "week", "month", "total")
BOARDS = ("popular", "shelf", "rising", "completed", "words", "volumes", "new")


class Rankings:
    def __init__(self, catalog, version: str, counts: dict[str, dict[str, int]], today: str,
                 *, shelf_counts=None, previous_week=None):
        self.catalog = catalog
        self.version = version
        self.counts = counts
        self.date = today
        self.shelf_counts = shelf_counts or {}
        self.previous_week = previous_week or {}
        # Home retains its existing BookSummary + readers response shape.
        self.items = {}
        self.boards = {}

        def scored_items(ids, scores, *, readers=False):
            result = []
            for key in ids[:100]:
                score = scores.get(key, 0)
                item = {**catalog.summaries[key], "score": score}
                if readers:
                    item["readers"] = score
                result.append(item)
            return result

        updated = catalog.sorted_ids["updated"]
        for period in PERIODS:
            readers = counts.get(period, {})
            ids = [key for key, count in readers.items() if count > 0 and key in catalog.books]
            ids.sort(key=lambda key: (readers[key], catalog.books[key]["updated"], int(key)), reverse=True)
            items = scored_items(ids, readers, readers=True)
            self.boards["popular", period] = items
            self.items[period] = [{key: value for key, value in item.items() if key != "score"} for item in items]
            completed = [key for key in ids if catalog.books[key]["status"] == "completed"]
            self.boards["completed", period] = scored_items(completed, readers, readers=True)
        shelf = sorted((key for key in updated if self.shelf_counts.get(key, 0) > 0),
                       key=lambda key: self.shelf_counts[key], reverse=True)
        self.boards["shelf", None] = scored_items(shelf, self.shelf_counts)
        week = counts.get("week", {})
        growth = {key: count - self.previous_week.get(key, 0) for key, count in week.items()}
        rising = sorted((key for key in updated if growth.get(key, 0) > 0),
                        key=lambda key: (growth[key], week[key], catalog.books[key]["updated"]), reverse=True)
        self.boards["rising", None] = scored_items(rising, growth)
        for board, field in (("words", "words"), ("volumes", "volume_count")):
            ids = catalog.sorted_ids[board][:100]
            self.boards[board, None] = scored_items(ids, {key: catalog.books[key][field] for key in ids})
        newest = sorted(updated, key=lambda key: catalog.books[key].get("first_seen") or "", reverse=True)
        self.boards["new", None] = scored_items(newest, {})

    def with_catalog(self, catalog):
        return Rankings(catalog, self.version, self.counts, self.date,
                        shelf_counts=self.shelf_counts, previous_week=self.previous_week)

    def listing(self, period: str | None, offset=0, limit=30, *, board="popular"):
        items = self.boards[board, period]
        return {"period": period, "board": board,
                "total": len(items), "offset": offset, "limit": limit,
                "items": items[offset:offset + limit]}


def load_rankings(config: Config, catalog, today: str) -> Rankings:
    if not config.stats_path.exists():
        return Rankings(catalog, "", {}, today)
    connection = sqlite3.connect(config.stats_path.resolve().as_uri() + "?mode=ro", uri=True)
    try:
        connection.execute("BEGIN")
        row = connection.execute("SELECT value FROM meta WHERE key='stats_version'").fetchone()
        version = row[0] if row else ""
        end = date.fromisoformat(today)
        lower = (end - timedelta(days=29)).isoformat()
        week = (end - timedelta(days=6)).isoformat()
        previous_week_start = (end - timedelta(days=13)).isoformat()
        counts = {period: {} for period in PERIODS}
        previous_week = {}
        for day, book_id, readers in connection.execute("SELECT day, book_id, readers FROM daily WHERE day >= ? AND day <= ?", (lower, today)):
            for period in (("month", "week", "day") if day == today else ("month", "week") if day >= week else ("month",)):
                counts[period][book_id] = counts[period].get(book_id, 0) + readers
            if previous_week_start <= day < week:
                previous_week[book_id] = previous_week.get(book_id, 0) + readers
        counts["total"] = dict(connection.execute("SELECT book_id, readers FROM total"))
        has_shelf = connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='shelf_total'").fetchone()
        shelf_counts = dict(connection.execute("SELECT book_id, count FROM shelf_total")) if has_shelf else {}
    finally:
        connection.close()
    return Rankings(catalog, version, counts, today, shelf_counts=shelf_counts, previous_week=previous_week)


class RankStore:
    def __init__(self, config: Config, catalog, date_provider):
        self.config = config
        self.date_provider = date_provider
        today = date_provider()
        self.rankings = Rankings(catalog, "", {}, today)
        self.last_check = time.monotonic()
        self.lock = threading.Lock()
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="rank-reload")
        self.future = None
        try:
            self.rankings = load_rankings(config, catalog, today)
        except Exception:
            logger.exception("Could not load rankings at startup")

    def _reload(self, catalog, today):
        try:
            rankings = load_rankings(self.config, catalog, today)
            with self.lock:
                if catalog is not self.rankings.catalog:
                    rankings = rankings.with_catalog(self.rankings.catalog)
                self.rankings = rankings
        except Exception:
            logger.exception("Could not reload rankings; keeping previous data")

    def snapshot(self, catalog, today=None):
        now = time.monotonic()
        today = today or self.date_provider()
        with self.lock:
            busy = self.future is not None and not self.future.done()
            if catalog is not self.rankings.catalog:
                self.rankings = self.rankings.with_catalog(catalog)
            if now - self.last_check >= self.config.rank_reload_seconds and not busy:
                self.last_check = now
                try:
                    version = ""
                    if self.config.stats_path.exists():
                        connection = sqlite3.connect(self.config.stats_path.resolve().as_uri() + "?mode=ro", uri=True)
                        try:
                            row = connection.execute("SELECT value FROM meta WHERE key='stats_version'").fetchone()
                            version = row[0] if row else ""
                        finally:
                            connection.close()
                    if version != self.rankings.version or today != self.rankings.date:
                        self.future = self.executor.submit(self._reload, catalog, today)
                except Exception:
                    logger.exception("Could not check stats version")
            return self.rankings

    def close(self):
        self.executor.shutdown(wait=True)
