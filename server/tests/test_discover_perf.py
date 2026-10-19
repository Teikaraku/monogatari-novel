import random
import time

import orjson
import pytest
from fastapi.testclient import TestClient

from novel.api import create_app
from novel.config import Config
from novel.indexer import write_catalog
from conftest import synthetic_book
from test_rank import write_stats


@pytest.mark.perf
def test_discover_and_tag_preview_first_requests(tmp_path, pytestconfig):
    curation = tmp_path / "curation"
    curation.mkdir()
    config = Config(data_dir=tmp_path, curation_dir=curation)
    rng = random.Random(5101)
    vocabulary = [f"分类{i}" for i in range(16)]
    books = {}
    for i in range(1, 5102):
        volumes = [{"n": n, "label": f"第{n}卷", "file": f"{n}_fixture.epub", "size": 10, "mtime": 1700000000}
                   for n in range(1, (4 if i <= 3705 else 3) + 1)]
        books[str(i)] = synthetic_book(i, tags=rng.sample(vocabulary, 4), volume_list=volumes,
                                       description=("机翻说明。" if i % 19 == 0 else "") + "故事简介" * 50,
                                       cover_key="0123456789ab" if i % 8 else "")
    themes = [{"key": f"theme-{i}", "title": f"主题{i}", "match": "all" if i % 2 else "any",
               "tags": [vocabulary[i], vocabulary[(i + 1) % 16]]} for i in range(16)]
    (curation / "themes.json").write_bytes(orjson.dumps({"themes": themes}))
    write_catalog(config.catalog_path, books)
    write_stats(config, totals=[(key, i % 500) for i, key in enumerate(books)])
    with TestClient(create_app(config, date_provider=lambda: "2026-10-17")) as client:
        assert len(client.app.state.store.catalog.books) == 5101
        assert len(client.app.state.store.catalog.themes) == 16
        start = time.perf_counter()
        discover = client.get("/api/v1/discover")
        discover_ms = (time.perf_counter() - start) * 1000
        start = time.perf_counter()
        tags = client.get("/api/v1/tags?covers=4")
        tags_ms = (time.perf_counter() - start) * 1000
    metrics = getattr(pytestconfig, "performance_metrics", {})
    metrics["discover first request, 5101 books / 16 themes"] = f"{discover_ms:.6f} ms (< 50 ms)"
    metrics["tags covers=4 first request, 5101 books"] = f"{tags_ms:.6f} ms (< 50 ms)"
    pytestconfig.performance_metrics = metrics
    assert discover.status_code == tags.status_code == 200
    assert discover.json()["pick"] is not None and len(discover.json()["themes"]) == 6
    assert all(len(entry["items"]) == 10 for entry in discover.json()["themes"])
    assert len(tags.json()["tags"]) == 16 and all(len(entry["covers"]) == 4 for entry in tags.json()["tags"])
    assert discover_ms < 50 and tags_ms < 50
