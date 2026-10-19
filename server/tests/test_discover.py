import hashlib
import random

import orjson
import pytest
from fastapi.testclient import TestClient

from novel.api import create_app
from novel.catalog import Catalog
from novel.config import Config
from novel.curation import read_themes
from novel.indexer import write_catalog
from novel.media import atomic_bytes
from conftest import synthetic_book


@pytest.fixture
def theme_config(tmp_path):
    curation = tmp_path / "curation"
    curation.mkdir()
    return Config(data_dir=tmp_path, curation_dir=curation, reload_check_seconds=0)


def write_themes(config, themes):
    raw = orjson.dumps({"themes": themes})
    atomic_bytes(config.curation_dir / "themes.json", raw)
    return raw


def theme(key="theme", tags=None, match="all", title="主题"):
    return {"key": key, "title": title, "match": match, "tags": tags if tags is not None else ["校园"]}


def test_discover_and_theme_all_any_matching_without_exclusion(theme_config):
    books = {
        "1": synthetic_book(1, tags=["校园", "恋爱"], description="完整简介" * 50),
        "2": synthetic_book(2, tags=["校园"], description="短简介"),
        "3": synthetic_book(3, tags=["恋爱", "魔法"], description="短简介"),
        "4": synthetic_book(4, tags=["校园", "恋爱"], cover_key=""),
        "5": synthetic_book(5, tags=["其他"], description="短简介"),
    }
    write_catalog(theme_config.catalog_path, books)
    write_themes(theme_config, [theme("all", ["校园", "恋爱"]), theme("any", ["校园", "恋爱"], "any"),
                                theme("empty", ["未知"])])
    with TestClient(create_app(theme_config, date_provider=lambda: "2026-10-17")) as client:
        result = client.get("/api/v1/discover").json()
        assert set(result) == {"version", "date", "pick", "themes"}
        assert result["pick"]["id"] == "1" and result["pick"]["description"] == ("完整简介" * 50)[:160]
        themes = {entry["key"]: entry for entry in result["themes"]}
        assert set(themes) == {"all", "any"}
        for key, ids in (("all", {"1"}), ("any", {"1", "2", "3"})):
            assert themes[key]["total"] == len(ids)
            assert {item["id"] for item in themes[key]["items"]} == ids
            assert set(themes[key]) == {"key", "title", "tags", "total", "items"}
            assert all("description" not in item for item in themes[key]["items"])
            detail = client.get("/api/v1/themes/" + key).json()
            assert {item["id"] for item in detail["items"]} == ids
        empty = client.get("/api/v1/themes/empty")
        assert empty.status_code == 200 and empty.json()["total"] == 0 and empty.json()["items"] == []


@pytest.mark.parametrize("overrides", [
    {"cover_key": ""}, {"volume_count": 1}, {"description": "文" * 59},
    *[{"description": "文" * 80 + word + "文" * 100} for word in ("机翻", "机润", "润色", "请返回", "介意者", "语言模型")],
])
def test_discover_pick_eligibility(theme_config, overrides):
    catalog = Catalog(theme_config, {"version": "test"}, {"1": synthetic_book(1, **overrides)})
    assert catalog.discover("2026-10-17")["pick"] is None


@pytest.mark.parametrize("description", ["文" * 60, "文" * 120 + "机翻", "文" * 117 + "语言模型", "🙂" * 200])
def test_discover_pick_boundaries_and_character_truncation(theme_config, description):
    catalog = Catalog(theme_config, {}, {"1": synthetic_book(1, description=description)})
    assert catalog.discover("2026-10-17")["pick"]["description"] == description[:160]
    assert catalog.books["1"]["description"] == description


def test_discover_daily_sampling_etag_and_restart_stability(theme_config):
    books = {str(i): synthetic_book(i) for i in range(1, 41)}
    themes = [theme(f"theme-{i}", title=f"主题{i}") for i in range(16)]
    write_catalog(theme_config.catalog_path, books)
    write_themes(theme_config, themes)
    with TestClient(create_app(theme_config, date_provider=lambda: "2026-10-17")) as client:
        first = client.get("/api/v1/discover")
        data = first.json()
        assert len(data["themes"]) == 6
        expected = random.Random(f"{data['version']}:2026-10-17:themes").sample(themes, 6)
        assert [entry["key"] for entry in data["themes"]] == [entry["key"] for entry in expected]
        assert all(entry["total"] == 40 and len(entry["items"]) == 10 for entry in data["themes"])
        ids = [str(i) for i in range(40, 0, -1)]
        assert data["pick"]["id"] == random.Random(f"{data['version']}:2026-10-17:pick").choice(ids)
        for entry in data["themes"]:
            expected_ids = random.Random(f"{data['version']}:2026-10-17:theme:{entry['key']}").sample(ids, 10)
            assert [item["id"] for item in entry["items"]] == expected_ids
        assert client.get("/api/v1/discover").content == first.content
        assert client.get("/api/v1/discover", headers={"If-None-Match": first.headers["etag"]}).status_code == 304
        assert Catalog.load(theme_config).discover("2026-10-17") == data
        client.app.state.date_provider = lambda: "2026-10-18"
        second = client.get("/api/v1/discover", headers={"If-None-Match": first.headers["etag"]})
        assert second.status_code == 200 and second.json()["date"] == "2026-10-18"
        assert second.json()["themes"] != data["themes"]
        assert second.headers["etag"] != first.headers["etag"]
        version = client.get("/api/v1/meta").json()["content_version"]
        for day, response in (("2026-10-17", first), ("2026-10-18", second)):
            normalized = "/api/v1/discover#" + day
            digest = hashlib.sha1(normalized.encode()).hexdigest()[:16]
            assert response.headers["etag"] == f'W/"{version}-{digest}"'
            assert client.app.state.responses.get((version, normalized)) == response.content


@pytest.mark.parametrize("content", [None, b"broken", b"[]", b"null", b"\xff", b'{"themes":{}}'])
def test_missing_or_broken_theme_file_leaves_other_features_working(theme_config, content, caplog):
    write_catalog(theme_config.catalog_path, {"1": synthetic_book(1)})
    if content is not None:
        (theme_config.curation_dir / "themes.json").write_bytes(content)
    with TestClient(create_app(theme_config)) as client:
        data = client.get("/api/v1/discover").json()
        assert data["themes"] == [] and data["pick"]["id"] == "1"
        missing = client.get("/api/v1/themes/missing")
        assert missing.status_code == 404 and missing.headers["cache-control"] == "no-store"
        assert "etag" not in missing.headers
        assert client.get("/api/v1/books").json()["total"] == 1
    assert "themes.json" in caplog.text


@pytest.mark.parametrize("invalid", [
    None, [], {}, theme(key=""), theme(key="UPPER"), theme(key="a" * 33), theme(key="has/slash"),
    theme(key=3), theme(title=""), theme(title=None), theme(match="both"), theme(match=[]),
    theme(tags=[]), theme(tags=["x"] * 6), theme(tags=[""]), theme(tags=["校园", 3]), theme(tags="校园"),
])
def test_invalid_theme_entries_are_skipped(theme_config, invalid, caplog):
    valid = theme(key="a" * 32, tags=["一", "二", "三", "四", "五"], match="any")
    raw = write_themes(theme_config, [invalid, valid])
    parsed, content = read_themes(theme_config.curation_dir / "themes.json")
    assert parsed == [valid] and content == raw
    assert "Skipping invalid theme entry" in caplog.text


def test_duplicate_theme_keys_keep_first_and_warn_for_each_duplicate(theme_config, caplog):
    first = theme(tags=["校园", "恋爱"], title="首个主题")
    other = theme(key="other", tags=["冒险"])
    duplicate = theme(tags=["校园", "冒险"], match="any", title="重复主题")
    raw = write_themes(theme_config, [first, other, duplicate, first])
    path = theme_config.curation_dir / "themes.json"

    parsed, content = read_themes(path)

    assert parsed == [first, other] and content == raw
    warnings = [record for record in caplog.records if "duplicate theme key" in record.getMessage()]
    assert len(warnings) == 2
    assert all(record.levelname == "WARNING" and "theme" in record.getMessage()
               and str(path) in record.getMessage() for record in warnings)


@pytest.mark.parametrize("reload", [False, True])
def test_duplicate_theme_keys_work_in_detail_and_discover(theme_config, reload):
    write_catalog(theme_config.catalog_path, {
        "1": synthetic_book(1, tags=["校园", "恋爱"]),
        "2": synthetic_book(2, tags=["校园"]),
        "3": synthetic_book(3, tags=["冒险"]),
    })
    first = theme(tags=["校园", "恋爱"], title="首个主题")
    themes = [first, theme(key="other", tags=["冒险"]),
              theme(tags=["校园", "冒险"], match="any", title="重复主题")]
    write_themes(theme_config, [theme(tags=["冒险"])] if reload else themes)
    with TestClient(create_app(theme_config)) as client:
        headers = {}
        if reload:
            before = client.get("/api/v1/themes/theme")
            assert [item["id"] for item in before.json()["items"]] == ["3"]
            write_themes(theme_config, themes)
            client.get("/api/v1/themes/theme")
            client.app.state.store.future.result(timeout=5)
            headers = {"If-None-Match": before.headers["etag"]}
        response = client.get("/api/v1/themes/theme", headers=headers)
        assert response.status_code == 200
        detail = response.json()
        assert detail["title"] == first["title"] and detail["tags"] == first["tags"]
        assert detail["total"] == 1 and [item["id"] for item in detail["items"]] == ["1"]
        assert client.get("/api/v1/themes/theme", headers={"If-None-Match": response.headers["etag"]}).status_code == 304
        discovered = client.get("/api/v1/discover").json()["themes"]
        assert len(discovered) == 2 and {entry["key"] for entry in discovered} == {"theme", "other"}
        entry = next(entry for entry in discovered if entry["key"] == "theme")
        assert entry["title"] == first["title"] and entry["tags"] == first["tags"]
        assert entry["total"] == 1 and [item["id"] for item in entry["items"]] == ["1"]


def test_theme_file_creation_change_corruption_and_removal_reload(theme_config):
    write_catalog(theme_config.catalog_path, {"1": synthetic_book(1)})
    original = theme_config.catalog_path.read_bytes()
    with TestClient(create_app(theme_config, date_provider=lambda: "2026-10-17")) as client:
        previous_meta = client.get("/api/v1/meta").json()
        previous = client.get("/api/v1/discover")
        for content, title in ((orjson.dumps({"themes": [theme(title="旧标题")]}), "旧标题"),
                               (orjson.dumps({"themes": [theme(title="新标题")]}), "新标题"),
                               (b"broken", None), (orjson.dumps({"themes": [theme()]}), "主题"), (None, None)):
            path = theme_config.curation_dir / "themes.json"
            if content is None:
                path.unlink()
            else:
                atomic_bytes(path, content)
            client.get("/api/v1/discover")
            client.app.state.store.future.result(timeout=5)
            response = client.get("/api/v1/discover", headers={"If-None-Match": previous.headers["etag"]})
            assert response.status_code == 200 and response.headers["etag"] != previous.headers["etag"]
            data = response.json()
            assert [item["title"] for item in data["themes"]] == ([title] if title else [])
            detail = client.get("/api/v1/themes/theme")
            assert detail.status_code == (200 if title else 404)
            if title:
                assert detail.json()["title"] == title
            meta = client.get("/api/v1/meta").json()
            assert meta["version"] == previous_meta["version"]
            assert meta["content_version"] == meta["version"] + "." + hashlib.sha1(content or b"").hexdigest()[:8]
            previous = response
    assert theme_config.catalog_path.read_bytes() == original


def test_discover_empty_catalog(theme_config):
    write_themes(theme_config, [theme()])
    with TestClient(create_app(theme_config)) as client:
        data = client.get("/api/v1/discover").json()
        assert data["version"] == "" and data["pick"] is None and data["themes"] == []
        assert client.get("/api/v1/themes/theme").json()["total"] == 0


def test_combined_version_includes_all_curation_files_and_stats(theme_config):
    from test_rank import write_stats
    write_catalog(theme_config.catalog_path, {"1": synthetic_book(1)})
    banner_bytes = b'{"banners":[]}'
    tv_bytes = b'{"upcoming":[],"completed":[]}'
    (theme_config.data_dir / "banners.json").write_bytes(banner_bytes)
    (theme_config.curation_dir / "tv.json").write_bytes(tv_bytes)
    theme_bytes = write_themes(theme_config, [theme()])
    write_stats(theme_config, totals=[("1", 1)], version="7")
    with TestClient(create_app(theme_config, date_provider=lambda: "2026-10-17")) as client:
        meta = client.get("/api/v1/meta").json()
        expected = meta["version"] + "." + hashlib.sha1(banner_bytes + tv_bytes + theme_bytes).hexdigest()[:8] + ".7"
        assert meta["content_version"] == expected
        response = client.get("/api/v1/discover")
        digest = hashlib.sha1(b"/api/v1/discover#2026-10-17").hexdigest()[:16]
        assert response.headers["etag"] == f'W/"{expected}-{digest}"'


def test_theme_candidate_reload_invalidates_random_cache(theme_config):
    write_catalog(theme_config.catalog_path, {"1": synthetic_book(1, tags=["校园"]),
                                             "2": synthetic_book(2, tags=["恋爱"])})
    write_themes(theme_config, [theme()])
    url = "/api/v1/themes/theme?sort=random&seed=1"
    with TestClient(create_app(theme_config)) as client:
        before = client.get(url)
        assert [item["id"] for item in before.json()["items"]] == ["1"]
        write_themes(theme_config, [theme(tags=["恋爱"])])
        client.get(url)
        client.app.state.store.future.result(timeout=5)
        after = client.get(url, headers={"If-None-Match": before.headers["etag"]})
        assert after.status_code == 200 and [item["id"] for item in after.json()["items"]] == ["2"]
        assert [item["id"] for item in client.get("/api/v1/discover").json()["themes"][0]["items"]] == ["2"]


@pytest.mark.parametrize(("sort", "expected"), [
    ("updated", [2, 1, 3]), ("title", [3, 2, 1]), ("words", [1, 3, 2]), ("volumes", [3, 2, 1]),
])
def test_theme_pagination_and_sorting(theme_config, sort, expected):
    books = {"1": synthetic_book(1, updated="2026-01-01", words=300, volume_count=2, sort_title="c"),
             "2": synthetic_book(2, updated="2026-01-01", words=100, volume_count=3, sort_title="b"),
             "3": synthetic_book(3, updated="2025-01-01", words=200, volume_count=4, sort_title="a"),
             "4": synthetic_book(4, cover_key=""), "5": synthetic_book(5, tags=["其他"])}
    write_catalog(theme_config.catalog_path, books)
    write_themes(theme_config, [theme()])
    with TestClient(create_app(theme_config)) as client:
        data = client.get("/api/v1/themes/theme", params={"sort": sort}).json()
        assert set(data) == {"key", "title", "tags", "total", "offset", "limit", "items"}
        assert data["key"] == "theme" and data["title"] == "主题" and data["tags"] == ["校园"]
        assert data["total"] == 3 and [item["id"] for item in data["items"]] == [str(i) for i in expected]
        page = client.get("/api/v1/themes/theme", params={"sort": sort, "offset": 1, "limit": 1}).json()
        assert page["total"] == 3 and page["offset"] == page["limit"] == 1
        assert page["items"] == data["items"][1:2]
        assert client.get("/api/v1/themes/theme?offset=3").json()["items"] == []
        missing = client.get("/api/v1/themes/UNKNOWN")
        assert missing.status_code == 404 and missing.json()["error"]["code"] == "not_found"


def test_theme_random_pages_and_cache_isolation(theme_config):
    books = {str(i): synthetic_book(i, tags=["校园", "恋爱"] if i <= 12 else ["校园"]) for i in range(1, 25)}
    write_catalog(theme_config.catalog_path, books)
    write_themes(theme_config, [theme(), theme("love", ["恋爱"])])
    with TestClient(create_app(theme_config)) as client:
        seeds = (0, 2**31 - 1)
        result = {}
        for key, expected in (("theme", 24), ("love", 12)):
            for seed in seeds:
                params = {"sort": "random", "seed": seed}
                url = "/api/v1/themes/" + key
                response = client.get(url, params=params)
                data = response.json()
                assert data["total"] == expected
                first = client.get(url, params={**params, "limit": 5}).json()["items"]
                rest = client.get(url, params={**params, "offset": 5}).json()["items"]
                assert first + rest == data["items"]
                assert client.get(url, params=params).json() == data
                assert client.get(url, params=params, headers={"If-None-Match": response.headers["etag"]}).status_code == 304
                result[key, seed] = [item["id"] for item in data["items"]]
                if key == "love":
                    assert set(result[key, seed]) == {str(i) for i in range(1, 13)}
            assert result[key, seeds[0]] != result[key, seeds[1]]
        assert client.get("/api/v1/books?sort=random&seed=0").json()["total"] == 24


@pytest.mark.parametrize("query", ["sort=bad", "sort=random", "sort=random&seed=-1", "sort=random&seed=2147483648",
                                    "sort=random&seed=x", "limit=0", "limit=61", "offset=-1"])
def test_theme_parameter_validation(theme_config, query):
    write_themes(theme_config, [theme()])
    with TestClient(create_app(theme_config)) as client:
        response = client.get("/api/v1/themes/theme?" + query)
        assert response.status_code == 400 and response.headers["cache-control"] == "no-store"
        assert "etag" not in response.headers
