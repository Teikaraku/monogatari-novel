import hashlib
import os
from dataclasses import replace
from unittest.mock import Mock

import orjson
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from novel import curation
from novel.api import create_app
from novel.catalog import Catalog
from novel.config import Config
from novel.curation import read_banners, read_tv, sync_banners
from novel.indexer import Indexer, write_catalog
from novel.media import atomic_bytes
from conftest import synthetic_book


@pytest.fixture
def curated(tmp_path):
    library, data, curation = (tmp_path / name for name in ("library", "data", "curation"))
    for path in (library, data, curation / "banners"):
        path.mkdir(parents=True)
    config = Config(library_dir=library, data_dir=data, curation_dir=curation,
                    reload_check_seconds=0, public_base="https://static.example.test")
    return config


def write_tv(config):
    def item(book_id, season):
        return {"book_id": str(book_id), "season": season, "badge": "动画化", "studio": "Studio"}
    data = {"as_of": "2026-09-22", "upcoming": [
        item(1, "2026年秋"), item(2, "2027年"), item(3, "2025年"), item(4, ""),
        item(5, "剧场版"), item(6, "2026年冬"), item(7, "2027年春"), item(999, "2026年秋"),
    ], "completed": [item(8, "2012年"), item(9, "2028年秋")]}
    atomic_bytes(config.curation_dir / "tv.json", orjson.dumps(data))
    return data


def test_banners_sizes_transparency_replacement_and_removal(curated, caplog):
    config = curated
    Image.new("RGB", (2400, 800), "blue").save(config.curation_dir / "banners" / "large.jpg")
    Image.new("RGBA", (300, 100), (0, 0, 0, 0)).save(config.curation_dir / "banners" / "small.png")
    source = {"banners": [
        {"key": "large", "book_id": "1", "image": "large.jpg"},
        {"key": "small", "book_id": "2", "image": "small.png"},
        {"key": "INVALID", "book_id": "1", "image": "large.jpg"},
        {"key": "absent", "book_id": "1", "image": "missing.jpg"},
        {"key": "bad-path", "book_id": "1", "image": "../large.jpg"},
    ]}
    atomic_bytes(config.curation_dir / "banners.json", orjson.dumps(source))
    indexer = Indexer(config)
    indexer.run_once()
    catalog = Catalog.load(config)
    version = catalog.version
    stamp = config.catalog_path.stat().st_mtime_ns
    output = orjson.loads((config.data_dir / "banners.json").read_bytes())["banners"]
    assert [item["key"] for item in output] == ["large", "small"]
    for item in output:
        assert set(item) == {"key", "book_id", "hash"}
        for width in (1200, 600):
            with Image.open(config.data_dir / "banners" / f"{item['key']}-{item['hash']}-{width}.webp") as image:
                assert image.mode == "RGB" and image.format == "WEBP"
                assert image.size == ((width, width // 3) if item["key"] == "large" else (300, 100))
                if item["key"] == "small":
                    assert min(image.getpixel((0, 0))) >= 250
    old_hash = output[0]["hash"]
    Image.new("RGB", (1800, 600), "red").save(config.curation_dir / "banners" / "large.jpg")
    result = indexer.run_once()
    assert not result.rebuilt and Catalog.load(config).version == version
    assert config.catalog_path.stat().st_mtime_ns == stamp
    new = orjson.loads((config.data_dir / "banners.json").read_bytes())["banners"]
    assert new[0]["hash"] != old_hash
    assert not list((config.data_dir / "banners").glob(f"large-{old_hash}-*"))
    atomic_bytes(config.curation_dir / "banners.json", b'{"banners":[]}')
    indexer.run_once()
    assert not list((config.data_dir / "banners").iterdir())
    assert "Skipping invalid banner" in caplog.text and "Skipping banner absent" in caplog.text


def test_existing_banners_skip_decoding_and_encoding(curated, monkeypatch):
    config = curated
    Image.new("RGB", (1800, 600), "blue").save(config.curation_dir / "banners" / "banner.jpg")
    atomic_bytes(config.curation_dir / "banners.json", orjson.dumps({"banners": [
        {"key": "banner", "book_id": "1", "image": "banner.jpg"},
    ]}))
    indexer = Indexer(config)
    indexer.run_once()
    manifest = (config.data_dir / "banners.json").read_bytes()
    outputs = sorted((config.data_dir / "banners").glob("*.webp"))
    assert len(outputs) == 2
    for path in outputs:
        os.utime(path, ns=(1_700_000_000_000_000_000, 1_700_000_000_000_000_000))
    before = {path: (path.stat().st_mtime_ns, path.read_bytes()) for path in outputs}
    decode = Mock(wraps=curation.decode_rgb)
    encode = Mock(wraps=curation.write_images)
    monkeypatch.setattr(curation, "decode_rgb", decode)
    monkeypatch.setattr(curation, "write_images", encode)

    assert not indexer.run_once().rebuilt

    decode.assert_not_called()
    encode.assert_not_called()
    assert {path: (path.stat().st_mtime_ns, path.read_bytes()) for path in outputs} == before
    assert (config.data_dir / "banners.json").read_bytes() == manifest


@pytest.mark.parametrize("missing_width", [1200, 600])
def test_banner_regenerates_when_one_size_is_missing(curated, missing_width):
    config = curated
    Image.new("RGB", (1800, 600), "blue").save(config.curation_dir / "banners" / "banner.jpg")
    atomic_bytes(config.curation_dir / "banners.json", orjson.dumps({"banners": [
        {"key": "banner", "book_id": "1", "image": "banner.jpg"},
    ]}))
    sync_banners(config)
    manifest = (config.data_dir / "banners.json").read_bytes()
    key = orjson.loads(manifest)["banners"][0]["hash"]
    (config.data_dir / "banners" / f"banner-{key}-{missing_width}.webp").unlink()

    sync_banners(config)

    for width in (1200, 600):
        with Image.open(config.data_dir / "banners" / f"banner-{key}-{width}.webp") as image:
            assert image.format == "WEBP" and image.size == (width, width // 3)
    assert (config.data_dir / "banners.json").read_bytes() == manifest


def test_banner_api_order_and_combined_version(curated):
    config = curated
    books = {str(i): synthetic_book(i) for i in range(1, 4)}
    write_catalog(config.catalog_path, books)
    manifest = {"banners": [
        {"key": "second", "book_id": "2", "hash": "abcdef123456"},
        {"key": "first", "book_id": "1", "hash": "123456abcdef"},
        {"key": "unknown", "book_id": "999", "hash": "abcdef123456"},
    ]}
    raw = orjson.dumps(manifest)
    atomic_bytes(config.data_dir / "banners.json", raw)
    tv_bytes = orjson.dumps({"upcoming": [], "completed": []})
    atomic_bytes(config.curation_dir / "tv.json", tv_bytes)
    with TestClient(create_app(config)) as client:
        banners = client.get("/api/v1/home").json()["banners"]
        assert [banner["key"] for banner in banners] == ["second", "first"]
        assert set(banners[0]) == {"key", "image", "image_small", "book"}
        assert banners[0]["book"]["id"] == "2"
        assert banners[0]["image"] == "https://static.example.test/banners/second-abcdef123456-1200.webp"
        assert banners[0]["image_small"].endswith("second-abcdef123456-600.webp")
        meta = client.get("/api/v1/meta").json()
        assert meta["content_version"] == meta["version"] + "." + hashlib.sha1(raw + tv_bytes).hexdigest()[:8]


@pytest.mark.parametrize(("today", "airing", "upcoming", "completed"), [
    ("2026-08-01", [], ["1", "2", "4", "5", "7"], ["3", "6", "8", "9"]),
    ("2026-10-01", ["1"], ["2", "4", "5", "7"], ["3", "6", "8", "9"]),
    ("2027-01-01", [], ["2", "4", "5", "7"], ["1", "3", "6", "8", "9"]),
    ("2027-12-31", [], ["2", "4", "5"], ["1", "3", "6", "7", "8", "9"]),
    ("2028-01-01", [], ["4", "5"], ["1", "2", "3", "6", "7", "8", "9"]),
])
def test_tv_status_order_and_detail(curated, today, airing, upcoming, completed):
    config = curated
    write_catalog(config.catalog_path, {str(i): synthetic_book(i) for i in range(1, 11)})
    write_tv(config)
    with TestClient(create_app(config, date_provider=lambda: today)) as client:
        for section, expected in (("airing", airing), ("upcoming", upcoming), ("completed", completed)):
            data = client.get("/api/v1/tv", params={"section": section}).json()
            assert data["section"] == section and data["total"] == len(expected)
            assert [item["id"] for item in data["items"]] == expected
            assert all(item["tv_status"] == section for item in data["items"])
        detail = client.get("/api/v1/books/1").json()["tv"]
        assert set(detail) == {"season", "badge", "studio", "tv_status"}
        assert detail["tv_status"] == ("airing" if "1" in airing else "upcoming" if "1" in upcoming else "completed")
        assert client.get("/api/v1/books/10").json()["tv"] is None
        assert client.get("/api/v1/tv?section=completed&offset=999").json()["items"] == []
        assert [item["id"] for item in client.get("/api/v1/tv?section=completed&offset=1&limit=2").json()["items"]] == completed[1:3]


def test_tv_date_etag_and_home_exclusion_exceptions(curated):
    config = curated
    write_catalog(config.catalog_path, {"1": synthetic_book(1)})
    write_tv(config)
    with TestClient(create_app(config, date_provider=lambda: "2026-08-01")) as client:
        before = client.get("/api/v1/tv?section=upcoming")
        client.app.state.date_provider = lambda: "2026-10-01"
        after = client.get("/api/v1/tv?section=upcoming", headers={"If-None-Match": before.headers["etag"]})
        assert after.status_code == 200 and after.headers["etag"] != before.headers["etag"]
        assert before.json()["total"] == 1 and after.json()["total"] == 0
        sections = {section["key"]: section["items"] for section in client.get("/api/v1/home").json()["sections"]}
        assert [item["id"] for item in sections["featured"]] == ["1"]
        assert sections["rank"] == []
        assert [item["id"] for item in sections["tv"]] == ["1"]
        assert sections["rank"] == [] and sections["tv"][0]["tv_status"] == "airing"
        assert all(not sections[key] for key in ("picks", "recent", "completed", "long"))


def test_detail_date_changes_tv_status_cache_and_etag(curated):
    write_catalog(curated.catalog_path, {"1": synthetic_book(1)})
    write_tv(curated)
    with TestClient(create_app(curated, date_provider=lambda: "2026-09-30")) as client:
        previous = None
        version = client.get("/api/v1/meta").json()["content_version"]
        for today, status in (("2026-09-30", "upcoming"), ("2026-10-01", "airing"), ("2027-01-01", "completed")):
            client.app.state.date_provider = lambda: today
            response = client.get("/api/v1/books/1", headers={"If-None-Match": previous} if previous else {})
            assert response.status_code == 200 and response.json()["tv"]["tv_status"] == status
            normalized = "/api/v1/books/1#" + today
            digest = hashlib.sha1(normalized.encode()).hexdigest()[:16]
            assert response.headers["etag"] == f'W/"{version}-{digest}"'
            assert client.app.state.responses.get((version, normalized)) == response.content
            previous = response.headers["etag"]
            assert client.get("/api/v1/books/1", headers={"If-None-Match": previous}).status_code == 304


@pytest.mark.parametrize("filename", ["tv.json", "banners.json"])
def test_curation_alone_triggers_reload(curated, filename):
    config = curated
    write_catalog(config.catalog_path, {"1": synthetic_book(1)})
    with TestClient(create_app(config, date_provider=lambda: "2026-10-17")) as client:
        old = client.get("/api/v1/meta").json()
        if filename == "tv.json":
            write_tv(config)
        else:
            atomic_bytes(config.data_dir / filename, orjson.dumps({"banners": [
                {"key": "new", "book_id": "1", "hash": "123456abcdef"}]}))
        client.get("/api/v1/meta")
        client.app.state.store.future.result(timeout=5)
        new = client.get("/api/v1/meta").json()
        assert old["version"] == new["version"] and old["content_version"] != new["content_version"]
        home = client.get("/api/v1/home").json()
        assert home["banners"] if filename == "banners.json" else home["sections"][4]["items"]


@pytest.mark.parametrize("content", [b"broken", b"[]", b'{"upcoming":"bad","completed":[]}'])
def test_invalid_curation_is_ignored(curated, content, caplog):
    path = curated.curation_dir / "tv.json"
    path.write_bytes(content)
    data, raw = read_tv(path)
    assert data == {"upcoming": [], "completed": []} and raw == content
    assert caplog.records


def test_invalid_tv_entry_does_not_hide_valid_entries(curated, caplog):
    data = write_tv(curated)
    data["upcoming"].extend([None, {"book_id": 1}, {"book_id": "1", "season": "2026年雨", "badge": "", "studio": ""}])
    atomic_bytes(curated.curation_dir / "tv.json", orjson.dumps(data))
    tv, _ = read_tv(curated.curation_dir / "tv.json")
    assert len(tv["upcoming"]) == 8 and len(tv["completed"]) == 2
    assert "Skipping invalid TV entry" in caplog.text


@pytest.mark.parametrize("url", ["/api/v1/tv", "/api/v1/tv?section=bad", "/api/v1/tv?section=airing&limit=0",
                                    "/api/v1/rank", "/api/v1/rank?period=bad", "/api/v1/rank?period=week&limit=61"])
def test_new_endpoint_validation(curated, url):
    with TestClient(create_app(curated)) as client:
        response = client.get(url)
        assert response.status_code == 400 and response.headers["cache-control"] == "no-store"
        assert "etag" not in response.headers


def test_home_tv_takes_first_twelve_in_section_order(curated):
    config = curated
    write_catalog(config.catalog_path, {str(i): synthetic_book(i) for i in range(1, 17)})
    entries = [{"book_id": str(i), "season": "2026年秋" if i <= 6 else "2027年", "badge": "", "studio": ""}
               for i in range(1, 17)]
    atomic_bytes(config.curation_dir / "tv.json", orjson.dumps({"upcoming": entries[:10], "completed": entries[10:]}))
    with TestClient(create_app(config, date_provider=lambda: "2026-10-17")) as client:
        items = client.get("/api/v1/home").json()["sections"][4]["items"]
        assert [item["id"] for item in items] == [str(i) for i in range(1, 13)]
        assert [item["tv_status"] for item in items] == ["airing"] * 6 + ["upcoming"] * 4 + ["completed"] * 2


def test_server_error_responses_are_not_cacheable(curated):
    from starlette.responses import Response
    app = create_app(curated)

    @app.get("/api/v1/test-error")
    async def error():
        return Response(b'{}', status_code=500, headers={"ETag": '"bad"', "Cache-Control": "public"})

    with TestClient(app) as client:
        response = client.get("/api/v1/test-error")
        assert response.status_code == 500 and response.headers["cache-control"] == "no-store"
        assert "etag" not in response.headers


@pytest.mark.parametrize("failure", ["route", "middleware"])
def test_unhandled_error_responses_are_not_cacheable(curated, monkeypatch, failure):
    app = create_app(curated)

    @app.get("/api/v1/test-error")
    async def error():
        raise RuntimeError("unexpected failure")

    with TestClient(app, raise_server_exceptions=False) as client:
        if failure == "middleware":
            def fail():
                raise RuntimeError("unexpected middleware failure")
            monkeypatch.setattr(app.state.store, "snapshot", fail)
        response = client.get("/api/v1/test-error")
        assert response.status_code == 500 and response.headers["cache-control"] == "no-store"
        assert "etag" not in response.headers
        assert response.headers["content-type"] == "application/json"
        assert response.content == b'{"error":{"code":"internal","message":"Internal error"}}'
