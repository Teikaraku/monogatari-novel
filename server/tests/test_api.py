import hashlib
import os
import threading
from dataclasses import replace

import pytest
from fastapi.testclient import TestClient

from novel.api import CACHE_CONTROL, create_app
from novel.catalog import Catalog, LRU
from novel.config import Config
from novel.indexer import write_catalog
from novel.rank import Rankings
from conftest import synthetic_book
from test_rank import write_stats


@pytest.fixture
def api_data(tmp_path):
    config = Config(data_dir=tmp_path, reload_check_seconds=0, public_base="https://static.example.test")
    books = {}
    for i in range(1, 91):
        volumes = [{"n": n, "label": f"第{n}卷", "file": f"{n}_story.epub", "size": n * 10, "mtime": 1700000000 + n}
                   for n in range(1, 9)]
        book = synthetic_book(i, status="completed" if i % 2 else "ongoing", words=i * 1000,
                              updated=f"2024-01-{i % 28 + 1:02d}", tags=["共有", f"分类{i % 30:02d}", "三", "四", "五", "六"],
                              volume_list=volumes)
        books[str(i)] = book
    write_catalog(config.catalog_path, books)
    return config, books


@pytest.fixture
def client(api_data):
    config, _ = api_data
    with TestClient(create_app(config, date_provider=lambda: "2026-10-17")) as connection:
        yield connection


SUMMARY_FIELDS = {"id", "title", "author", "status", "tags", "volumes", "words", "updated", "cover", "cover_large"}


def test_endpoint_shapes(client):
    meta = client.get("/api/v1/meta")
    assert meta.status_code == 200
    assert set(meta.json()) == {"version", "content_version", "built_at", "books", "volumes"}
    assert meta.json()["books"] == 90 and meta.json()["volumes"] == 720
    listing = client.get("/api/v1/books").json()
    assert (listing["total"], listing["offset"], listing["limit"]) == (90, 0, 30)
    assert len(listing["items"]) == 30
    assert set(listing["items"][0]) == SUMMARY_FIELDS
    assert len(listing["items"][0]["tags"]) == 5
    detail_response = client.get("/api/v1/books/1")
    detail = detail_response.json()
    assert set(detail) == SUMMARY_FIELDS | {"illustrator", "publisher", "description", "chapters", "volume_list", "tv"}
    assert detail["tv"] is None
    assert len(detail["tags"]) == 6
    assert detail["cover"] == "https://static.example.test/covers/1/0123456789ab-240.webp"
    assert detail["cover_large"] == "https://static.example.test/covers/1/0123456789ab-480.webp"
    assert detail["volume_list"][0] == {"n": 1, "label": "第1卷", "size": 10, "mtime": 1700000001, "chapters": 0,
                                        "url": "https://static.example.test/files/1/1.epub"}
    assert b'": ' not in detail_response.content
    assert "故事1".encode() in detail_response.content
    tags = client.get("/api/v1/tags").json()["tags"]
    assert tags == sorted(tags, key=lambda tag: (-tag["count"], tag["name"]))
    assert {entry["name"]: entry["count"] for entry in tags}["共有"] == 90
    search = client.get("/api/v1/search", params={"q": " 故事1 "}).json()
    assert set(search) == {"q", "total", "offset", "limit", "items"}
    assert search["q"] == " 故事1 " and search["items"][0]["id"] == "1"
    size = len(client.app.state.responses.items)
    health = client.get("/healthz")
    assert health.json() == {"ok": True, "version": meta.json()["version"]}
    assert health.headers["cache-control"] == "no-store" and "etag" not in health.headers
    assert len(client.app.state.responses.items) == size


@pytest.mark.parametrize(("url", "params"), [
    ("/api/v1/books", {"limit": 0}), ("/api/v1/books", {"limit": 61}),
    ("/api/v1/books", {"offset": -1}), ("/api/v1/books", {"offset": "1.2"}),
    ("/api/v1/books/bad", {}), ("/api/v1/books/12345678901", {}),
    ("/api/v1/books", {"sort": "bad"}), ("/api/v1/books", {"status": "unknown"}),
    ("/api/v1/books", {"sort": "random"}), ("/api/v1/books", {"sort": "random", "seed": -1}),
    ("/api/v1/books", {"sort": "random", "seed": 2**31}),
    ("/api/v1/books", {"sort": "random", "seed": "bad"}),
    ("/api/v1/books", [("tag", "a"), ("tag", "b"), ("tag", "c"), ("tag", "d")]),
    ("/api/v1/search", {}), ("/api/v1/search", {"q": ""}), ("/api/v1/search", {"q": " \t　"}),
    ("/api/v1/search", {"q": "a" * 65}), ("/api/v1/search", {"q": "a", "limit": 61}),
    ("/api/v1/search", {"q": "a", "limit": 0}), ("/api/v1/search", {"q": "a", "offset": -1}),
])
def test_bad_parameters(client, url, params):
    response = client.get(url, params=params)
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "bad_request"
    assert response.json()["error"]["message"].isascii()
    assert response.headers["cache-control"] == "no-store"
    assert "etag" not in response.headers


def test_missing_book(client):
    response = client.get("/api/v1/books/999999")
    assert response.status_code == 404
    assert response.json() == {"error": {"code": "not_found", "message": "Not found"}}
    assert response.headers["cache-control"] == "no-store"
    assert "etag" not in response.headers


def test_pagination_filters_and_ignored_seed(client):
    result = client.get("/api/v1/books", params={"offset": 9999, "limit": 60}).json()
    assert result == {"total": 90, "offset": 9999, "limit": 60, "items": []}
    result = client.get("/api/v1/search", params={"q": "故事", "offset": 9999}).json()
    assert result["total"] == 90 and result["items"] == []
    result = client.get("/api/v1/books?tag=共有&tag=分类01&status=completed").json()
    assert result["total"] == 3
    assert {item["id"] for item in result["items"]} == {"1", "31", "61"}
    assert client.get("/api/v1/books?tag=missing").json()["total"] == 0
    assert client.get("/api/v1/books?tag=分类01&tag=分类02").json()["total"] == 0
    assert client.get("/api/v1/books?seed=not-an-integer").json() == client.get("/api/v1/books").json()
    assert client.get("/api/v1/search", params={"q": "　" + "Ａ" * 64 + "　"}).status_code == 200


def test_etag_normalized_query_and_lru(client):
    response = client.get("/api/v1/books?limit=10&offset=0")
    normalized = "/api/v1/books?limit=10&offset=0"
    version = client.get("/api/v1/meta").json()["content_version"]
    expected = f'W/"{version}-{hashlib.sha1(normalized.encode()).hexdigest()[:16]}"'
    assert response.headers["etag"] == expected
    cached = client.get("/api/v1/books?offset=0&limit=10")
    assert cached.content == response.content and cached.headers["etag"] == expected
    conditional = client.get("/api/v1/books?offset=0&limit=10", headers={"If-None-Match": expected})
    assert conditional.status_code == 304 and conditional.content == b""
    assert conditional.headers["etag"] == expected and conditional.headers["cache-control"] == CACHE_CONTROL
    assert isinstance(client.app.state.responses.get((version, normalized)), bytes)
    assert client.app.state.responses.capacity == 2048


def test_home_day_rollover_changes_lru_and_etag(client):
    first = client.get("/api/v1/home")
    assert client.get("/api/v1/home").content == first.content
    data = first.json()
    assert [section["key"] for section in data["sections"]] == ["featured", "picks", "rank", "recent", "tv", "completed", "long"]
    assert [len(section["items"]) for section in data["sections"]] == [6, 6, 0, 12, 0, 6, 6]
    ids = [item["id"] for section in data["sections"] if section["key"] not in ("rank", "tv") for item in section["items"]]
    assert len(ids) == len(set(ids))
    assert all(len(item["description"]) == 80 for item in data["sections"][0]["items"])
    assert len(data["tags"]) == 24
    assert data["tags"] == client.get("/api/v1/tags").json()["tags"][:24]
    featured_ids = {item["id"] for section in data["sections"][:2] for item in section["items"]}
    catalog = client.app.state.store.catalog
    assert [item["id"] for item in data["sections"][3]["items"]] == [
        key for key in catalog.sorted_ids["updated"] if key not in featured_ids
    ][:12]
    client.app.state.date_provider = lambda: "2026-10-18"
    second = client.get("/api/v1/home", headers={"If-None-Match": first.headers["etag"]})
    assert second.status_code == 200 and second.json()["date"] == "2026-10-18"
    assert second.headers["etag"] != first.headers["etag"]
    assert second.json()["sections"][0] != data["sections"][0]
    version = client.get("/api/v1/meta").json()["content_version"]
    assert (version, "/api/v1/home#2026-10-17") in client.app.state.responses.items
    assert (version, "/api/v1/home#2026-10-18") in client.app.state.responses.items


@pytest.mark.parametrize("phrase", ["机翻", "机润", "润色", "请返回", "介意者", "语言模型"])
def test_featured_excludes_translator_notes_without_changing_book(tmp_path, phrase):
    config = Config(data_dir=tmp_path)
    description = "故事开篇" * 10 + phrase + "，译者说明。" + "故事内容" * 30
    write_catalog(config.catalog_path, {"1": synthetic_book(1, description=description)})
    write_stats(config, [("2026-10-17", "1", 1)])
    stored = config.catalog_path.read_bytes()
    with TestClient(create_app(config, date_provider=lambda: "2026-10-17")) as client:
        sections = {section["key"]: section["items"] for section in client.get("/api/v1/home").json()["sections"]}
        assert sections["featured"] == []
        assert [item["id"] for item in sections["picks"]] == ["1"]
        assert [item["id"] for item in sections["rank"]] == ["1"]
        assert client.get("/api/v1/books").json()["total"] == 1
        assert client.get("/api/v1/books/1").json()["description"] == description
        assert client.app.state.store.catalog.books["1"]["description"] == description
    assert config.catalog_path.read_bytes() == stored


@pytest.mark.parametrize(("prefix_length", "included"), [(0, False), (116, False), (117, True), (120, True)])
def test_featured_note_filter_uses_first_120_characters(tmp_path, prefix_length, included):
    description = "序" * prefix_length + "语言模型" + "故事内容" * 40
    catalog = Catalog(Config(data_dir=tmp_path), {}, {"1": synthetic_book(1, description=description)})
    featured = catalog.home("2026-10-17")["sections"][0]["items"]
    assert [item["id"] for item in featured] == (["1"] if included else [])
    if included:
        assert featured[0]["description"] == description[:80]


def test_translator_notes_remain_eligible_for_every_other_home_section(tmp_path):
    description = "机翻译者说明。" + "故事内容" * 30
    books = {str(i): synthetic_book(i, description=description, status="completed", volume_count=8)
             for i in range(1, 51)}
    tv = {"upcoming": [], "completed": [
        {"book_id": str(i), "season": "2026年", "badge": "", "studio": ""} for i in range(1, 51)
    ]}
    catalog = Catalog(Config(data_dir=tmp_path), {}, books, tv=tv)
    rankings = Rankings(catalog, "1", {"week": {key: 1 for key in books}}, "2026-10-17")
    sections = {section["key"]: section["items"] for section in catalog.home("2026-10-17", rankings)["sections"]}
    assert {key: len(items) for key, items in sections.items()} == {
        "featured": 0, "picks": 6, "rank": 10, "recent": 12, "tv": 12, "completed": 6, "long": 6,
    }
    ids = [item["id"] for key in ("picks", "recent", "completed", "long") for item in sections[key]]
    assert len(ids) == len(set(ids))
    assert all(book["description"] == description for book in catalog.books.values())


def test_random_pages_are_stable(client):
    def page(seed, offset=0, limit=30):
        return client.get("/api/v1/books", params={"sort": "random", "seed": seed, "offset": offset, "limit": limit}).json()
    first = page(10)
    second = page(10, 30)
    assert first == page(10)
    assert first["items"] + second["items"] == page(10, limit=60)["items"]
    assert first["items"] != page(11)["items"]
    assert first["items"] != client.get("/api/v1/books").json()["items"]
    assert client.app.state.store.catalog.random_cache.capacity == 64


def test_absent_database_and_no_cover(tmp_path):
    config = Config(data_dir=tmp_path)
    with TestClient(create_app(config, date_provider=lambda: "2026-10-17")) as client:
        assert client.get("/api/v1/meta").json() == {"version": "", "content_version": ".da39a3ee", "built_at": "", "books": 0, "volumes": 0}
        assert client.get("/api/v1/books").json()["items"] == []
        assert client.get("/api/v1/search?q=test").json()["total"] == 0
        assert all(section["items"] == [] for section in client.get("/api/v1/home").json()["sections"])
        assert client.get("/api/v1/tags").json() == {"tags": []}
    books = {"01": synthetic_book("01", cover_key="", tags=[])}
    write_catalog(config.catalog_path, books)
    with TestClient(create_app(config)) as client:
        detail = client.get("/api/v1/books/01").json()
        assert detail["id"] == "01" and detail["cover"] is None and detail["cover_large"] is None
        assert detail["volume_list"][0]["url"] == "/files/01/1.epub"


@pytest.mark.skipif(os.name == "nt", reason="Atomic replacement of an open SQLite catalog is supported on Linux; Windows denies it")
def test_reload_keeps_old_snapshot_while_loading(client, api_data, monkeypatch, caplog):
    config, books = api_data
    previous = client.get("/api/v1/meta").json()
    entered = threading.Event()
    release = threading.Event()
    original = Catalog.load

    def slow_load(config):
        entered.set()
        assert release.wait(timeout=5)
        return original(config)

    monkeypatch.setattr(Catalog, "load", slow_load)
    books["91"] = synthetic_book(91)
    write_catalog(config.catalog_path, books)
    assert client.get("/api/v1/meta").json() == previous
    assert entered.wait(timeout=2)
    assert client.get("/api/v1/meta").json() == previous
    release.set()
    client.app.state.store.future.result(timeout=5)
    new = client.get("/api/v1/meta").json()
    assert new["books"] == 91 and new["version"] != previous["version"]
    assert client.get("/api/v1/books/91").status_code == 200
    config.catalog_path.write_bytes(b"invalid sqlite")
    assert client.get("/api/v1/meta").json() == new
    client.app.state.store.future.result(timeout=5)
    assert client.app.state.store.catalog.meta == new
    assert "Could not reload catalog" in caplog.text


def test_lru_eviction():
    cache = LRU(2)
    cache.put("a", b"a")
    cache.put("b", b"b")
    assert cache.get("a") == b"a"
    cache.put("c", b"c")
    assert cache.get("b") is None
    assert cache.get("a") == b"a" and cache.get("c") == b"c"


def test_all_sort_orders(tmp_path):
    books = {
        "2": synthetic_book(2, sort_title="a", updated="2024-01-02", words=10),
        "10": synthetic_book(10, sort_title="a", updated="2024-01-02", words=20),
        "3": synthetic_book(3, sort_title="z", updated="2024-01-01", words=20,
                            volume_list=[{"n": 1, "label": "a", "file": "1_a.epub", "size": 1, "mtime": 0}]),
    }
    config = Config(data_dir=tmp_path)
    write_catalog(config.catalog_path, books)
    with TestClient(create_app(config)) as client:
        expected = {"updated": ["10", "2", "3"], "title": ["2", "10", "3"],
                    "words": ["10", "3", "2"], "volumes": ["10", "2", "3"]}
        for sort, ids in expected.items():
            assert [item["id"] for item in client.get("/api/v1/books", params={"sort": sort}).json()["items"]] == ids
