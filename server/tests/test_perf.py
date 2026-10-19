import math
import random
import sqlite3
import time

import orjson
import pytest

from novel.catalog import Catalog
from novel.config import Config
from novel.indexer import SCHEMA


def p95(samples):
    return sorted(samples)[math.ceil(len(samples) * 0.95) - 1] * 1000


@pytest.mark.perf
def test_catalog_performance(tmp_path, pytestconfig):
    config = Config(data_dir=tmp_path)
    vocabulary = ["校园", "魔法", "恋爱", "冒险", "青春", "王国", "星空", "旅行", "谜团", "竞技", "公主", "骑士"]
    rng = random.Random(5101)
    books = []
    volumes = []
    for i in range(5101):
        tokens = rng.sample(vocabulary, 4)
        count = 4 if i < 3705 else 3
        title = f"{tokens[0]}与{tokens[1]}的故事{i}"
        books.append((str(i + 1), title, f"作家{i % 100}号", f"插画师{i % 70}", f"文库{i % 20}",
                      "completed" if i % 2 else "ongoing", i * 1500, i % 120, f"2024-{i % 12 + 1:02d}-{i % 28 + 1:02d}",
                      "故事描述" * 30, orjson.dumps(tokens).decode(), count, "abcdef123456",
                      f"xiao shuo {i}", f"xiaoshuo{i}", f"xs{i}", "2024-01-01"))
        volumes.extend((str(i + 1), n, f"{tokens[2]}中的{tokens[3]} 第{n}卷", f"{n}_story.epub", 1000000, 1700000000)
                       for n in range(1, count + 1))
    assert len(books) == 5101 and len(volumes) == 19008
    connection = sqlite3.connect(config.catalog_path)
    try:
        connection.executescript(SCHEMA)
        connection.executemany("INSERT INTO books VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", books)
        connection.executemany("INSERT INTO volumes VALUES (?,?,?,?,?,?)", volumes)
        connection.executemany("INSERT INTO meta VALUES (?,?)", [
            ("version", "20261017000000-perftest"), ("built_at", "2026-10-17T00:00:00+00:00"),
            ("book_count", "5101"), ("volume_count", "19008"),
        ])
        connection.commit()
    finally:
        connection.close()
    start = time.perf_counter()
    catalog = Catalog.load(config)
    load_seconds = time.perf_counter() - start
    assert catalog.meta["books"] == 5101 and catalog.meta["volumes"] == 19008
    terms = vocabulary + ["xs", "xiaoshuo", "作家", "插画师", "文库", "不存在", "魔法 校园", "星空 骑士"]
    search_samples = []
    for _ in range(200):
        term = rng.choice(terms)
        start = time.perf_counter()
        catalog.search(term)
        search_samples.append(time.perf_counter() - start)
    listing_samples = []
    for i in range(200):
        sort = ("updated", "title", "words", "volumes", "random")[i % 5]
        tags = [vocabulary[i % len(vocabulary)]] if i % 2 else []
        start = time.perf_counter()
        catalog.listing(tags=tags, sort=sort, seed=i, offset=i, use_cache=False)
        listing_samples.append(time.perf_counter() - start)
    search_p95 = p95(search_samples)
    listing_p95 = p95(listing_samples)
    metrics = getattr(pytestconfig, "performance_metrics", {})
    metrics.update({
        "load": f"{load_seconds:.6f} s (< 2 s)",
        "search 200 requests, p95, no LRU": f"{search_p95:.6f} ms (< 15 ms)",
        "books 200 requests, p95, no LRU": f"{listing_p95:.6f} ms (< 5 ms)",
    })
    pytestconfig.performance_metrics = metrics
    assert load_seconds < 2
    assert search_p95 < 15
    assert listing_p95 < 5
