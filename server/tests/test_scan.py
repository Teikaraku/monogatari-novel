import os
from dataclasses import replace
from pathlib import Path

import orjson
import pytest

from novel.scan import parse_book, parse_words, read_meta, scan_library, volume_label


def test_all_fields_and_ignored_inputs(mini_library):
    sources = scan_library(mini_library.config)
    assert set(sources) == {"1000", "01001", "1002", "1004", "1005", "1006", "1007", "1008"}
    books = {key: parse_book(source, mini_library.config) for key, source in sources.items()}
    book = books["1000"]
    assert book["id"] == "1000"
    assert book["title"] == "圈、叉与三角——王牌，就此展开"
    assert (book["author"], book["illustrator"], book["publisher"]) == ("月本一", "插画师", "Fami通文库")
    assert book["description"] == "描述" + "很长的故事" * 30
    assert (book["status"], book["words"], book["chapters"], book["updated"]) == ("completed", 142000, 8, "2020-02-22")
    assert book["tags"] == ["校园", "竞技", "青春", "恋爱", "青梅竹马", "第六标签"]
    assert book["volume_count"] == 2
    assert [volume["n"] for volume in book["volume_list"]] == [1, 2]
    first = book["volume_list"][0]
    assert first == {"n": 1, "label": "1 乱七八糟湿透了的赛璐璐", "file": "01_圈、叉与三角——王牌，就此展开 1 乱七八糟湿透了的赛璐璐.epub",
                     "size": 24, "mtime": int(mini_library.timestamp - 86400)}
    assert books["1004"]["volume_list"][0]["label"] == "为了女 1"
    assert books["1005"]["volume_list"][0]["label"] == "第3卷"
    assert books["1006"]["volume_list"][0]["label"] == "1"
    assert books["1006"]["status"] == "ongoing"
    assert books["1006"]["words"] == 123456
    assert books["1006"]["tags"] == ["恋爱", "旅行"]
    assert all(books["1006"][field] == "" for field in ("author", "illustrator", "publisher", "description"))
    assert books["1007"]["status"] == "unknown"
    assert books["1007"]["words"] == books["1007"]["chapters"] == 0
    assert books["1007"]["tags"] == []
    for key in ("01001", "1002"):
        assert books[key]["title"] == sources[key].directory_title
        assert books[key]["updated"] == "2024-01-02"
        assert books[key]["status"] == "unknown"
        assert books[key]["author"] == ""
    assert sources["1000"].cover.name == "cover.jpg"
    assert sources["1008"].cover.name == "custom.png"
    assert sources["01001"].cover is None


@pytest.mark.parametrize(("value", "expected"), [
    ("14.2 万", 142000), (" 123456 ", 123456), ("未知", 0), (None, 0), (12, 0),
    ("1.2.3万", 0), (".万", 0), ("-1", 0), ("1.5", 0), ("0.00005 万", 0),
])
def test_words(value, expected):
    assert parse_words(value) == expected


@pytest.mark.parametrize("content", [b"broken", b"[]", b"null", b"123", b'"text"', b"\xff"])
def test_broken_meta_is_missing(mini_library, content):
    (mini_library.directories["1000"] / "meta.json").write_bytes(content)
    source = scan_library(mini_library.config)["1000"]
    book = parse_book(source, mini_library.config)
    assert book["title"] == source.directory_title
    assert book["author"] == ""
    assert book["updated"] == "2024-01-02"


def test_unreadable_meta(tmp_path, monkeypatch):
    def denied(*args):
        raise PermissionError("test")
    monkeypatch.setattr(type(tmp_path), "read_bytes", denied)
    assert read_meta(tmp_path / "meta.json") == {}


@pytest.mark.parametrize("title", [None, 3, [], "  ", "\t"])
def test_title_fallback(mini_library, title):
    source = scan_library(mini_library.config)["1000"]
    source.meta["title"] = title
    assert parse_book(source, mini_library.config)["title"] == source.directory_title


def test_directory_title_prefix_and_separator_characters():
    assert volume_label("01_目录题\t -—_:：·・、,，卷一.epub", 1, "元数据题", "目录题") == "卷一"
    assert volume_label("01_ＡＢＣ　Title 终.epub", 1, "abc title", "其他") == "终"


@pytest.mark.parametrize(("chapters", "expected"), [(None, 0), ([], 0), ("bad", 0), ("12", 12), (4.9, 4)])
def test_chapters(mini_library, chapters, expected):
    source = scan_library(mini_library.config)["1000"]
    source.meta["chapter_count"] = chapters
    assert parse_book(source, mini_library.config)["chapters"] == expected


def test_updated_format_only_and_timezone(mini_library):
    source = scan_library(mini_library.config)["1000"]
    source.meta["last_update"] = "2020-99-99"
    assert parse_book(source, mini_library.config)["updated"] == "2020-99-99"
    source.meta["last_update"] = " 2020-01-01 "
    assert parse_book(source, mini_library.config)["updated"] == "2024-01-02"
    assert parse_book(source, replace(mini_library.config, timezone="UTC"))["updated"] == "2024-01-01"


def test_cover_fallback_order_and_missing_reference(mini_library):
    directory = mini_library.directories["1008"]
    (directory / "meta.json").write_bytes(orjson.dumps({"cover_file": "missing.png"}))
    for name in ("cover.jpeg", "cover.png", "cover.webp"):
        (directory / name).write_bytes(b"test")
    for expected in ("cover.jpg", "cover.jpeg", "cover.png", "cover.webp"):
        assert scan_library(mini_library.config)["1008"].cover.name == expected
        (directory / expected).unlink()
    assert scan_library(mini_library.config)["1008"].cover is None


def test_signature_changes_with_each_input(mini_library):
    def signature():
        return scan_library(mini_library.config)["1000"].signature
    directory = mini_library.directories["1000"]
    previous = signature()
    for path in (directory, directory / "meta.json", directory / "cover.jpg",
                 directory / "02_圈、叉与三角——王牌，就此展开 2 决赛.epub"):
        info = path.stat()
        os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns + 1_000_000))
        current = signature()
        assert current != previous
        previous = current


def test_pinyin(mini_library):
    source = scan_library(mini_library.config)["1000"]
    source.meta["title"] = "轻小说Ａ"
    book = parse_book(source, mini_library.config)
    assert book["sort_title"] == "qing xiao shuo a"
    assert book["pinyin_full"] == "qingxiaoshuoa"
    assert book["pinyin_initials"] == "qxsa"
    source.meta["title"] = "轻 小说Ａ　Ｂ"
    book = parse_book(source, mini_library.config)
    assert book["pinyin_full"] == "qingxiaoshuoab"
    assert book["pinyin_initials"] == "qxsab"


@pytest.mark.parametrize("reference", ["images/custom.png", "images\\custom.png", "../outside.png",
                                        "..\\outside.png", ".", "..", "/outside.png", "C:\\outside.png",
                                        "./custom.png", ".\\custom.png", "images", "", None, 42])
def test_invalid_cover_reference_falls_back_without_external_reads(mini_library, monkeypatch, reference):
    directory = mini_library.directories["1008"]
    (directory / "images").mkdir()
    cover = directory / "images" / "custom.png"
    cover.write_bytes(b"fixture")
    (directory.parent / "outside.png").write_bytes(b"outside fixture")
    (directory / "meta.json").write_bytes(orjson.dumps({"cover_file": reference}))
    original_scandir = os.scandir
    original_read = Path.read_bytes
    allowed = {mini_library.config.library_dir, *mini_library.directories.values()}

    def guarded_scandir(path):
        assert Path(path) in allowed
        return original_scandir(path)

    def guarded_read(path):
        assert path.name == "meta.json" and path.parent in allowed
        return original_read(path)

    monkeypatch.setattr(os, "scandir", guarded_scandir)
    monkeypatch.setattr(Path, "read_bytes", guarded_read)
    source = scan_library(mini_library.config)["1008"]
    assert source.cover == directory / "cover.jpg"
    previous = source.signature
    cover.write_bytes(b"changed fixture")
    assert scan_library(mini_library.config)["1008"].signature == previous
    (directory / "cover.jpg").unlink()
    assert scan_library(mini_library.config)["1008"].cover is None


def test_each_scanned_file_is_statted_once(mini_library, monkeypatch):
    original = os.scandir
    counts = {}

    class Entry:
        def __init__(self, entry):
            self.entry = entry

        def __getattr__(self, name):
            return getattr(self.entry, name)

        def stat(self, *args, **kwargs):
            counts[self.entry.path] = counts.get(self.entry.path, 0) + 1
            return self.entry.stat(*args, **kwargs)

    class Scan:
        def __init__(self, path):
            self.entries = original(path)

        def __enter__(self):
            return (Entry(entry) for entry in self.entries)

        def __exit__(self, *args):
            self.entries.close()

    monkeypatch.setattr(os, "scandir", Scan)
    scan_library(mini_library.config)
    assert counts and all(count == 1 for count in counts.values())
