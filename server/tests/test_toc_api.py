import hashlib
import gc
import os
import sqlite3
import weakref
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing

import pytest
from fastapi.testclient import TestClient

from conftest import synthetic_book
from novel.api import CACHE_CONTROL, create_app
from novel.catalog import Catalog, LRU
from novel.config import Config
from novel.indexer import write_catalog


@pytest.fixture
def toc_config(tmp_path):
    config = Config(data_dir=tmp_path, curation_dir=tmp_path / "curation", reload_check_seconds=0)
    config.curation_dir.mkdir()
    for path in (config.data_dir / "banners.json", config.curation_dir / "tv.json",
                 config.curation_dir / "themes.json"):
        path.write_text("{}", encoding="utf-8")
    book = synthetic_book(1000)
    book["volume_list"][0]["toc"] = [
        {"title": "第一章", "href": "OEBPS/Text/ch1.xhtml", "level": 0},
        {"title": "第一节", "href": "OEBPS/Text/ch1.xhtml#p3", "level": 1},
    ]
    write_catalog(config.catalog_path, {"1000": book})
    return config


def test_toc_detail_count_response_cache_and_conditional_get(toc_config, monkeypatch):
    with TestClient(create_app(toc_config)) as client:
        detail = client.get("/api/v1/books/1000").json()
        assert [volume["chapters"] for volume in detail["volume_list"]] == [2, 0]
        url = "/api/v1/books/1000/volumes/1/toc"
        response = client.get(url)
        assert response.status_code == 200
        assert response.json() == {"book_id": "1000", "n": 1, "items": [
            {"title": "第一章", "href": "OEBPS/Text/ch1.xhtml", "level": 0},
            {"title": "第一节", "href": "OEBPS/Text/ch1.xhtml#p3", "level": 1},
        ]}
        version = client.get("/api/v1/meta").json()["content_version"]
        digest = hashlib.sha1(url.encode()).hexdigest()[:16]
        assert response.headers["etag"] == f'W/"{version}-{digest}"'
        assert response.headers["cache-control"] == CACHE_CONTROL
        cache = client.app.state.responses
        assert cache.get((version, url)) == response.content
        def unexpected_query(*_):
            pytest.fail("A cached or conditional response must not query the TOC")

        monkeypatch.setattr(client.app.state.store.catalog, "volume_toc", unexpected_query)
        assert client.get(url).content == response.content
        conditional = client.get(url, headers={"If-None-Match": response.headers["etag"]})
        assert conditional.status_code == 304 and conditional.content == b""
        assert conditional.headers["etag"] == response.headers["etag"]
        assert conditional.headers["cache-control"] == CACHE_CONTROL


@pytest.mark.parametrize("book_id,n", [("9999", 1), ("1000", 3), ("1000", 0), ("1000", -1)])
def test_missing_book_or_volume_returns_uncached_404(toc_config, book_id, n):
    with TestClient(create_app(toc_config)) as client:
        response = client.get(f"/api/v1/books/{book_id}/volumes/{n}/toc")
        assert response.status_code == 404
        assert response.json() == {"error": {"code": "not_found", "message": "Not found"}}
        assert response.headers["cache-control"] == "no-store"
        assert "etag" not in response.headers


def test_existing_volume_without_toc_returns_empty_items(toc_config):
    with TestClient(create_app(toc_config)) as client:
        response = client.get("/api/v1/books/1000/volumes/2/toc")
        assert response.status_code == 200
        assert response.json() == {"book_id": "1000", "n": 2, "items": []}


def test_legacy_catalog_without_toc_table_is_readable(toc_config):
    with closing(sqlite3.connect(toc_config.catalog_path)) as connection:
        connection.execute("DROP TABLE volume_toc")
        connection.commit()
    with TestClient(create_app(toc_config)) as client:
        assert client.get("/api/v1/books/1000/volumes/1/toc").json() == {
            "book_id": "1000", "n": 1, "items": []}
        assert all(volume["chapters"] == 0 for volume in client.get("/api/v1/books/1000").json()["volume_list"])


def test_catalog_keeps_only_counts_and_uses_a_read_only_connection(toc_config):
    catalog = Catalog.load(toc_config)
    volumes = catalog.books["1000"]["volume_list"]
    assert all("toc" not in volume for volume in volumes)
    assert [volume["chapters"] for volume in volumes] == [2, 0]
    assert [volume["chapters"] for volume in catalog.detail("1000")["volume_list"]] == [2, 0]
    with pytest.raises(sqlite3.OperationalError, match="readonly"):
        catalog._toc_connection.execute("DELETE FROM volume_toc")
    assert len(catalog.volume_toc("1000", 1)["items"]) == 2
    assert all("toc" not in volume for volume in volumes)


def test_toc_queries_can_run_on_threads_other_than_the_loader(toc_config):
    catalog = Catalog.load(toc_config)
    expected = catalog.volume_toc("1000", 1)
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda _: catalog.volume_toc("1000", 1), range(40)))
    assert all(result == expected for result in results)


def test_catalog_finalizer_closes_connection_after_last_reference(toc_config):
    catalog = Catalog.load(toc_config)
    reference = weakref.ref(catalog)
    connection = catalog._toc_connection
    retained_request = catalog
    del catalog
    gc.collect()
    assert reference() is retained_request
    assert retained_request.volume_toc("1000", 1)["items"]
    del retained_request
    gc.collect()
    assert reference() is None
    with pytest.raises(sqlite3.ProgrammingError, match="closed"):
        connection.execute("SELECT 1")


def test_load_failure_closes_the_read_only_connection(toc_config, monkeypatch):
    connections = []
    original_connect = sqlite3.connect

    def connect(*args, **kwargs):
        connection = original_connect(*args, **kwargs)
        connections.append(connection)
        return connection

    def broken_themes(*_):
        raise RuntimeError("load failed")

    monkeypatch.setattr("novel.catalog.sqlite3.connect", connect)
    monkeypatch.setattr("novel.catalog.read_themes", broken_themes)
    with pytest.raises(RuntimeError, match="load failed"):
        Catalog.load(toc_config)
    assert connections
    for connection in connections:
        with pytest.raises(sqlite3.ProgrammingError, match="closed"):
            connection.execute("SELECT 1")


@pytest.mark.skipif(os.name == "nt", reason="Atomic replacement of an open SQLite catalog is supported on Linux; Windows denies it")
def test_toc_api_keeps_each_catalog_snapshot_across_atomic_replacement(toc_config, monkeypatch):
    url = "/api/v1/books/1000/volumes/1/toc"
    with TestClient(create_app(toc_config)) as client:
        store = client.app.state.store
        old = store.catalog
        before = client.get(url)
        book = synthetic_book(1000)
        book["volume_list"][0]["toc"] = [
            {"title": "替换后的章节", "href": "OEBPS/new.xhtml#updated", "level": 0}]
        write_catalog(toc_config.catalog_path, {"1000": book})
        store._reload(store._stamp())
        assert store.catalog is not old
        after = client.get(url, headers={"If-None-Match": before.headers["etag"]})
        assert after.status_code == 200
        assert after.json()["items"] == book["volume_list"][0]["toc"]
        assert after.headers["etag"] != before.headers["etag"]
        assert client.get("/api/v1/books/1000").json()["volume_list"][0]["chapters"] == 1
        # Model an in-flight request retaining the old snapshot after reload.
        # Clear the response cache so the assertion exercises its open connection.
        monkeypatch.setattr(store, "snapshot", lambda: old)
        client.app.state.responses = LRU(2048)
        retained = client.get(url)
        assert retained.status_code == 200
        assert retained.json() == before.json()
        assert retained.headers["etag"] == before.headers["etag"]
        assert old.detail("1000")["volume_list"][0]["chapters"] == 2
