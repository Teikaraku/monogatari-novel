import errno
import logging
import os
import sqlite3
import zipfile
from contextlib import closing

import orjson
import pytest

from novel import toc
from novel.indexer import Indexer
from test_toc import library_config, write_epub


def _book(config, *, broken=None):
    directory = config.library_dir / "1_book"
    directory.mkdir()
    path = directory / "01_book.epub"
    if broken == "zip":
        path.write_bytes(b"invalid zip")
    else:
        nav = {
            "xml": "<html><nav>",
            "empty": "<html><nav><ol/></nav></html>",
            "no-nav": "<html/>",
        }
        write_epub(path, **({"nav": nav[broken]} if broken else {}))
    return path


def _cache_rows(config):
    with closing(sqlite3.connect(config.data_dir / "toc_cache.sqlite")) as connection:
        return connection.execute(
            "SELECT book_id, n, entries_json, ok FROM toc_cache ORDER BY book_id, n").fetchall()


def _catalog_entries(config):
    with closing(sqlite3.connect(config.catalog_path)) as connection:
        return connection.execute("SELECT n, title FROM volume_toc ORDER BY n, idx").fetchall()


def _catalog_version(config):
    with closing(sqlite3.connect(config.catalog_path)) as connection:
        return connection.execute("SELECT value FROM meta WHERE key='version'").fetchone()[0]


def _make_legacy_cache(config, path, entries):
    info = path.stat()
    with closing(sqlite3.connect(config.data_dir / "toc_cache.sqlite")) as connection:
        connection.executescript("""
            DROP TABLE toc_cache;
            CREATE TABLE toc_cache(
                book_id TEXT, n INTEGER, size INTEGER, mtime INTEGER, entries_json TEXT,
                PRIMARY KEY(book_id, n)
            );
        """)
        connection.execute("INSERT INTO toc_cache VALUES (?, ?, ?, ?, ?)",
                           ("1", 1, info.st_size, info.st_mtime_ns, orjson.dumps(entries).decode()))
        connection.commit()


def _toc_warnings(caplog):
    return [record for record in caplog.records
            if record.name == "novel.toc" and record.levelno >= logging.WARNING]


@pytest.mark.parametrize("stage", ["open", "read"])
@pytest.mark.parametrize("failure", [PermissionError, FileNotFoundError, OSError])
def test_unreadable_volume_is_not_cached_and_retries_without_signature_change(
        tmp_path, monkeypatch, caplog, stage, failure):
    config = library_config(tmp_path)
    path = _book(config)
    original = toc.ZipFile
    unreadable = True
    attempts = []

    def fail(*args, **kwargs):
        raise failure(errno.EIO, "simulated unreadable EPUB", str(path))

    def open_archive(filename, *args, **kwargs):
        attempts.append(filename)
        if unreadable and stage == "open":
            fail()
        archive = original(filename, *args, **kwargs)
        if unreadable and stage == "read":
            monkeypatch.setattr(archive, "read", fail)
        return archive

    monkeypatch.setattr(toc, "ZipFile", open_archive)
    assert toc.extract_toc(path) is None
    assert _toc_warnings(caplog) == []
    attempts.clear()
    info = path.stat()
    signature = (info.st_size, info.st_mtime_ns)
    indexer = Indexer(config)
    assert indexer.run_once().rebuilt
    assert _cache_rows(config) == []
    assert _catalog_entries(config) == []
    empty_version = _catalog_version(config)
    assert len(_toc_warnings(caplog)) == 1

    caplog.clear()
    result = indexer.run_once()
    assert not result.rebuilt and result.changed == 0
    assert len(attempts) == 2 and _cache_rows(config) == []
    assert len(_toc_warnings(caplog)) == 1

    unreadable = False
    caplog.clear()
    result = indexer.run_once()
    assert result.rebuilt and result.changed == 0
    assert len(attempts) == 3
    assert (path.stat().st_size, path.stat().st_mtime_ns) == signature
    assert _catalog_entries(config) == [(1, "第一章")]
    assert _catalog_version(config).split("-")[-1] != empty_version.split("-")[-1]
    assert len(_cache_rows(config)) == 1 and _cache_rows(config)[0][3] == 1
    assert _toc_warnings(caplog) == []
    assert not indexer.run_once().rebuilt and len(attempts) == 3


def test_underlying_read_error_wrapped_as_bad_zip_is_not_cached(tmp_path, monkeypatch, caplog):
    config = library_config(tmp_path)
    path = _book(config)
    original_open = zipfile.io.open
    unreadable = True
    failures = []

    class UnreadableFile:
        def __init__(self, stream):
            self.stream = stream

        def __getattr__(self, name):
            return getattr(self.stream, name)

        def read(self, *args, **kwargs):
            failures.append(path)
            raise OSError(errno.EIO, "simulated storage read failure", str(path))

    def open_file(filename, *args, **kwargs):
        stream = original_open(filename, *args, **kwargs)
        if str(filename) == str(path) and unreadable:
            return UnreadableFile(stream)
        return stream

    monkeypatch.setattr(zipfile.io, "open", open_file)
    # ZipFile converts the central-directory read's OSError into BadZipFile.
    assert toc.extract_toc(path) is None
    assert failures and _toc_warnings(caplog) == []
    indexer = Indexer(config)
    assert indexer.run_once().rebuilt
    assert _cache_rows(config) == [] and _catalog_entries(config) == []
    assert not indexer.run_once().rebuilt
    assert _cache_rows(config) == []
    unreadable = False
    result = indexer.run_once()
    assert result.rebuilt and result.changed == 0
    assert _catalog_entries(config) == [(1, "第一章")]
    assert _cache_rows(config)[0][3] == 1


@pytest.mark.parametrize("broken", ["zip", "xml", "empty", "no-nav"])
def test_content_failures_are_marked_ok_and_empty_cache_is_reused(tmp_path, monkeypatch, broken):
    config = library_config(tmp_path)
    _book(config, broken=broken)
    indexer = Indexer(config)
    assert indexer.run_once().rebuilt
    assert _cache_rows(config) == [("1", 1, "[]", 1)]
    assert _catalog_entries(config) == []

    def no_open(*args, **kwargs):
        pytest.fail("An unchanged content error must reuse its successful empty cache")

    monkeypatch.setattr(toc, "ZipFile", no_open)
    assert not indexer.run_once().rebuilt
    assert not indexer.run_once(full=True).rebuilt
    assert _cache_rows(config) == [("1", 1, "[]", 1)]


def test_legacy_nonempty_cache_is_marked_ok_without_reextracting(tmp_path, monkeypatch):
    config = library_config(tmp_path)
    path = _book(config)
    indexer = Indexer(config)
    assert indexer.run_once().rebuilt
    entries = orjson.loads(_cache_rows(config)[0][2])
    _make_legacy_cache(config, path, entries)
    before = config.catalog_path.read_bytes()

    def no_open(*args, **kwargs):
        pytest.fail("A legacy nonempty TOC must be trusted without reopening the EPUB")

    monkeypatch.setattr(toc, "ZipFile", no_open)
    assert not indexer.run_once().rebuilt
    assert _cache_rows(config) == [("1", 1, orjson.dumps(entries).decode(), 1)]
    assert config.catalog_path.read_bytes() == before
    cache_stamp = (config.data_dir / "toc_cache.sqlite").stat().st_mtime_ns
    assert not indexer.run_once().rebuilt
    assert (config.data_dir / "toc_cache.sqlite").stat().st_mtime_ns == cache_stamp


@pytest.mark.parametrize("still_empty", [False, True])
def test_legacy_empty_cache_is_rechecked_once_and_only_new_entries_rebuild(
        tmp_path, monkeypatch, still_empty):
    config = library_config(tmp_path)
    path = _book(config, broken="zip" if still_empty else None)
    original = toc.extract_toc
    monkeypatch.setattr(toc, "extract_toc", lambda path: [])
    indexer = Indexer(config)
    assert indexer.run_once().rebuilt
    assert _catalog_entries(config) == []
    _make_legacy_cache(config, path, [])
    calls = []

    def extract(filename):
        calls.append(filename)
        return original(filename)

    monkeypatch.setattr(toc, "extract_toc", extract)
    result = indexer.run_once()
    assert result.changed == 0 and result.rebuilt is not still_empty
    assert calls == [path]
    assert _cache_rows(config)[0][3] == 1
    assert _catalog_entries(config) == ([] if still_empty else [(1, "第一章")])
    assert not indexer.run_once().rebuilt
    assert not indexer.run_once(full=True).rebuilt
    assert calls == [path]


def test_legacy_empty_cache_that_is_still_unreadable_is_removed_then_retried(tmp_path, monkeypatch):
    config = library_config(tmp_path)
    path = _book(config)
    original = toc.extract_toc
    monkeypatch.setattr(toc, "extract_toc", lambda path: [])
    indexer = Indexer(config)
    assert indexer.run_once().rebuilt
    _make_legacy_cache(config, path, [])
    monkeypatch.setattr(toc, "extract_toc", lambda path: None)
    assert indexer.run_once().rebuilt
    assert _cache_rows(config) == []
    assert not indexer.run_once().rebuilt
    monkeypatch.setattr(toc, "extract_toc", original)
    result = indexer.run_once()
    assert result.rebuilt and result.changed == 0
    assert _catalog_entries(config) == [(1, "第一章")]
    assert _cache_rows(config)[0][3] == 1


def test_multiple_unreadable_volumes_emit_one_summary_per_round(tmp_path, monkeypatch, caplog):
    config = library_config(tmp_path)
    first = _book(config)
    paths = [first, first.with_name("02_book.epub"), first.with_name("03_book.epub")]
    for path in paths[1:]:
        write_epub(path)
    healthy = first.with_name("04_book.epub")
    write_epub(healthy)
    original = toc.ZipFile

    def open_archive(path, *args, **kwargs):
        if path in paths:
            raise PermissionError(errno.EACCES, "permission denied", str(path))
        return original(path, *args, **kwargs)

    monkeypatch.setattr(toc, "ZipFile", open_archive)
    indexer = Indexer(config)
    for round_number in range(2):
        caplog.clear()
        assert indexer.run_once().rebuilt is (round_number == 0)
        warnings = _toc_warnings(caplog)
        assert len(warnings) == 1
        message = warnings[0].getMessage()
        assert "3" in message and any(str(path) in message for path in paths)
        assert [(row[0], row[1], row[3]) for row in _cache_rows(config)] == [("1", 4, 1)]
        assert _catalog_entries(config) == [(4, "第一章")]


def test_changed_unreadable_volume_discards_old_nonempty_cache_until_recovery(tmp_path, monkeypatch):
    config = library_config(tmp_path)
    path = _book(config)
    indexer = Indexer(config)
    assert indexer.run_once().rebuilt
    assert _catalog_entries(config) == [(1, "第一章")]
    info = path.stat()
    os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns + 1000000))
    original = toc.ZipFile

    def deny(*args, **kwargs):
        raise PermissionError(errno.EACCES, "permission denied", str(path))

    monkeypatch.setattr(toc, "ZipFile", deny)
    assert indexer.run_once().rebuilt
    assert _cache_rows(config) == [] and _catalog_entries(config) == []
    assert not indexer.run_once().rebuilt
    monkeypatch.setattr(toc, "ZipFile", original)
    result = indexer.run_once()
    assert result.rebuilt and result.changed == 0
    assert _catalog_entries(config) == [(1, "第一章")]
    assert _cache_rows(config)[0][3] == 1
