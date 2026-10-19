import os
import signal
from concurrent.futures import Future

import orjson
import pytest

from novel import indexer as module
from novel.catalog import Catalog
from novel.indexer import Indexer
from novel.scan import scan_library
from test_indexer import database_meta


def test_full_applies_only_to_first_loop(monkeypatch):
    handlers = {}
    calls = []
    monkeypatch.setenv("INDEX_INTERVAL", "0")
    monkeypatch.setattr(signal, "signal", lambda number, handler: handlers.update({number: handler}))

    def run(self, full=False):
        calls.append(full)
        if len(calls) == 3:
            handlers[signal.SIGTERM](None, None)

    monkeypatch.setattr(Indexer, "run_once", run)
    assert module.main(["--full"]) == 0
    assert calls == [True, False, False]


def test_repeated_new_failure_does_not_rebuild(mini_library, monkeypatch):
    original = module.parse_book
    calls = []

    def fail(source, config):
        if source.id == "1000":
            calls.append(source.id)
            raise RuntimeError("persistent failure")
        return original(source, config)

    monkeypatch.setattr(module, "parse_book", fail)
    indexer = Indexer(mini_library.config)
    first = indexer.run_once()
    version = database_meta(mini_library.config)["version"]
    stamp = mini_library.config.catalog_path.stat().st_mtime_ns
    second = indexer.run_once()
    third = indexer.run_once()
    assert first.books == second.books == third.books == 7
    assert calls == ["1000"] * 3
    assert not second.rebuilt and not third.rebuilt
    assert database_meta(mini_library.config)["version"] == version
    assert mini_library.config.catalog_path.stat().st_mtime_ns == stamp


@pytest.mark.parametrize("failure", ["parse", "cover", "scan"])
def test_failure_preserves_previous_book_and_signature(built_library, monkeypatch, failure):
    config = built_library.config
    state_path = config.data_dir / "state.json"
    previous = orjson.loads(state_path.read_bytes())
    version = database_meta(config)["version"]
    path = built_library.directories["1000"] / "meta.json"
    value = orjson.loads(path.read_bytes())
    value["author"] = "changed"
    path.write_bytes(orjson.dumps(value))
    if failure == "parse":
        original = module.parse_book

        def fail(source, config):
            if source.id == "1000":
                raise OSError("parse failed")
            return original(source, config)

        monkeypatch.setattr(module, "parse_book", fail)
    elif failure == "scan":
        from novel import scan
        original = scan.scan_book

        def fail(entry):
            if entry.name.startswith("1000_"):
                raise OSError("scan failed")
            return original(entry)

        monkeypatch.setattr(scan, "scan_book", fail)
    else:
        class FailedPool:
            def __init__(self, **kwargs):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def submit(self, *args):
                future = Future()
                future.set_exception(OSError("cover write failed"))
                return future

        monkeypatch.setattr(module, "ProcessPoolExecutor", FailedPool)
    for _ in range(2):
        result = built_library.indexer.run_once()
        assert result.books == 8 and not result.rebuilt
        assert database_meta(config)["version"] == version
        assert orjson.loads(state_path.read_bytes()) == previous


def test_ids_duplicate_and_too_long_are_ignored(mini_library, caplog):
    duplicate = mini_library.config.library_dir / "1000_duplicate"
    duplicate.mkdir()
    (duplicate / "01_test.epub").write_bytes(b"fixture")
    long_id = mini_library.config.library_dir / "12345678901_too_long"
    long_id.mkdir()
    (long_id / "01_test.epub").write_bytes(b"fixture")
    sources = scan_library(mini_library.config)
    assert "1000" not in sources and "12345678901" not in sources
    assert "Duplicate book id 1000" in caplog.text


def test_empty_duplicate_does_not_hide_book_with_volumes(mini_library, caplog):
    library = mini_library.config.library_dir
    empty = library / "251_kanon"
    empty.mkdir()
    (empty / "cover.jpg").write_bytes(b"cover only")
    book = library / "251_kanon 雪之少女官方小说"
    book.mkdir()
    for n in range(1, 7):
        (book / f"{n:02d}_kanon 第{n}卷.epub").write_bytes(b"fixture")
    source = scan_library(mini_library.config)["251"]
    assert source.directory == book and len(source.volumes) == 6
    Indexer(mini_library.config).run_once()
    catalog = Catalog.load(mini_library.config)
    assert catalog.books["251"]["volume_count"] == 6
    assert "Duplicate book id 251" not in caplog.text


def test_cover_decode_failure_keeps_book_with_empty_cover(built_library, caplog):
    config = built_library.config
    previous = orjson.loads((config.data_dir / "state.json").read_bytes())
    assert previous["1007"]["book"]["cover_key"] == ""
    assert previous["1000"]["book"]["cover_key"]
    (built_library.directories["1000"] / "cover.jpg").write_bytes(b"broken image")
    assert built_library.indexer.run_once().rebuilt
    state = orjson.loads((config.data_dir / "state.json").read_bytes())
    assert state["1000"]["book"]["cover_key"] == ""
    assert state["1000"]["signature"] != previous["1000"]["signature"]
    assert Catalog.load(config).books["1000"]["cover_key"] == ""
    assert "Cannot decode cover for book 1000" in caplog.text
    assert not built_library.indexer.run_once().rebuilt


def test_unrelated_success_preserves_failed_book_signature(built_library, monkeypatch):
    config = built_library.config
    previous = orjson.loads((config.data_dir / "state.json").read_bytes())
    for key in ("1000", "1005"):
        (built_library.directories[key] / "meta.json").write_bytes(b'{"author":"changed"}')
    original = module.parse_book

    def parse(source, config):
        if source.id == "1000":
            raise RuntimeError("failure")
        return original(source, config)

    monkeypatch.setattr(module, "parse_book", parse)
    result = built_library.indexer.run_once()
    state = orjson.loads((config.data_dir / "state.json").read_bytes())
    assert result.rebuilt and state["1000"] == previous["1000"]
    assert state["1005"]["book"]["author"] == "changed"


def test_new_cover_write_failure_does_not_rebuild_forever(mini_library):
    config = mini_library.config
    output = config.data_dir / "covers"
    output.mkdir(parents=True)
    (output / "1000").write_bytes(b"blocks cover directory creation")
    indexer = Indexer(config)
    first = indexer.run_once()
    version = database_meta(config)["version"]
    (output / "1000").write_bytes(b"blocks cover directory creation")
    second = indexer.run_once()
    assert first.books == second.books == 7
    assert not second.rebuilt and database_meta(config)["version"] == version
