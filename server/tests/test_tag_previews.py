import pytest
from fastapi.testclient import TestClient

from novel.api import create_app
from novel.config import Config
from novel.indexer import write_catalog
from conftest import synthetic_book
from test_rank import write_stats


@pytest.fixture
def preview_config(tmp_path):
    config = Config(data_dir=tmp_path, rank_reload_seconds=0, public_base="https://static.example.test")
    books = {
        "1": synthetic_book(1, cover_key="", tags=["共同", "无封面"], updated="2028-01-01"),
        "2": synthetic_book(2, tags=["共同"], updated="2024-01-01"),
        "3": synthetic_book(3, tags=["共同"], updated="2025-01-01"),
        "10": synthetic_book(10, tags=["共同"], updated="2025-01-01"),
        "4": synthetic_book(4, tags=["共同", "唯一"], updated="2020-01-01"),
        "5": synthetic_book(5, tags=["共同"], updated="2027-01-01"),
    }
    write_catalog(config.catalog_path, books)
    return config


def cover_ids(tag):
    return [url.split("/covers/")[1].split("/")[0] for url in tag["covers"]]


@pytest.mark.parametrize("covers", [1, 2, 3, 4])
def test_tag_previews_use_total_counts_and_tie_breaks(preview_config, covers):
    write_stats(preview_config, totals=[("1", 999), ("2", 5), ("3", 5), ("10", 5), ("4", 20)])
    with TestClient(create_app(preview_config)) as client:
        tags = client.get("/api/v1/tags", params={"covers": covers}).json()["tags"]
        by_name = {tag["name"]: tag for tag in tags}
        assert cover_ids(by_name["共同"]) == ["4", "10", "3", "2"][:covers]
        assert by_name["共同"]["count"] == 6 and by_name["无封面"]["covers"] == []
        assert cover_ids(by_name["唯一"]) == ["4"]
        assert all(len(tag["covers"]) <= covers for tag in tags)
        assert all(url.startswith("https://static.example.test/covers/") and url.endswith("-240.webp")
                   for tag in tags for url in tag["covers"])
        plain = client.get("/api/v1/tags").json()["tags"]
        assert plain == [{key: value for key, value in tag.items() if key != "covers"} for tag in tags]
        assert client.get("/api/v1/tags?covers=0").json()["tags"] == plain
        assert all("covers" not in tag for tag in client.get("/api/v1/home").json()["tags"])


def test_missing_stats_previews_use_updated_then_numeric_id(preview_config):
    with TestClient(create_app(preview_config)) as client:
        tags = {tag["name"]: tag for tag in client.get("/api/v1/tags?covers=4").json()["tags"]}
        assert cover_ids(tags["共同"]) == ["5", "10", "3", "2"]


def test_previews_include_books_below_top_100(tmp_path):
    config = Config(data_dir=tmp_path)
    books = {str(i): synthetic_book(i, tags=["其他"]) for i in range(1, 102)}
    books.update({"200": synthetic_book(200, tags=["目标"], updated="2020-01-01"),
                  "201": synthetic_book(201, tags=["目标"], updated="2026-01-01")})
    write_catalog(config.catalog_path, books)
    write_stats(config, totals=[(str(i), 1000) for i in range(1, 102)] + [("200", 2), ("201", 1)])
    with TestClient(create_app(config)) as client:
        assert "200" not in {item["id"] for item in client.app.state.rank_store.rankings.items["total"]}
        tags = {tag["name"]: tag for tag in client.get("/api/v1/tags?covers=4").json()["tags"]}
        assert cover_ids(tags["目标"]) == ["200", "201"]


def test_stats_reload_updates_tag_preview_cache(preview_config):
    write_stats(preview_config, totals=[("4", 20)])
    with TestClient(create_app(preview_config)) as client:
        before = client.get("/api/v1/tags?covers=1")
        write_stats(preview_config, totals=[("5", 30)], version="2")
        client.get("/api/v1/tags?covers=1")
        client.app.state.rank_store.future.result(timeout=5)
        after = client.get("/api/v1/tags?covers=1", headers={"If-None-Match": before.headers["etag"]})
        assert after.status_code == 200 and after.headers["etag"] != before.headers["etag"]
        tags = {tag["name"]: tag for tag in after.json()["tags"]}
        assert cover_ids(tags["共同"]) == ["5"]
        assert client.get("/api/v1/tags?covers=1", headers={"If-None-Match": after.headers["etag"]}).status_code == 304


@pytest.mark.parametrize("value", [5, -1, "1.5", "bad", ""])
def test_invalid_cover_count(preview_config, value):
    with TestClient(create_app(preview_config)) as client:
        response = client.get("/api/v1/tags", params={"covers": value})
        assert response.status_code == 400 and response.headers["cache-control"] == "no-store"
        assert "etag" not in response.headers
