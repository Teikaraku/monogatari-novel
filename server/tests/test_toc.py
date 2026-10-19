import os
import sqlite3
from contextlib import closing
from zipfile import ZIP_DEFLATED, ZipFile

import orjson
import pytest

from novel import indexer as indexer_module, toc
from novel.config import Config
from novel.indexer import Indexer
from novel.scan import parse_book, scan_library

CONTAINER = ('<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
             '<rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>')
NAV = ('<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
       '<body><nav epub:type="toc"><ol><li><a href="../Text/ch1.xhtml#p3">第一章</a></li></ol>'
       '</nav></body></html>')
NCX = ('<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>'
       '<navPoint id="one"><navLabel><text>第一卷</text></navLabel><content src="Text/one.xhtml"/>'
       '<navPoint id="two"><navLabel><text> 第二章\n  开始 </text></navLabel>'
       '<content src="./Text/../Text/two.xhtml#part"/></navPoint></navPoint></navMap></ncx>')


def write_epub(path, *, nav=NAV, ncx=None, spine_toc="ncx", files=None):
    items = []
    if nav is not None:
        items.append('<item id="nav" properties="scripted nav" href="Navigation/nav.xhtml" '
                     'media-type="application/xhtml+xml"/>')
    if ncx is not None:
        items.append('<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>')
    package = ('<package xmlns="http://www.idpf.org/2007/opf"><manifest>' + "".join(items)
               + f'</manifest><spine toc="{spine_toc}"/></package>')
    with ZipFile(path, "w", ZIP_DEFLATED) as archive:
        archive.writestr("META-INF/container.xml", CONTAINER)
        archive.writestr("OEBPS/content.opf", package)
        if nav is not None:
            archive.writestr("OEBPS/Navigation/nav.xhtml", nav)
        if ncx is not None:
            archive.writestr("OEBPS/toc.ncx", ncx)
        for name, content in (files or {}).items():
            archive.writestr(name, content)


def library_config(tmp_path):
    library = tmp_path / "library"
    library.mkdir()
    return Config(library_dir=library, data_dir=tmp_path / "data", files_link_root=library)


def test_epub3_nested_nav_relative_paths_fragments_and_titles(tmp_path):
    path = tmp_path / "book.epub"
    nav = ('<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>'
           '<nav><ol><li><a href="wrong.xhtml">Wrong nav</a></li></ol></nav>'
           '<nav epub:type="toc"><ol><li><a href="../Text/./ch1.xhtml#p3">  第一章\n <b>开始</b> </a>'
           '<ol><li><a href="../Text/sub/../ch2.xhtml"> 第二章 </a><ol>'
           '<li><a href="..\\Text\\ch3.xhtml#end"> 第三章 </a></li></ol></li></ol></li>'
           '<li><a href="empty.xhtml"> \n </a></li><li><a href="#local">'
           + "长" * 130 + '</a></li></ol></nav></body></html>')
    write_epub(path, nav=nav)
    assert toc.extract_toc(path) == [
        {"title": "第一章 开始", "href": "OEBPS/Text/ch1.xhtml#p3", "level": 0},
        {"title": "第二章", "href": "OEBPS/Text/ch2.xhtml", "level": 1},
        {"title": "第三章", "href": "OEBPS/Text/ch3.xhtml#end", "level": 2},
        {"title": "长" * 120, "href": "OEBPS/Navigation/nav.xhtml#local", "level": 0},
    ]


def test_epub3_falls_back_to_first_nav_and_caps_at_500(tmp_path):
    path = tmp_path / "book.epub"
    nav = "<html><nav><ol>" + "".join(
        f'<li><a href="../Text/ch{i}.xhtml">Chapter {i}</a></li>' for i in range(505)) + "</ol></nav></html>"
    write_epub(path, nav=nav)
    entries = toc.extract_toc(path)
    assert len(entries) == 500
    assert entries[0]["title"] == "Chapter 0"
    assert entries[-1]["title"] == "Chapter 499"


@pytest.mark.parametrize("spine_toc", ["ncx", "missing", ""])
def test_epub2_nested_ncx_and_manifest_fallback(tmp_path, spine_toc):
    path = tmp_path / "book.epub"
    write_epub(path, nav=None, ncx=NCX, spine_toc=spine_toc)
    assert toc.extract_toc(path) == [
        {"title": "第一卷", "href": "OEBPS/Text/one.xhtml", "level": 0},
        {"title": "第二章 开始", "href": "OEBPS/Text/two.xhtml#part", "level": 1},
    ]


def test_epub3_nav_has_priority_over_ncx(tmp_path):
    path = tmp_path / "book.epub"
    write_epub(path, ncx=NCX)
    assert toc.extract_toc(path) == [{"title": "第一章", "href": "OEBPS/Text/ch1.xhtml#p3", "level": 0}]


@pytest.mark.parametrize("broken", ["zip", "container", "xml", "empty", "no-nav"])
def test_broken_or_missing_toc_is_empty_and_does_not_stop_indexing(tmp_path, caplog, broken):
    config = library_config(tmp_path)
    directory = config.library_dir / "1_book"
    directory.mkdir()
    path = directory / "01_book.epub"
    write_epub(directory / "02_book.epub")
    if broken == "zip":
        path.write_bytes(b"invalid zip")
    elif broken == "container":
        with ZipFile(path, "w") as archive:
            archive.writestr("unrelated.txt", "missing container")
    else:
        write_epub(path, nav={"xml": "<html><nav>", "empty": "<html><nav><ol/></nav></html>",
                              "no-nav": "<html/>"}[broken])
    stats = Indexer(config).run_once()
    assert stats.books == 1 and stats.volumes == 2 and stats.rebuilt
    with closing(sqlite3.connect(config.catalog_path)) as connection:
        assert connection.execute("SELECT n, title FROM volume_toc ORDER BY n").fetchall() == [(2, "第一章")]
    assert "Cannot extract TOC" in caplog.text


@pytest.mark.parametrize("encoding", ["utf-8", "utf-16"])
@pytest.mark.parametrize("entity", ["external", "internal", "parameter"])
def test_xml_entities_are_explicitly_rejected(tmp_path, caplog, encoding, entity):
    path = tmp_path / "book.epub"
    secret = tmp_path / "secret.txt"
    secret.write_text("PRIVATE ENTITY CONTENT", encoding="utf-8")
    declarations = {
        "external": f'<!ENTITY xxe SYSTEM "{secret.as_uri()}">',
        "internal": '<!ENTITY xxe "PRIVATE ENTITY CONTENT">',
        "parameter": f'<!ENTITY % remote SYSTEM "{secret.as_uri()}"> %remote;',
    }
    body = "&xxe;" if entity != "parameter" else "Ignored entity"
    nav = (f'<?xml version="1.0" encoding="{encoding}"?><!DOCTYPE html [{declarations[entity]}]>'
           f'<html><nav><ol><li><a href="../Text/ch1.xhtml">{body}</a></li></ol></nav></html>')
    write_epub(path, nav=nav.encode(encoding))
    assert toc.extract_toc(path) == []
    assert "XML entities are disabled" in caplog.text


def test_external_doctype_is_not_loaded(tmp_path):
    path = tmp_path / "book.epub"
    # A nonexistent external DTD is not opened or expanded.
    nav = f'<!DOCTYPE html SYSTEM "{(tmp_path / "missing.dtd").as_uri()}">' + NAV
    write_epub(path, nav=nav)
    assert toc.extract_toc(path)[0]["title"] == "第一章"


def test_cache_reuses_signatures_and_prunes_removed_volumes_and_books(tmp_path, monkeypatch):
    config = library_config(tmp_path)
    directory = config.library_dir / "1_book"
    directory.mkdir()
    first = directory / "01_book.epub"
    second = directory / "02_book.epub"
    write_epub(first)
    write_epub(second)
    opened = []
    original = toc.ZipFile

    def record(path, *args, **kwargs):
        opened.append(path)
        return original(path, *args, **kwargs)

    monkeypatch.setattr(toc, "ZipFile", record)
    indexer = Indexer(config)
    assert indexer.run_once().rebuilt
    assert len(opened) == 2
    before = config.catalog_path.read_bytes()
    cache = config.data_dir / "toc_cache.sqlite"
    cache_stamp = cache.stat().st_mtime_ns
    assert not indexer.run_once().rebuilt
    assert not indexer.run_once(full=True).rebuilt
    assert len(opened) == 2 and config.catalog_path.read_bytes() == before
    assert cache.stat().st_mtime_ns == cache_stamp
    info = first.stat()
    os.utime(first, ns=(info.st_atime_ns, info.st_mtime_ns + 1000000))
    assert indexer.run_once().rebuilt
    assert len(opened) == 3 and opened[-1] == first
    second.unlink()
    assert indexer.run_once().rebuilt and len(opened) == 3
    with closing(sqlite3.connect(cache)) as connection:
        assert connection.execute("SELECT book_id, n FROM toc_cache").fetchall() == [("1", 1)]
    directory.rename(directory.with_name("_removed"))
    assert indexer.run_once().rebuilt
    with closing(sqlite3.connect(cache)) as connection:
        assert connection.execute("SELECT * FROM toc_cache").fetchall() == []


def test_old_state_and_catalog_upgrade_without_source_changes(tmp_path, monkeypatch):
    config = library_config(tmp_path)
    directory = config.library_dir / "1_book"
    directory.mkdir()
    write_epub(directory / "01_book.epub")
    Indexer(config).run_once()
    state_path = config.data_dir / "state.json"
    state = orjson.loads(state_path.read_bytes())
    state["1"]["book"]["volume_list"][0].pop("toc", None)
    state_path.write_bytes(orjson.dumps(state))
    with closing(sqlite3.connect(config.catalog_path)) as connection:
        connection.execute("DROP TABLE volume_toc")
        connection.commit()

    def no_open(*args, **kwargs):
        pytest.fail("Unchanged EPUB must use the persisted TOC cache")

    monkeypatch.setattr(toc, "ZipFile", no_open)
    indexer = Indexer(config)
    result = indexer.run_once()
    assert result.rebuilt and result.changed == 0
    with closing(sqlite3.connect(config.catalog_path)) as connection:
        assert connection.execute("SELECT book_id, n, idx, title FROM volume_toc").fetchall() == [("1", 1, 0, "第一章")]
    assert not indexer.run_once().rebuilt


def test_sync_reports_only_new_changed_or_removed_cached_results(tmp_path, monkeypatch):
    config = library_config(tmp_path)
    config.data_dir.mkdir()
    directory = config.library_dir / "1_book"
    directory.mkdir()
    path = directory / "01_book.epub"
    write_epub(path)
    calls = []
    original = toc.extract_toc

    def extract(path):
        calls.append(path)
        return original(path)

    monkeypatch.setattr(toc, "extract_toc", extract)

    def sync():
        sources = scan_library(config)
        books = {key: parse_book(source, config) for key, source in sources.items()}
        result = toc.sync_toc(config, books, sources)
        assert all("toc" not in volume for book in books.values() for volume in book["volume_list"])
        return result

    assert sync() is True and len(calls) == 1
    assert sync() is False and len(calls) == 1
    info = path.stat()
    os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns + 1000000))
    assert sync() is False and len(calls) == 2
    write_epub(path, nav=NAV.replace("第一章", "目录发生变化"))
    assert sync() is True and len(calls) == 3
    assert sync() is False and len(calls) == 3
    empty = directory / "02_book.epub"
    empty.write_bytes(b"invalid zip")
    assert sync() is True and len(calls) == 4
    empty.unlink()
    assert sync() is True and len(calls) == 4
    directory.rename(directory.with_name("_removed"))
    assert sync() is True and len(calls) == 4
    assert sync() is False and len(calls) == 4


def test_corrupt_cache_json_is_recovered_and_results_compare_semantically(tmp_path):
    config = library_config(tmp_path)
    config.data_dir.mkdir()
    directory = config.library_dir / "1_book"
    directory.mkdir()
    write_epub(directory / "01_book.epub")
    sources = scan_library(config)
    books = {key: parse_book(source, config) for key, source in sources.items()}
    assert toc.sync_toc(config, books, sources) is True
    cache = config.data_dir / "toc_cache.sqlite"
    with closing(sqlite3.connect(cache)) as connection:
        connection.execute("UPDATE toc_cache SET entries_json='broken json'")
        connection.commit()
    assert toc.sync_toc(config, books, sources) is True
    assert toc.sync_toc(config, books, sources) is False
    with closing(sqlite3.connect(cache)) as connection:
        encoded = orjson.dumps([{"level": 0, "href": "OEBPS/Text/ch1.xhtml#p3", "title": "第一章"}]).decode()
        connection.execute("UPDATE toc_cache SET mtime=-1, entries_json=?", (encoded,))
        connection.commit()
    assert toc.sync_toc(config, books, sources) is False


def test_state_excludes_toc_and_metadata_rebuild_uses_cache(tmp_path, monkeypatch):
    config = library_config(tmp_path)
    directory = config.library_dir / "1_book"
    directory.mkdir()
    write_epub(directory / "01_book.epub")
    captured = []
    original = indexer_module.write_catalog

    def capture(path, books):
        captured.append(books)
        return original(path, books)

    monkeypatch.setattr(indexer_module, "write_catalog", capture)
    indexer = Indexer(config)
    assert indexer.run_once().rebuilt
    state_path = config.data_dir / "state.json"

    def check_state():
        state = orjson.loads(state_path.read_bytes())
        assert all("toc" not in volume for value in state.values() for volume in value["book"]["volume_list"])

    check_state()
    assert captured[0]["1"]["volume_list"][0]["toc"][0]["title"] == "第一章"

    def no_open(*args, **kwargs):
        pytest.fail("An unchanged EPUB must never reopen while rebuilding unrelated metadata")

    monkeypatch.setattr(toc, "ZipFile", no_open)
    assert not indexer.run_once().rebuilt
    assert len(captured) == 1
    (directory / "meta.json").write_bytes(b'{"author":"new author"}')
    assert indexer.run_once().rebuilt
    check_state()
    assert captured[1]["1"]["volume_list"][0]["toc"][0]["title"] == "第一章"
    with closing(sqlite3.connect(config.catalog_path)) as connection:
        assert connection.execute("SELECT title FROM volume_toc").fetchall() == [("第一章",)]


def test_legacy_state_toc_is_ignored_and_cleaned_without_catalog_rebuild(tmp_path, monkeypatch):
    config = library_config(tmp_path)
    directory = config.library_dir / "1_book"
    directory.mkdir()
    write_epub(directory / "01_book.epub")
    Indexer(config).run_once()
    state_path = config.data_dir / "state.json"
    state = orjson.loads(state_path.read_bytes())
    state["1"]["book"]["volume_list"][0]["toc"] = [{"title": "Do not restore from state", "href": "wrong", "level": 0}]
    state_path.write_bytes(orjson.dumps(state))
    before = config.catalog_path.read_bytes()
    catalog_stamp = config.catalog_path.stat().st_mtime_ns

    def no_open(*args, **kwargs):
        pytest.fail("Legacy state cleanup must use the cache without opening EPUBs")

    monkeypatch.setattr(toc, "ZipFile", no_open)
    indexer = Indexer(config)
    assert not indexer.run_once().rebuilt
    assert "toc" not in orjson.loads(state_path.read_bytes())["1"]["book"]["volume_list"][0]
    assert config.catalog_path.read_bytes() == before
    assert config.catalog_path.stat().st_mtime_ns == catalog_stamp
    state_stamp = state_path.stat().st_mtime_ns
    assert not indexer.run_once().rebuilt
    assert state_path.stat().st_mtime_ns == state_stamp


def test_changed_toc_rebuilds_catalog_and_changes_version_hash(tmp_path):
    config = library_config(tmp_path)
    directory = config.library_dir / "1_book"
    directory.mkdir()
    path = directory / "01_book.epub"
    write_epub(path)
    indexer = Indexer(config)
    assert indexer.run_once().rebuilt
    with closing(sqlite3.connect(config.catalog_path)) as connection:
        version = connection.execute("SELECT value FROM meta WHERE key='version'").fetchone()[0]
    write_epub(path, nav=NAV.replace("第一章", "全新目录"))
    assert indexer.run_once().rebuilt
    with closing(sqlite3.connect(config.catalog_path)) as connection:
        newer = connection.execute("SELECT value FROM meta WHERE key='version'").fetchone()[0]
        assert newer.split("-")[-1] != version.split("-")[-1]
        assert connection.execute("SELECT title FROM volume_toc").fetchall() == [("全新目录",)]
    assert not indexer.run_once().rebuilt


@pytest.mark.parametrize("volumes", ["missing", None, [None]])
def test_invalid_state_volume_list_falls_back_to_rebuilding(tmp_path, caplog, volumes):
    config = library_config(tmp_path)
    directory = config.library_dir / "1_book"
    directory.mkdir()
    write_epub(directory / "01_book.epub")
    indexer = Indexer(config)
    assert indexer.run_once().rebuilt
    state_path = config.data_dir / "state.json"
    state = orjson.loads(state_path.read_bytes())
    if volumes == "missing":
        del state["1"]["book"]["volume_list"]
    else:
        state["1"]["book"]["volume_list"] = volumes
    state_path.write_bytes(orjson.dumps(state))
    assert indexer.run_once().rebuilt
    restored = orjson.loads(state_path.read_bytes())["1"]["book"]["volume_list"]
    assert len(restored) == 1 and restored[0]["n"] == 1 and "toc" not in restored[0]
    assert "Could not read index state; rebuilding" in caplog.text
