import sqlite3
import time
from collections import Counter
from datetime import date, datetime, timedelta

import pytest

from novel.catalog import Catalog
from novel.config import Config
from novel.rank import load_rankings
from novel.stats import SCHEMA, Stats
from conftest import synthetic_book


@pytest.mark.perf
def test_million_log_lines(tmp_path, pytestconfig):
    logs = tmp_path / "logs"
    logs.mkdir()
    config = Config(data_dir=tmp_path / "data", log_dir=logs)
    stamp = int(datetime(2026, 10, 17, 12, tzinfo=config.tz).timestamp())
    with (logs / "events.log").open("wb") as stream:
        for i in range(1_000_000):
            stream.write(f"{stamp + i // 1000}.{i % 1000:03d}|read:open|{i % 5101 + 1}|install-{i:08d}\n".encode())
    result = Stats(config, date_provider=lambda: "2026-10-17").run_once()
    metrics = getattr(pytestconfig, "performance_metrics", {})
    metrics["stats 1,000,000 read events / distinct readers"] = f"{result.elapsed:.6f} s (< 10 s)"
    pytestconfig.performance_metrics = metrics
    assert result.lines == result.added == 1_000_000
    connection = sqlite3.connect(config.stats_path)
    try:
        assert connection.execute("SELECT SUM(readers) FROM daily").fetchone()[0] == 1_000_000
        assert connection.execute("SELECT SUM(readers) FROM total").fetchone()[0] == 1_000_000
    finally:
        connection.close()
    assert result.elapsed < 10


@pytest.mark.perf
def test_rank_recalculation_performance(tmp_path, pytestconfig):
    config = Config(data_dir=tmp_path)
    books = {str(i): synthetic_book(i, updated=f"2026-10-{i % 28 + 1:02d}") for i in range(1, 5102)}
    catalog = Catalog(config, {"version": "rank-perf"}, books)
    today = date(2026, 10, 17)
    daily = []
    total = Counter()
    for age in range(30):
        day = (today - timedelta(days=age)).isoformat()
        for i in range(2000):
            book = str((i + age * 173) % 5101 + 1)
            readers = (i * 17 + age * 11) % 300 + 1
            daily.append((day, book, readers))
            total[book] += readers
    connection = sqlite3.connect(config.stats_path)
    try:
        connection.execute("PRAGMA journal_mode=DELETE")
        connection.executescript(SCHEMA)
        connection.executemany("INSERT INTO daily VALUES (?, ?, ?)", daily)
        connection.executemany("INSERT INTO total VALUES (?, ?)", total.items())
        connection.execute("INSERT INTO meta VALUES ('stats_version', '1')")
        connection.commit()
    finally:
        connection.close()
    start = time.perf_counter()
    rankings = load_rankings(config, catalog, str(today))
    elapsed = time.perf_counter() - start
    metrics = getattr(pytestconfig, "performance_metrics", {})
    metrics["rank recalculation, 5101 books / 30 days x 2000 books"] = f"{elapsed:.6f} s (< 1 s)"
    pytestconfig.performance_metrics = metrics
    assert len(daily) == 60_000
    assert all(len(items) == 100 and items[0]["readers"] > 0 for items in rankings.items.values())
    assert elapsed < 1
