import hashlib
import sqlite3
import threading
from contextlib import closing

import pytest
from fastapi.testclient import TestClient

from novel.api import create_app
from novel.catalog import Catalog
from novel.config import Config
from novel.indexer import write_catalog
from novel.rank import BOARDS, PERIODS, RankStore, load_rankings
from conftest import synthetic_book
from test_events import event
from test_rank import write_stats
from novel.stats import Stats


@pytest.fixture
def boards_config(tmp_path):
    config = Config(data_dir=tmp_path, rank_reload_seconds=0)
    definitions = [
        (1, "completed", "2026-10-11", 500, 6, "2026-10-01", True),
        (2, "ongoing", "2026-10-11", 1000, 4, "2026-10-12", True),
        (3, "completed", "2026-10-13", 500, 6, "2026-10-12", True),
        (4, "completed", "2026-10-12", 2000, 20, "2026-10-14", False),
        (5, "ongoing", "2026-10-09", 0, 3, "2026-10-12", True),
        (6, "completed", "2026-10-08", 1000, 5, "2026-10-14", True),
        (7, "completed", "2026-10-11", 500, 6, "2026-10-12", True),
        (8, "ongoing", "2026-10-15", 0, 2, "2026-10-15", False),
    ]
    books = {str(i): synthetic_book(i, status=status, updated=updated, words=words,
                                   volume_count=volumes, first_seen=first_seen, cover_key="hash" if cover else "")
             for i, status, updated, words, volumes, first_seen, cover in definitions}
    write_catalog(config.catalog_path, books)
    write_stats(config, [
        ("2026-10-17", "1", 10), ("2026-10-04", "1", 2), ("2026-10-10", "1", 3),
        ("2026-10-11", "2", 12), ("2026-10-10", "2", 7),
        ("2026-10-17", "3", 12), ("2026-10-09", "3", 7),
        ("2026-10-17", "4", 3), ("2026-10-10", "5", 9),
        ("2026-10-16", "6", 8), ("2026-10-03", "6", 1000),
        ("2026-10-17", "7", 5), ("2026-10-10", "7", 5),
        ("2026-10-18", "8", 1000), ("2026-10-17", "999", 10000),
    ], [("1", 20), ("2", 100), ("3", 20), ("4", 5), ("999", 10000)])
    with closing(sqlite3.connect(config.stats_path)) as connection:
        connection.executemany("INSERT INTO shelf_total VALUES (?, ?)",
                               [("1", 5), ("2", 5), ("3", 5), ("4", 9), ("5", 0), ("999", 20)])
        connection.commit()
    return config


@pytest.mark.parametrize(("board", "period", "ids", "scores"), [
    ("popular", "week", [3, 2, 1, 6, 7, 4], [12, 12, 10, 8, 5, 3]),
    ("shelf", None, [4, 3, 2, 1], [9, 5, 5, 5]),
    ("rising", None, [6, 3, 2, 1, 4], [8, 5, 5, 5, 3]),
    ("completed", "week", [3, 1, 6, 7, 4], [12, 10, 8, 5, 3]),
    ("completed", "total", [3, 1, 4], [20, 20, 5]),
    ("words", None, [4, 2, 6, 3, 7, 1, 8, 5], [2000, 1000, 1000, 500, 500, 500, 0, 0]),
    ("volumes", None, [4, 3, 7, 1, 6, 2, 5, 8], [20, 6, 6, 6, 5, 4, 3, 2]),
    ("new", None, [8, 4, 6, 3, 7, 2, 5, 1], [0] * 8),
])
def test_board_order_scores_without_padding(boards_config, board, period, ids, scores):
    with TestClient(create_app(boards_config, date_provider=lambda: "2026-10-17")) as client:
        params = {"board": board, **({"period": period} if period else {})}
        response = client.get("/api/v1/rank", params=params)
        assert response.status_code == 200
        data = response.json()
        assert set(data) == {"board", "period", "total", "offset", "limit", "items"}
        assert data["board"] == board and data["period"] == period and data["total"] == len(ids)
        assert [item["id"] for item in data["items"]] == [str(i) for i in ids]
        assert [item["score"] for item in data["items"]] == scores
        summary_fields = set(client.get("/api/v1/books/1").json()) - {
            "illustrator", "publisher", "description", "chapters", "tv", "volume_list"}
        for item in data["items"]:
            assert type(item["score"]) is int
            assert set(item) == summary_fields | {"score"} | ({"readers"} if board in ("popular", "completed") else set())
            if board in ("popular", "completed"):
                assert item["readers"] == item["score"]
        assert client.get("/api/v1/rank", params={**params, "offset": 1, "limit": 2}).json()["items"] == data["items"][1:3]
        assert client.get("/api/v1/rank", params={**params, "offset": 100}).json()["items"] == []
        assert client.get("/api/v1/rank", params=params, headers={"If-None-Match": response.headers["etag"]}).status_code == 304
        if board in ("words", "volumes"):
            assert [item["id"] for item in client.get("/api/v1/books", params={"sort": board}).json()["items"]] == [str(i) for i in ids]


@pytest.mark.parametrize("board", [None, "popular", "completed"])
@pytest.mark.parametrize("period", [None, "", "bad"])
def test_readership_boards_require_valid_period(boards_config, board, period):
    params = {key: value for key, value in (("board", board), ("period", period)) if value is not None}
    with TestClient(create_app(boards_config)) as client:
        response = client.get("/api/v1/rank", params=params)
        assert response.status_code == 400 and response.headers["cache-control"] == "no-store"
        assert "etag" not in response.headers


@pytest.mark.parametrize("board", ["shelf", "rising", "words", "volumes", "new"])
def test_non_period_boards_ignore_period(boards_config, board):
    with TestClient(create_app(boards_config, date_provider=lambda: "2026-10-17")) as client:
        expected = client.get("/api/v1/rank", params={"board": board}).json()
        assert expected["period"] is None
        for period in ("", "invalid", "day", "week", "month", "total"):
            response = client.get("/api/v1/rank", params={"board": board, "period": period})
            assert response.status_code == 200 and response.json() == expected


@pytest.mark.parametrize("board", ["", "Popular", "unknown"])
def test_invalid_board_is_not_cached(boards_config, board):
    with TestClient(create_app(boards_config)) as client:
        response = client.get("/api/v1/rank", params={"board": board, "period": "week"})
        assert response.status_code == 400 and response.headers["cache-control"] == "no-store"
        assert "etag" not in response.headers


@pytest.mark.parametrize("period", PERIODS)
def test_default_board_equals_popular_and_preserves_legacy_fields(boards_config, period):
    with TestClient(create_app(boards_config, date_provider=lambda: "2026-10-17")) as client:
        legacy = client.get("/api/v1/rank", params={"period": period}).json()
        explicit = client.get("/api/v1/rank", params={"period": period, "board": "popular"}).json()
        assert legacy == explicit and legacy["board"] == "popular"
        assert all(item["score"] == item["readers"] for item in legacy["items"])
        original_items = client.app.state.rank_store.rankings.items[period]
        assert [{key: value for key, value in item.items() if key != "score"} for item in legacy["items"]] == original_items
        home_items = client.get("/api/v1/home").json()["sections"][2]["items"]
        assert all("score" not in item for item in home_items)


def test_all_boards_limit_100_and_no_padding(tmp_path):
    config = Config(data_dir=tmp_path)
    books = {str(i): synthetic_book(i, status="completed" if i % 2 else "ongoing",
                                   volume_count=i, first_seen="2026-10-01") for i in range(1, 251)}
    books["250"]["cover_key"] = ""
    catalog = Catalog(config, {}, books)
    rankings = load_rankings(config, catalog, "2026-10-17")
    for (board, period), items in rankings.boards.items():
        if board in ("words", "volumes", "new"):
            assert len(items) == len({item["id"] for item in items}) == 100
            assert items[0]["id"] == "250"
        else:
            assert items == []
    write_stats(config, [("2026-10-17", str(i), i) for i in range(1, 251)])
    with closing(sqlite3.connect(config.stats_path)) as connection:
        connection.executemany("INSERT INTO shelf_total VALUES (?, ?)", [(str(i), i) for i in range(1, 251)])
        connection.commit()
    ranked = load_rankings(config, catalog, "2026-10-17")
    for board in ("popular", "shelf", "rising", "completed"):
        items = ranked.boards[board, "week" if board in ("popular", "completed") else None]
        assert len(items) == 100 and all(item["score"] > 0 for item in items)
        assert items[0]["id"] == ("249" if board == "completed" else "250")


@pytest.mark.parametrize("has_stats", [False, True])
def test_empty_statistics_leave_all_four_statistical_boards_empty(tmp_path, has_stats):
    config = Config(data_dir=tmp_path)
    catalog = Catalog(config, {}, {"1": synthetic_book(1, status="completed"),
                                   "2": synthetic_book(2, status="completed", cover_key=""),
                                   "3": synthetic_book(3, status="ongoing", volume_count=100)})
    write_catalog(config.catalog_path, catalog.books)
    if has_stats:
        write_stats(config)
    with TestClient(create_app(config, date_provider=lambda: "2026-10-17")) as client:
        for board in ("popular", "completed", "shelf", "rising"):
            for period in PERIODS:
                response = client.get("/api/v1/rank", params={"board": board, "period": period})
                assert response.status_code == 200
                assert response.json()["total"] == 0 and response.json()["items"] == []
        assert client.get("/api/v1/home").json()["sections"][2] == {"key": "rank", "items": []}


def test_all_boards_empty_catalog(tmp_path):
    config = Config(data_dir=tmp_path)
    with TestClient(create_app(config)) as client:
        for board in BOARDS:
            result = client.get("/api/v1/rank", params={"board": board, "period": "day"})
            assert result.status_code == 200 and result.json()["total"] == 0 and result.json()["items"] == []


def test_shelf_events_reload_board_and_etag_without_readers(tmp_path):
    logs = tmp_path / "logs"
    logs.mkdir()
    config = Config(data_dir=tmp_path, log_dir=logs, rank_reload_seconds=0)
    write_catalog(config.catalog_path, {"1": synthetic_book(1), "2": synthetic_book(2)})
    url = "/api/v1/rank?board=shelf"
    with TestClient(create_app(config, date_provider=lambda: "2026-10-17")) as client:
        before = client.get(url)
        assert before.json()["items"] == [] and before.json()["total"] == 0
        (logs / "events.log").write_bytes(event(book="1"))
        stats = Stats(config, date_provider=lambda: "2026-10-17")
        assert stats.run_once().shelf_changes == 1
        client.get(url)
        client.app.state.rank_store.future.result(timeout=5)
        after = client.get(url, headers={"If-None-Match": before.headers["etag"]})
        assert after.status_code == 200 and after.json()["items"][0]["id"] == "1"
        assert after.json()["items"][0]["score"] == 1
        with (logs / "events.log").open("ab") as stream:
            stream.write(event(book="1", action="remove"))
        stats.run_once()
        client.get(url)
        client.app.state.rank_store.future.result(timeout=5)
        removed = client.get(url, headers={"If-None-Match": after.headers["etag"]})
        assert removed.status_code == 200 and removed.json()["items"] == []
        assert removed.json()["total"] == 0


def test_boards_date_change_recomputes_and_cache_keys_include_day(boards_config):
    with TestClient(create_app(boards_config, date_provider=lambda: "2026-10-17")) as client:
        before = {board: client.get(f"/api/v1/rank?board={board}&period=week") for board in BOARDS}
        version = client.get("/api/v1/meta").json()["content_version"]
        client.app.state.date_provider = lambda: "2026-10-18"
        client.get("/api/v1/rank?board=rising")
        client.app.state.rank_store.future.result(timeout=5)
        for board in BOARDS:
            url = f"/api/v1/rank?board={board}&period=week"
            response = client.get(url, headers={"If-None-Match": before[board].headers["etag"]})
            assert response.status_code == 200
            normalized = url + "#2026-10-18"
            digest = hashlib.sha1(normalized.encode()).hexdigest()[:16]
            assert response.headers["etag"] == f'W/"{version}-{digest}"'
            assert client.app.state.responses.get((version, normalized)) == response.content
        assert client.get("/api/v1/rank?board=rising").json()["items"][0]["id"] == "8"
        assert client.app.state.rank_store.rankings.version == "1"


def test_catalog_reload_keeps_shelf_and_previous_week_counts(boards_config):
    catalog = Catalog.load(boards_config)
    store = RankStore(boards_config, catalog, lambda: "2026-10-17")
    try:
        before = store.rankings
        newer = Catalog(boards_config, {"version": "new"}, {key: book for key, book in catalog.books.items() if key != "4"})
        after = store.snapshot(newer)
        assert after.shelf_counts == before.shelf_counts and after.previous_week == before.previous_week
        assert after.boards["shelf", None][0]["id"] == "3"
        assert after.boards["rising", None][0]["score"] == 8
        assert all(item["id"] != "4" for items in after.boards.values() for item in items)
    finally:
        store.close()


def test_old_stats_database_without_shelf_tables_is_readable(boards_config):
    with closing(sqlite3.connect(boards_config.stats_path)) as connection:
        connection.execute("DROP TABLE shelf")
        connection.execute("DROP TABLE shelf_total")
        connection.commit()
    rankings = load_rankings(boards_config, Catalog.load(boards_config), "2026-10-17")
    assert rankings.boards["popular", "week"][0]["score"] == 12
    assert rankings.boards["shelf", None] == []


def test_catalog_change_during_rank_reload_keeps_all_board_inputs(boards_config, monkeypatch):
    from novel import rank

    catalog = Catalog.load(boards_config)
    store = RankStore(boards_config, catalog, lambda: "2026-10-17")
    entered, release = threading.Event(), threading.Event()
    original = rank.load_rankings

    def delayed(*args):
        entered.set()
        assert release.wait(5)
        return original(*args)

    try:
        monkeypatch.setattr(rank, "load_rankings", delayed)
        write_stats(boards_config, version="2")
        store.snapshot(catalog)
        assert entered.wait(5)
        newer = Catalog(boards_config, {"version": "changed"}, {key: book for key, book in catalog.books.items() if key != "4"})
        store.snapshot(newer)
        release.set()
        store.future.result(timeout=5)
        assert store.rankings.catalog is newer and store.rankings.version == "2"
        assert store.rankings.boards["shelf", None][0]["id"] == "3"
        assert store.rankings.boards["shelf", None][0]["score"] == 5
        assert store.rankings.boards["rising", None][0]["score"] == 8
        assert all(item["id"] != "4" for items in store.rankings.boards.values() for item in items)
    finally:
        release.set()
        store.close()
