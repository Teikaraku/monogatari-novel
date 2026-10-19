"""Measure the v1.4 TOC storage change against its frozen eager loader."""

import gc
import hashlib
import sqlite3
import time
import tracemalloc
from contextlib import closing
from types import SimpleNamespace

import orjson
import pytest
from fastapi.testclient import TestClient

from novel import indexer, toc
from novel.api import create_app
from novel.catalog import Catalog
from novel.config import Config
from novel.curation import read_banners, read_themes, read_tv
from novel.scan import BookSource
from conftest import synthetic_book

BOOKS = 5000
VOLUMES = 19000
CHAPTERS_PER_VOLUME = 30


def _eager_catalog_load(config):
    """Exact pre-rework Catalog.load body, captured before changing production code.

    The shared Catalog constructor builds the same non-TOC indexes for both
    measurements. Only the eager loading body is frozen here; this deliberately
    reads the same SQLite fixture and all 570,000 TOC rows as the original did.
    """
    meta, books = {}, {}
    if config.catalog_path.exists():
        connection = sqlite3.connect(config.catalog_path.resolve().as_uri() + "?mode=ro", uri=True)
        connection.row_factory = sqlite3.Row
        try:
            meta = dict(connection.execute("SELECT key, value FROM meta"))
            for row in connection.execute("SELECT * FROM books"):
                book = dict(row)
                book["tags"] = orjson.loads(book["tags"])
                book["volume_list"] = []
                books[book["id"]] = book
            for row in connection.execute("SELECT * FROM volumes ORDER BY book_id, n"):
                volume = dict(row)
                volume["toc"] = []
                books[volume.pop("book_id")]["volume_list"].append(volume)
            has_toc = connection.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='volume_toc'").fetchone()
            if has_toc:
                volumes = {(key, volume["n"]): volume for key, book in books.items()
                           for volume in book["volume_list"]}
                for row in connection.execute(
                        "SELECT book_id, n, title, href, level FROM volume_toc ORDER BY book_id, n, idx"):
                    volumes[row["book_id"], row["n"]]["toc"].append(
                        {key: row[key] for key in ("title", "href", "level")})
        finally:
            connection.close()
    banners, banner_bytes = read_banners(config.data_dir / "banners.json", generated=True)
    tv, tv_bytes = read_tv(config.curation_dir / "tv.json")
    themes, theme_bytes = read_themes(config.curation_dir / "themes.json")
    return Catalog(config, meta, books, banners=banners, tv=tv, themes=themes,
                   content_hash=hashlib.sha1(banner_bytes + tv_bytes + theme_bytes).hexdigest()[:8])


def _build_fixture(tmp_path, monkeypatch):
    """Use real TOC cache, catalog writer and state writer; omit EPUB scanning I/O."""
    config = Config(library_dir=tmp_path / "library", data_dir=tmp_path / "data",
                    curation_dir=tmp_path / "curation", log_dir=tmp_path / "logs")
    config.library_dir.mkdir()
    config.data_dir.mkdir()
    config.curation_dir.mkdir()
    (config.data_dir / "banners.json").write_bytes(orjson.dumps({"banners": []}))
    (config.curation_dir / "banners.json").write_bytes(orjson.dumps({"banners": []}))
    (config.curation_dir / "tv.json").write_bytes(orjson.dumps({"upcoming": [], "completed": []}))
    (config.curation_dir / "themes.json").write_bytes(orjson.dumps({"themes": []}))
    entries = [{"title": f"第 {i + 1} 章：合成目录条目", "href": f"OEBPS/Text/chapter-{i + 1:02d}.xhtml#content",
                "level": i % 3} for i in range(CHAPTERS_PER_VOLUME)]
    encoded_entries = orjson.dumps(entries).decode()
    stat = SimpleNamespace(st_size=1000000, st_mtime=1700000000, st_mtime_ns=1700000000000000000)
    books, sources = {}, {}
    for i in range(1, BOOKS + 1):
        count = 4 if i <= 4000 else 3
        volumes = [{"n": n, "label": f"第{n}卷", "file": f"{n:02d}_fixture.epub",
                    "size": stat.st_size, "mtime": stat.st_mtime} for n in range(1, count + 1)]
        book = synthetic_book(i, volume_list=volumes, cover_key="")
        books[book["id"]] = book
        sources[book["id"]] = BookSource(
            book["id"], config.library_dir / book["directory"], book["title"], {},
            [(volume["file"], stat) for volume in volumes], None,
            hashlib.sha1(book["id"].encode()).hexdigest())
    assert sum(book["volume_count"] for book in books.values()) == VOLUMES
    with closing(sqlite3.connect(config.data_dir / "toc_cache.sqlite")) as connection:
        connection.executescript(toc.CACHE_SCHEMA)
        connection.executemany(
            "INSERT INTO toc_cache (book_id, n, size, mtime, entries_json, ok) VALUES (?, ?, ?, ?, ?, 1)", (
            (book_id, volume["n"], stat.st_size, stat.st_mtime_ns, encoded_entries)
            for book_id, book in books.items() for volume in book["volume_list"]
        ))
        connection.commit()

    with monkeypatch.context() as patch:
        patch.setattr(indexer, "scan_library", lambda *_: sources)
        patch.setattr(indexer, "parse_book", lambda source, _: books[source.id])
        patch.setattr(indexer, "sync_links", lambda *_: 0)

        def must_reuse_cache(*_):
            pytest.fail("Synthetic fixture must reuse the prefilled TOC cache without opening EPUBs")

        patch.setattr(toc, "extract_toc", must_reuse_cache)
        stats = indexer.Indexer(config).run_once()
    assert stats.rebuilt and stats.books == BOOKS and stats.volumes == VOLUMES
    with closing(sqlite3.connect(config.catalog_path)) as connection:
        assert connection.execute("SELECT COUNT(*) FROM volume_toc").fetchone()[0] == VOLUMES * CHAPTERS_PER_VOLUME

    state_path = config.data_dir / "state.json"
    state = orjson.loads(state_path.read_bytes())
    assert len(state) == BOOKS
    assert all("toc" not in volume for value in state.values() for volume in value["book"]["volume_list"])
    # Reproduce the former state's encoding with the same metadata and signatures.
    for value in state.values():
        for volume in value["book"]["volume_list"]:
            volume["toc"] = entries
    old_state_path = config.data_dir / "state-before-rework.json"
    old_state_path.write_bytes(orjson.dumps(state))
    return config, state_path.stat().st_size, old_state_path.stat().st_size


def _measure_load(loader, config, *, eager):
    """Time without tracing, then separately measure retained/peak Python allocations.

    Each pass starts after fixture construction and a full collection. tracemalloc
    begins only for the second load, so neither the fixture nor previous catalogs
    contribute to the delta. SQLite native allocations and OS page cache are not
    included; this measures the Python objects formerly retaining the TOC rows.
    """
    gc.collect()
    start = time.perf_counter()
    catalog = loader(config)
    elapsed = time.perf_counter() - start
    assert len(catalog.books) == BOOKS
    del catalog
    gc.collect()

    tracemalloc.start()
    before, _ = tracemalloc.get_traced_memory()
    try:
        catalog = loader(config)
        retained, peak = tracemalloc.get_traced_memory()
        volumes = [volume for book in catalog.books.values() for volume in book["volume_list"]]
        assert len(volumes) == VOLUMES
        if eager:
            assert all(len(volume["toc"]) == CHAPTERS_PER_VOLUME for volume in volumes)
        else:
            assert all("toc" not in volume and volume["chapters"] == CHAPTERS_PER_VOLUME for volume in volumes)
    finally:
        tracemalloc.stop()
    del volumes, catalog
    gc.collect()
    return elapsed, retained - before, peak - before


@pytest.mark.perf
def test_toc_storage_load_and_uncached_endpoint_performance(tmp_path, monkeypatch, pytestconfig):
    config, state_bytes, old_state_bytes = _build_fixture(tmp_path, monkeypatch)
    # Both loaders use the identical on-disk fixture with a warm filesystem cache.
    # Fixture creation above has already written and read every TOC row.
    before_seconds, before_memory, before_peak = _measure_load(_eager_catalog_load, config, eager=True)
    after_seconds, after_memory, after_peak = _measure_load(Catalog.load, config, eager=False)

    with TestClient(create_app(config, date_provider=lambda: "2026-10-18")) as client:
        assert not client.app.state.responses.items
        start = time.perf_counter()
        response = client.get("/api/v1/books/1/volumes/1/toc")
        request_ms = (time.perf_counter() - start) * 1000
        assert response.status_code == 200
        assert len(response.json()["items"]) == CHAPTERS_PER_VOLUME
        assert len(client.app.state.responses.items) == 1

    mib = 1024 * 1024
    label = "TOC storage, 5000 books / 19000 volumes / 30 entries each"
    metrics = getattr(pytestconfig, "performance_metrics", {})
    metrics.update({
        f"{label}, eager load before": f"{before_seconds:.6f} s",
        f"{label}, count-only load after": f"{after_seconds:.6f} s",
        f"{label}, retained Python memory before": f"{before_memory / mib:.6f} MiB ({before_memory} bytes)",
        f"{label}, retained Python memory after": f"{after_memory / mib:.6f} MiB ({after_memory} bytes)",
        f"{label}, peak Python memory before": f"{before_peak / mib:.6f} MiB ({before_peak} bytes)",
        f"{label}, peak Python memory after": f"{after_peak / mib:.6f} MiB ({after_peak} bytes)",
        f"{label}, state.json before": f"{old_state_bytes} bytes ({old_state_bytes / mib:.6f} MiB)",
        f"{label}, state.json after": f"{state_bytes} bytes ({state_bytes / mib:.6f} MiB)",
        f"{label}, first TOC HTTP request, empty LRU": f"{request_ms:.6f} ms",
    })
    pytestconfig.performance_metrics = metrics
    assert after_memory < before_memory
    assert state_bytes < old_state_bytes
