import hashlib

import pytest
from fastapi.testclient import TestClient

from novel.api import create_app
from novel.config import Config
from novel.indexer import write_catalog
from conftest import synthetic_book


@pytest.fixture
def books_client(tmp_path):
    config = Config(data_dir=tmp_path)
    books = {str(i): synthetic_book(i, volume_count=count, tags=["共同", "奇数" if i % 2 else "偶数"],
                                   status="completed" if i % 2 else "ongoing", description="🙂汉字" * 40)
             for i, count in enumerate((1, 2, 3, 4, 9999), 1)}
    write_catalog(config.catalog_path, books)
    with TestClient(create_app(config)) as client:
        yield client


@pytest.mark.parametrize(("params", "ids"), [
    ({}, [5, 4, 3, 2, 1]), ({"min_volumes": 2}, [5, 4, 3, 2]), ({"max_volumes": 3}, [3, 2, 1]),
    ({"min_volumes": 2, "max_volumes": 3}, [3, 2]), ({"min_volumes": 2, "max_volumes": 2}, [2]),
    ({"min_volumes": 1, "max_volumes": 1}, [1]), ({"min_volumes": 9999, "max_volumes": 9999}, [5]),
    ({"min_volumes": 5, "max_volumes": 9998}, []),
    ({"min_volumes": 2, "max_volumes": 4, "tag": "奇数", "status": "completed"}, [3]),
])
def test_volume_ranges_are_inclusive(books_client, params, ids):
    response = books_client.get("/api/v1/books", params=params)
    assert response.status_code == 200
    assert response.json()["total"] == len(ids)
    assert [item["id"] for item in response.json()["items"]] == [str(i) for i in ids]


@pytest.mark.parametrize("params", [
    {name: value} for name in ("min_volumes", "max_volumes") for value in (0, -1, 10000, "1.5", "bad", "")
] + [{"min_volumes": 3, "max_volumes": 2}] + [
    {"with_description": value} for value in ("2", "-1", "true", "", "1.0")
])
def test_invalid_book_extensions_are_not_cacheable(books_client, params):
    response = books_client.get("/api/v1/books", params=params)
    assert response.status_code == 400 and response.json()["error"]["code"] == "bad_request"
    assert response.headers["cache-control"] == "no-store" and "etag" not in response.headers


def test_description_is_character_limited_and_does_not_mutate_summaries(books_client):
    response = books_client.get("/api/v1/books?with_description=1&offset=1&limit=2")
    assert response.json()["total"] == 5 and len(response.json()["items"]) == 2
    assert all(item["description"] == ("🙂汉字" * 40)[:80] for item in response.json()["items"])
    assert all("description" not in item for item in books_client.get("/api/v1/books?with_description=0").json()["items"])
    assert all("description" not in item for item in books_client.get("/api/v1/books").json()["items"])
    assert books_client.get("/api/v1/books/1").json()["description"] == "🙂汉字" * 40
    assert books_client.get("/api/v1/books?min_volumes=2&max_volumes=3&offset=2").json()["items"] == []


def test_random_cache_distinguishes_both_volume_bounds(books_client):
    queries = [(1, 9999, {"1", "2", "3", "4", "5"}), (2, 9999, {"2", "3", "4", "5"}),
               (2, 3, {"2", "3"}), (1, 3, {"1", "2", "3"})]
    for lower, upper, expected in queries * 2:
        params = {"sort": "random", "seed": 42, "min_volumes": lower, "max_volumes": upper}
        full = books_client.get("/api/v1/books", params=params).json()
        assert {item["id"] for item in full["items"]} == expected and full["total"] == len(expected)
        pages = [books_client.get("/api/v1/books", params={**params, "limit": 1, "offset": i}).json()["items"][0]
                 for i in range(len(expected))]
        assert pages == full["items"]
        described = books_client.get("/api/v1/books", params={**params, "with_description": 1}).json()
        assert [item["id"] for item in described["items"]] == [item["id"] for item in full["items"]]


def test_extensions_participate_in_response_cache_and_etag(books_client):
    version = books_client.get("/api/v1/meta").json()["content_version"]
    etags = set()
    for query in ("max_volumes=4&min_volumes=2", "max_volumes=3&min_volumes=2",
                  "max_volumes=4&min_volumes=2&with_description=1"):
        normalized = "/api/v1/books?" + query
        response = books_client.get(normalized)
        digest = hashlib.sha1(normalized.encode()).hexdigest()[:16]
        assert response.headers["etag"] == f'W/"{version}-{digest}"'
        assert books_client.app.state.responses.get((version, normalized)) == response.content
        assert books_client.get(normalized, headers={"If-None-Match": response.headers["etag"]}).status_code == 304
        etags.add(response.headers["etag"])
    assert len(etags) == 3
