import pytest
from fastapi.testclient import TestClient

from novel.api import create_app
from novel.catalog import Catalog
from novel.config import Config
from novel.indexer import write_catalog
from conftest import synthetic_book


def ids(result):
    return [item["id"] for item in result["items"]]


def test_scores_100_through_40_and_numeric_ties(tmp_path):
    books = {
        "1": synthetic_book(1, title="Magic", author="magic"),
        "2": synthetic_book(2, title="magic story"),
        "3": synthetic_book(3, title="a magic story"),
        "4": synthetic_book(4, pinyin_initials="magicletters"),
        "5": synthetic_book(5, pinyin_full="beforemagicafter"),
        "6": synthetic_book(6, author="magic"),
        "7": synthetic_book(7, illustrator="magic"),
        "8": synthetic_book(8, tags=["magic"]),
        "9": synthetic_book(9, publisher="magic"),
        "10": synthetic_book(10, volume_list=[{"n": 1, "label": "magic", "file": "1_a.epub", "size": 1, "mtime": 0}]),
        "60": synthetic_book(60, author="magic", updated="2024-02-01"),
        "100": synthetic_book(100, author="magic", updated="2024-02-01"),
        "999": synthetic_book(999, tags=["magic suffix"]),
    }
    config = Config(data_dir=tmp_path)
    write_catalog(config.catalog_path, books)
    with TestClient(create_app(config)) as client:
        result = client.get("/api/v1/search", params={"q": "　ＭＡＧＩＣ　"}).json()
        assert ids(result) == ["1", "2", "3", "5", "4", "100", "60", "7", "6", "8", "10", "9"]
        assert result["total"] == 12 and result["q"] == "　ＭＡＧＩＣ　"
        assert ids(client.get("/api/v1/search?q=magic&offset=3&limit=2").json()) == ["5", "4"]


def test_multiword_score_30_and_highest_match(tmp_path):
    books = {
        "1": synthetic_book(1, title="magic field", author="magic field"),
        "2": synthetic_book(2, title="magic field extra"),
        "3": synthetic_book(3, title="a magic field extra"),
        "4": synthetic_book(4, author="magic field"),
        "5": synthetic_book(5, tags=["magic field"]),
        "6": synthetic_book(6, publisher="magic field"),
        "7": synthetic_book(7, title="magic", author="field"),
        "8": synthetic_book(8, title="magic", illustrator="field"),
        "9": synthetic_book(9, title="magic", tags=["field"]),
        "10": synthetic_book(10, title="magic", description="field"),
    }
    catalog = Catalog(Config(data_dir=tmp_path), {}, books)
    result = catalog.search(" Magic  \t Field ")
    assert ids(result) == ["1", "2", "3", "4", "5", "6", "9", "8", "7"]
    assert result["q"] == " Magic  \t Field "


@pytest.mark.parametrize("q", ["g", "12", "gu12", "古"])
def test_pinyin_requires_two_ascii_letters(q, tmp_path):
    book = synthetic_book(1, title="汉字", pinyin_full="gugu12", pinyin_initials="gugu12")
    catalog = Catalog(Config(data_dir=tmp_path), {}, {"1": book})
    assert catalog.search(q)["total"] == 0


def test_pinyin_initials_prefix_and_full_substring(tmp_path):
    book = synthetic_book(1, title="轻小说", pinyin_full="qingxiaoshuo", pinyin_initials="qxs")
    catalog = Catalog(Config(data_dir=tmp_path), {}, {"1": book})
    assert catalog.search("qx")["total"] == 1
    assert catalog.search("xiaoshuo")["total"] == 1
    assert catalog.search("xs")["total"] == 0
