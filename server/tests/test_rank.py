import hashlib
import sqlite3
import threading
from contextlib import closing
from datetime import date, timedelta

import pytest
from fastapi.testclient import TestClient

from novel.api import create_app
from novel.catalog import Catalog
from novel.config import Config
from novel.indexer import write_catalog
from novel.rank import load_rankings
from novel.stats import SCHEMA
from conftest import synthetic_book


def write_stats(config, daily=(), totals=(), version="1"):
    with closing(sqlite3.connect(config.stats_path)) as connection:
        connection.execute("PRAGMA journal_mode=DELETE")
        connection.executescript(SCHEMA)
        connection.executemany("INSERT OR REPLACE INTO daily VALUES (?, ?, ?)", daily)
        connection.executemany("INSERT OR REPLACE INTO total VALUES (?, ?)", totals)
        connection.execute("INSERT OR REPLACE INTO meta VALUES ('stats_version', ?)", (version,))
        connection.commit()


def test_rank_window_boundaries_and_missing_ids(tmp_path):
    config = Config(data_dir=tmp_path)
    books = {str(i): synthetic_book(i, cover_key="") for i in range(1, 9)}
    catalog = Catalog(config, {}, books)
    today = date(2026, 10, 17)
    ages = (0, 1, 6, 7, 29, 30, -1)
    daily = [((today - timedelta(days=age)).isoformat(), str(i), i) for i, age in enumerate(ages, 1)]
    daily.append((str(today), "999", 1000))
    write_stats(config, daily, [(str(i), i) for i in range(1, 9)] + [("999", 1000)])
    ranks = load_rankings(config, catalog, str(today))
    expected = {"day": ["1"], "week": ["3", "2", "1"], "month": ["5", "4", "3", "2", "1"],
                "total": [str(i) for i in range(8, 0, -1)]}
    for period, ids in expected.items():
        assert [item["id"] for item in ranks.items[period]] == ids
        assert all(item["readers"] == int(item["id"]) for item in ranks.items[period])


def test_rank_ties_return_only_positive_scores(tmp_path):
    config = Config(data_dir=tmp_path)
    books = {str(i): synthetic_book(i, words=999999 - i) for i in range(1, 151)}
    books["1"]["updated"] = "2025-01-01"
    books["2"]["updated"] = "2025-01-01"
    books["3"]["cover_key"] = ""
    books["4"]["volume_count"] = 8
    books["5"]["volume_count"] = 8
    books["5"]["updated"] = "2025-01-01"
    catalog = Catalog(config, {}, books)
    write_stats(config, [("2026-10-17", str(i), 10) for i in (1, 2, 3)], [(str(i), 10) for i in (1, 2, 3)])
    rankings = load_rankings(config, catalog, "2026-10-17")
    for period in rankings.items:
        items = rankings.items[period]
        assert [item["id"] for item in items] == ["2", "1", "3"]
        assert [item["readers"] for item in items] == [10, 10, 10]


def test_missing_stats_returns_empty_rank_and_keeps_empty_home_section(tmp_path):
    config = Config(data_dir=tmp_path)
    books = {"1": synthetic_book(1), "2": synthetic_book(2, cover_key=""), "3": synthetic_book(3)}
    write_catalog(config.catalog_path, books)
    with TestClient(create_app(config)) as client:
        for period in ("day", "week", "month", "total"):
            data = client.get("/api/v1/rank", params={"period": period}).json()
            assert data["period"] == period and data["total"] == 0
            assert data["items"] == []
        assert client.get("/api/v1/home").json()["sections"][2] == {"key": "rank", "items": []}
        assert not config.stats_path.exists()


def test_stats_version_reload_and_response_cache(tmp_path):
    config = Config(data_dir=tmp_path, rank_reload_seconds=0)
    books = {"1": synthetic_book(1), "2": synthetic_book(2), "3": synthetic_book(3)}
    write_catalog(config.catalog_path, books)
    write_stats(config, [("2026-10-17", "1", 1)], [("1", 1)])
    with TestClient(create_app(config, date_provider=lambda: "2026-10-17")) as client:
        before = client.get("/api/v1/rank?period=week")
        meta = client.get("/api/v1/meta").json()
        assert meta["content_version"].endswith(".1")
        assert before.json()["items"][0]["id"] == "1"
        write_stats(config, [("2026-10-17", "2", 20)], [("2", 20)], version="2")
        client.get("/api/v1/rank?period=week")
        client.app.state.rank_store.future.result(timeout=5)
        after = client.get("/api/v1/rank?period=week", headers={"If-None-Match": before.headers["etag"]})
        assert after.status_code == 200 and after.json()["items"][0]["id"] == "2"
        assert after.json()["items"][0]["readers"] == 20
        assert after.headers["etag"] != before.headers["etag"]
        new_meta = client.get("/api/v1/meta").json()
        assert new_meta["version"] == meta["version"]
        assert new_meta["content_version"].endswith(".2")
        home = client.get("/api/v1/home").json()
        assert home["sections"][2]["items"] == [
            {key: value for key, value in item.items() if key != "score"} for item in after.json()["items"][:10]]
        assert client.get("/api/v1/rank?period=week&offset=99").json()["items"] == []
        assert client.get("/api/v1/rank?period=week&offset=1&limit=1").json()["items"] == after.json()["items"][1:2]


def test_home_rank_contains_at_most_ten_real_weekly_entries(tmp_path):
    config = Config(data_dir=tmp_path)
    write_catalog(config.catalog_path, {str(i): synthetic_book(i) for i in range(1, 31)})
    write_stats(config, [("2026-10-17", str(i), i) for i in range(1, 13)])
    with TestClient(create_app(config, date_provider=lambda: "2026-10-17")) as client:
        rank = client.get("/api/v1/rank?period=week").json()
        home = client.get("/api/v1/home").json()["sections"][2]
        assert rank["total"] == 12 and len(home["items"]) == 10
        assert [item["id"] for item in home["items"]] == [str(i) for i in range(12, 2, -1)]
        assert all(item["readers"] > 0 for item in home["items"])


def test_rank_reload_failure_keeps_previous(tmp_path, monkeypatch, caplog):
    from novel import rank
    config = Config(data_dir=tmp_path, rank_reload_seconds=0)
    write_catalog(config.catalog_path, {"1": synthetic_book(1)})
    write_stats(config, [("2026-10-17", "1", 2)])
    with TestClient(create_app(config, date_provider=lambda: "2026-10-17")) as client:
        before = client.get("/api/v1/rank?period=day").json()
        write_stats(config, version="2")

        def fail(*args):
            raise RuntimeError("test failure")

        monkeypatch.setattr(rank, "load_rankings", fail)
        client.get("/api/v1/rank?period=day")
        client.app.state.rank_store.future.result(timeout=5)
        assert client.get("/api/v1/rank?period=day").json() == before
        assert "Could not reload rankings" in caplog.text


def test_date_rollover_recalculates_without_version_change(tmp_path, monkeypatch):
    from novel import rank
    config = Config(data_dir=tmp_path, rank_reload_seconds=0)
    write_catalog(config.catalog_path, {str(i): synthetic_book(i) for i in range(1, 5)})
    write_stats(config, [("2026-10-17", "1", 7), ("2026-10-11", "2", 30),
                         ("2026-09-18", "3", 50), ("2026-10-18", "4", 2)],
                [("1", 7), ("2", 30), ("3", 50), ("4", 2)])
    release = threading.Event()
    original = rank.load_rankings

    def delayed(*args):
        assert release.wait(5)
        return original(*args)

    with TestClient(create_app(config, date_provider=lambda: "2026-10-17")) as client:
        before = {period: client.get(f"/api/v1/rank?period={period}") for period in rank.PERIODS}
        home = client.get("/api/v1/home")
        version = client.get("/api/v1/meta").json()["content_version"]
        store = client.app.state.rank_store
        assert store.rankings.date == "2026-10-17" and store.rankings.version == "1"
        monkeypatch.setattr(rank, "load_rankings", delayed)
        client.app.state.date_provider = lambda: "2026-10-18"
        try:
            pending = client.get("/api/v1/rank?period=week")
            assert pending.json() == before["week"].json()
            client.get("/api/v1/home")
            assert store.rankings.date == "2026-10-17"
        finally:
            release.set()
        store.future.result(timeout=5)
        assert store.rankings.date == "2026-10-18" and store.rankings.version == "1"
        expected = {"day": {"4": 2}, "week": {"1": 7, "4": 2},
                    "month": {"1": 7, "2": 30, "4": 2}, "total": {"1": 7, "2": 30, "3": 50, "4": 2}}
        for period in rank.PERIODS:
            url = f"/api/v1/rank?period={period}"
            response = client.get(url, headers={"If-None-Match": before[period].headers["etag"]})
            assert response.status_code == 200
            assert {item["id"]: item["readers"] for item in response.json()["items"] if item["readers"]} == expected[period]
            normalized = url + "#2026-10-18"
            digest = hashlib.sha1(normalized.encode()).hexdigest()[:16]
            assert response.headers["etag"] == f'W/"{version}-{digest}"'
            assert client.app.state.responses.get((version, normalized)) == response.content
            assert client.get(url, headers={"If-None-Match": response.headers["etag"]}).status_code == 304
        after_home = client.get("/api/v1/home", headers={"If-None-Match": home.headers["etag"]})
        assert after_home.status_code == 200
        assert {item["id"]: item["readers"] for item in after_home.json()["sections"][2]["items"]
                if item["readers"]} == expected["week"]
        assert client.get("/api/v1/meta").json()["content_version"] == version


def test_date_reload_respects_check_interval_and_retries_after_failure(tmp_path, monkeypatch):
    from types import SimpleNamespace
    from novel import rank
    config = Config(data_dir=tmp_path, rank_reload_seconds=300)
    catalog = Catalog(config, {}, {"1": synthetic_book(1)})
    write_stats(config, [("2026-10-17", "1", 1)])
    clock = [100.0]
    today = ["2026-10-17"]
    monkeypatch.setattr(rank, "time", SimpleNamespace(monotonic=lambda: clock[0]))
    store = rank.RankStore(config, catalog, lambda: today[0])
    try:
        today[0] = "2026-10-18"
        clock[0] = 399
        assert store.snapshot(catalog).date == "2026-10-17"
        assert store.future is None
        original = rank.load_rankings

        def fail(*args):
            raise OSError("temporary read failure")

        monkeypatch.setattr(rank, "load_rankings", fail)
        clock[0] = 400
        store.snapshot(catalog)
        store.future.result(timeout=5)
        assert store.rankings.date == "2026-10-17"
        monkeypatch.setattr(rank, "load_rankings", original)
        clock[0] = 700
        store.snapshot(catalog)
        store.future.result(timeout=5)
        assert store.rankings.date == "2026-10-18" and store.rankings.version == "1"
        assert store.rankings.items["day"] == []
        previous = store.future
        clock[0] = 1000
        store.snapshot(catalog)
        assert store.future is previous
    finally:
        store.close()
