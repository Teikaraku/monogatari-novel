import sqlite3
import time
from collections import Counter
from contextlib import closing
from datetime import date, timedelta

import pytest

from novel.catalog import Catalog
from novel.config import Config
from novel.rank import BOARDS, load_rankings
from novel.stats import SCHEMA, Stats
from conftest import synthetic_book


@pytest.mark.perf
def test_million_shelf_events(tmp_path, pytestconfig):
    logs = tmp_path / "logs"
    logs.mkdir()
    config = Config(data_dir=tmp_path / "data", log_dir=logs)
    with (logs / "events.log").open("wb") as stream:
        for i in range(1_000_000):
            stream.write(f"1729123456.789|shelf:add|{i % 5101 + 1}|install-{i:08d}\n".encode())
    result = Stats(config, date_provider=lambda: "2026-10-17").run_once()
    metrics = getattr(pytestconfig, "performance_metrics", {})
    metrics["events 1,000,000 valid lines / distinct installs"] = f"{result.elapsed:.6f} s (< 10 s)"
    pytestconfig.performance_metrics = metrics
    assert result.lines == result.shelf_changes == 1_000_000 and result.added == 0
    with closing(sqlite3.connect(config.stats_path)) as connection:
        assert connection.execute("SELECT COUNT(*) FROM shelf").fetchone()[0] == 1_000_000
        assert connection.execute("SELECT SUM(count) FROM shelf_total").fetchone()[0] == 1_000_000
        assert connection.execute("SELECT value FROM meta WHERE key='stats_version'").fetchone()[0] == "1"
    assert result.elapsed < 10


@pytest.mark.perf
def test_all_boards_recalculation_performance(tmp_path, pytestconfig):
    config = Config(data_dir=tmp_path)
    today = date(2026, 10, 17)
    books = {str(i): synthetic_book(i, updated=f"2026-10-{i % 28 + 1:02d}",
                                   first_seen=f"2026-10-{i % 17 + 1:02d}",
                                   status="completed" if i % 2 else "ongoing", words=i * 100,
                                   volume_count=i % 50 + 1) for i in range(1, 5102)}
    catalog = Catalog(config, {"version": "all-boards-perf"}, books)
    daily, totals = [], Counter()
    for age in range(30):
        day = (today - timedelta(days=age)).isoformat()
        for i in range(1, 5102):
            readers = (i * 17 + (30 - age) * 11) % 300 + 1
            daily.append((day, str(i), readers))
            totals[str(i)] += readers
    shelves = [(f"{i:016x}", str(i % 5101 + 1)) for i in range(50_000)]
    with closing(sqlite3.connect(config.stats_path)) as connection:
        connection.executescript(SCHEMA)
        connection.executemany("INSERT INTO daily VALUES (?, ?, ?)", daily)
        connection.executemany("INSERT INTO total VALUES (?, ?)", totals.items())
        connection.executemany("INSERT INTO shelf VALUES (?, ?)", shelves)
        connection.executemany("INSERT INTO shelf_total VALUES (?, ?)", Counter(book for _, book in shelves).items())
        connection.execute("INSERT INTO meta VALUES ('stats_version', '1')")
        connection.commit()
    start = time.perf_counter()
    rankings = load_rankings(config, catalog, str(today))
    elapsed = time.perf_counter() - start
    metrics = getattr(pytestconfig, "performance_metrics", {})
    metrics["all boards, 5101 books x 30 days / 50,000 shelf records"] = f"{elapsed:.6f} s (< 1 s)"
    pytestconfig.performance_metrics = metrics
    assert len(daily) == 153_030 and len(shelves) == 50_000
    assert {board for board, _ in rankings.boards} == set(BOARDS)
    assert all(len(items) == 100 for items in rankings.boards.values())
    assert all(items[0]["score"] > 0 for (board, _), items in rankings.boards.items() if board != "new")
    assert elapsed < 1
