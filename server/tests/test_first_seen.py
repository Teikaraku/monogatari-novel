import sqlite3
from contextlib import closing
from datetime import datetime, timezone

import orjson

from novel import indexer as module
from novel.config import Config
from novel.indexer import Indexer


def test_first_seen_is_utc_and_preserved_until_removal(tmp_path, monkeypatch):
    library = tmp_path / "library"
    library.mkdir()
    book = library / "1_book"
    book.mkdir()
    (book / "01_book.epub").write_bytes(b"fixture")
    config = Config(library_dir=library, data_dir=tmp_path / "data", files_link_root=library)
    now = [datetime(2026, 10, 17, 23, 59, tzinfo=timezone.utc)]

    class Clock:
        @staticmethod
        def now(tz):
            assert tz == timezone.utc
            return now[0]

    monkeypatch.setattr(module, "datetime", Clock)

    def first_seen():
        state = orjson.loads((config.data_dir / "state.json").read_bytes())
        with closing(sqlite3.connect(config.catalog_path)) as connection:
            stored = connection.execute("SELECT first_seen FROM books WHERE id='1'").fetchone()[0]
        assert state["1"]["book"]["first_seen"] == stored
        return stored

    indexer = Indexer(config)
    assert indexer.run_once().rebuilt and first_seen() == "2026-10-17"
    now[0] = datetime(2026, 10, 19, tzinfo=timezone.utc)
    assert not Indexer(config).run_once().rebuilt and first_seen() == "2026-10-17"
    (book / "meta.json").write_bytes(b'{"title":"changed"}')
    assert indexer.run_once().rebuilt and first_seen() == "2026-10-17"
    assert not indexer.run_once(full=True).rebuilt and first_seen() == "2026-10-17"
    removed = library / "_removed"
    book.rename(removed)
    assert indexer.run_once().rebuilt
    assert orjson.loads((config.data_dir / "state.json").read_bytes()) == {}
    removed.rename(book)
    assert indexer.run_once().rebuilt and first_seen() == "2026-10-19"


def test_old_state_and_catalog_gain_first_seen_without_source_changes(tmp_path, monkeypatch):
    library = tmp_path / "library"
    library.mkdir()
    book = library / "1_book"
    book.mkdir()
    (book / "01_book.epub").write_bytes(b"fixture")
    config = Config(library_dir=library, data_dir=tmp_path / "data", files_link_root=library)
    Indexer(config).run_once()
    path = config.data_dir / "state.json"
    state = orjson.loads(path.read_bytes())
    del state["1"]["book"]["first_seen"]
    signature = state["1"]["signature"]
    path.write_bytes(orjson.dumps(state))
    with closing(sqlite3.connect(config.catalog_path)) as connection:
        connection.execute("ALTER TABLE books DROP COLUMN first_seen")
        connection.commit()

    class Clock:
        @staticmethod
        def now(tz):
            return datetime(2026, 10, 20, tzinfo=tz)

    monkeypatch.setattr(module, "datetime", Clock)
    indexer = Indexer(config)
    result = indexer.run_once()
    assert result.rebuilt and result.changed == result.covers == 0
    state = orjson.loads(path.read_bytes())
    assert state["1"]["signature"] == signature and state["1"]["book"]["first_seen"] == "2026-10-20"
    with closing(sqlite3.connect(config.catalog_path)) as connection:
        assert connection.execute("SELECT first_seen FROM books").fetchone() == ("2026-10-20",)
    assert not indexer.run_once().rebuilt


def test_old_empty_catalog_schema_is_upgraded(tmp_path):
    library = tmp_path / "library"
    library.mkdir()
    config = Config(library_dir=library, data_dir=tmp_path / "data", files_link_root=library)
    Indexer(config).run_once()
    with closing(sqlite3.connect(config.catalog_path)) as connection:
        connection.execute("ALTER TABLE books DROP COLUMN first_seen")
        connection.commit()
    indexer = Indexer(config)
    assert indexer.run_once().rebuilt
    with closing(sqlite3.connect(config.catalog_path)) as connection:
        assert "first_seen" in {row[1] for row in connection.execute("PRAGMA table_info(books)")}
    assert not indexer.run_once().rebuilt
