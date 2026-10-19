import hashlib
import os
import signal
import sqlite3
import subprocess
import sys
from contextlib import closing

import orjson
import pytest
from PIL import Image

from novel import indexer as module
from novel.indexer import Indexer


def database_meta(config):
    with closing(sqlite3.connect(config.catalog_path)) as connection:
        return dict(connection.execute("SELECT key, value FROM meta"))


def snapshot(root):
    return {str(path.relative_to(root)): (path.lstat().st_mtime_ns, path.lstat().st_size)
            for path in root.rglob("*")}


def test_first_build(built_library, caplog):
    config = built_library.config
    assert built_library.stats.books == 8
    assert built_library.stats.volumes == 9
    assert built_library.stats.changed == 8
    assert built_library.stats.covers == 6
    assert built_library.stats.rebuilt
    with closing(sqlite3.connect(config.catalog_path)) as connection:
        objects = dict(connection.execute("SELECT name, type FROM sqlite_master"))
        assert all(objects[name] == "table" for name in ("meta", "books", "volumes"))
        assert all(objects[name] == "index" for name in ("books_updated", "books_status", "books_words"))
        meta = dict(connection.execute("SELECT key, value FROM meta"))
        assert meta["book_count"] == "8" and meta["volume_count"] == "9"
        assert len(meta["version"]) == 23
        assert meta["built_at"].endswith("+00:00")
        keys = dict(connection.execute("SELECT id, cover_key FROM books"))
    for book_id, dimensions in (("1000", [(240, 360), (480, 720)]),
                                ("1006", [(160, 80), (160, 80)]), ("1008", [(240, 120), (320, 160)])):
        for width, size in zip((240, 480), dimensions):
            with Image.open(config.data_dir / "covers" / book_id / f"{keys[book_id]}-{width}.webp") as image:
                assert image.format == "WEBP" and image.mode == "RGB" and image.size == size
                if book_id == "1006":
                    assert all(channel >= 250 for channel in image.getpixel((0, 0)))
    assert keys["1007"] == keys["01001"] == ""
    assert keys["1000"] == hashlib.sha1((built_library.directories["1000"] / "cover.jpg").read_bytes()).hexdigest()[:12]
    state = orjson.loads((config.data_dir / "state.json").read_bytes())
    assert set(state) == set(keys)
    assert len(state["1000"]["signature"]) == 40
    assert not list(config.data_dir.rglob("*.tmp-*"))


def test_links_point_to_host_root(built_library, symlinks_available):
    state = orjson.loads((built_library.config.data_dir / "state.json").read_bytes())
    for book_id, cached in state.items():
        book = cached["book"]
        for volume in book["volume_list"]:
            link = built_library.config.data_dir / "files" / book_id / f"{volume['n']}.epub"
            assert link.is_symlink()
            target = os.readlink(link)
            if os.name == "nt":
                target = target.removeprefix("\\\\?\\")
            assert target == str(built_library.config.files_link_root / book["directory"] / volume["file"])


def test_unchanged_round_preserves_every_output(built_library, caplog):
    before = snapshot(built_library.config.data_dir)
    version = database_meta(built_library.config)["version"]
    caplog.set_level("INFO")
    stats = built_library.indexer.run_once()
    assert stats.changed == stats.covers == 0
    assert not stats.rebuilt
    assert database_meta(built_library.config)["version"] == version
    assert snapshot(built_library.config.data_dir) == before
    records = [record for record in caplog.records if record.name == "novel.indexer"]
    assert len(records) == 1
    assert all(word in records[0].message for word in ("unchanged", "elapsed=", "books=8", "volumes=9", "link_failures="))


def test_only_changed_book_is_parsed(built_library, monkeypatch):
    path = built_library.directories["1000"] / "meta.json"
    meta = orjson.loads(path.read_bytes())
    old_version = database_meta(built_library.config)["version"]
    meta["author"] = "新的作者"
    path.write_bytes(orjson.dumps(meta))
    parsed = []
    original = module.parse_book

    def record(source, config):
        parsed.append(source.id)
        return original(source, config)

    monkeypatch.setattr(module, "parse_book", record)
    stats = built_library.indexer.run_once()
    assert parsed == ["1000"]
    assert stats.changed == 1 and stats.covers == 2
    assert database_meta(built_library.config)["version"] != old_version


def test_removed_book_outputs_deleted(built_library):
    directory = built_library.directories["1000"]
    directory.rename(directory.with_name("_removed"))
    stats = built_library.indexer.run_once()
    assert stats.books == 7 and stats.volumes == 7
    for root in ("covers", "files"):
        assert not (built_library.config.data_dir / root / "1000").exists()


def test_restart_and_full_repair_links_without_rewriting_database(built_library, symlinks_available):
    config = built_library.config
    link = config.data_dir / "files" / "1000" / "1.epub"
    target = os.readlink(link)
    database_before = (config.catalog_path.stat().st_mtime_ns, database_meta(config)["version"])
    link.unlink()
    built_library.indexer.run_once()
    assert not link.is_symlink()
    restarted = Indexer(config)
    stats = restarted.run_once()
    assert link.is_symlink() and os.readlink(link) == target
    assert not stats.rebuilt and stats.changed == 0
    link.unlink()
    link.symlink_to(config.data_dir / "wrong-target")
    extra = link.with_name("999.epub")
    extra.symlink_to(config.data_dir / "old-target")
    old_covers = snapshot(config.data_dir / "covers")
    stats = restarted.run_once(full=True)
    assert os.readlink(link) == target and not extra.is_symlink()
    assert stats.changed == 8 and stats.covers == 6 and not stats.rebuilt
    assert snapshot(config.data_dir / "covers") != old_covers
    assert (config.catalog_path.stat().st_mtime_ns, database_meta(config)["version"]) == database_before


def test_cover_changes_delete_old_thumbnails(built_library):
    directory = built_library.config.data_dir / "covers" / "1000"
    before = {path.name for path in directory.iterdir()}
    Image.new("RGB", (700, 1000), "blue").save(built_library.directories["1000"] / "cover.jpg")
    stats = built_library.indexer.run_once()
    after = {path.name for path in directory.iterdir()}
    assert len(after) == 2 and before.isdisjoint(after)
    assert stats.changed == 1
    (built_library.directories["1000"] / "cover.jpg").write_bytes(b"invalid image")
    stats = built_library.indexer.run_once()
    assert stats.changed == 1
    assert not list(directory.iterdir())


def test_link_failures_logged_per_book(mini_library, monkeypatch, caplog):
    def denied(*args, **kwargs):
        raise PermissionError("test denied")
    monkeypatch.setattr(os, "symlink", denied)
    stats = Indexer(mini_library.config).run_once()
    assert stats.books == 8 and stats.link_failures == 8
    assert sum("File links failed for book" in record.message for record in caplog.records) == 8
    assert "Cannot decode cover for book 1007" in caplog.text


def test_single_book_exception_is_isolated(mini_library, monkeypatch, caplog):
    original = module.parse_book

    def fail_one(source, config):
        if source.id == "1000":
            raise RuntimeError("broken book")
        return original(source, config)

    monkeypatch.setattr(module, "parse_book", fail_one)
    stats = Indexer(mini_library.config).run_once()
    assert stats.books == 7
    assert "Skipping book 1000" in caplog.text


def test_database_replace_failure_preserves_database_and_state(built_library, monkeypatch):
    config = built_library.config
    before_db = config.catalog_path.read_bytes()
    before_state = (config.data_dir / "state.json").read_bytes()
    (built_library.directories["1005"] / "meta.json").write_bytes(b'{"author":"changed"}')
    original = os.replace

    def fail_database(source, destination):
        if destination == config.catalog_path:
            raise OSError("test replace failure")
        return original(source, destination)

    monkeypatch.setattr(os, "replace", fail_database)
    with pytest.raises(OSError, match="test replace failure"):
        built_library.indexer.run_once()
    assert config.catalog_path.read_bytes() == before_db
    assert (config.data_dir / "state.json").read_bytes() == before_state
    assert not list(config.data_dir.glob("catalog.sqlite.tmp-*"))


@pytest.mark.parametrize("signum", [signal.SIGINT, signal.SIGTERM])
def test_signal_finishes_round_before_exit(monkeypatch, signum):
    handlers = {}
    actions = []
    monkeypatch.setattr(signal, "signal", lambda number, handler: handlers.update({number: handler}))

    def run(self, full=False):
        actions.append("start")
        handlers[signum](signum, None)
        actions.append("finish")

    monkeypatch.setattr(Indexer, "run_once", run)
    assert module.main([]) == 0
    assert actions == ["start", "finish"]


def test_cli_once(tmp_path):
    library = tmp_path / "library"
    library.mkdir()
    data = tmp_path / "data"
    environment = {**os.environ, "LIBRARY_DIR": str(library), "DATA_DIR": str(data)}
    result = subprocess.run([sys.executable, "-m", "novel.indexer", "--once", "--full"], env=environment,
                            capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stderr
    assert "books=0 volumes=0" in result.stderr
    assert (data / "catalog.sqlite").exists()
