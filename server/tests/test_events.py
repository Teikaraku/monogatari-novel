import hashlib
import sqlite3
from contextlib import closing

import pytest
from fastapi.testclient import TestClient

from novel import stats as module
from novel.api import create_app
from novel.stats import SCHEMA
from test_stats import log_line, rows, runner, stats_config


def event(install="INSTALL-PRIVATE-0001", book="1000", action="add"):
    return f"1729123456.789|shelf:{action}|{book}|{install}\n".encode()


@pytest.mark.parametrize("line", [
    b"bad\n", b"1|shelf:add|1000|valid-id|extra\n",
    event(action="ADD"), event(action="unknown"), event().replace(b"shelf:", b"other:"),
    event(book=""), event(book="12345678901"), event(book="-1"), event(book="1.0"), event(book="1x"),
    event().replace(b"|1000|", b"|\xff|"), event(install=""), event(install="a" * 7),
    event(install="a" * 65), event(install="invalid_1"), event(install="invalid 1"),
    event(install="中文安装标识符"), event().replace(b"PRIVATE", b"\xff"),
])
def test_invalid_events_are_ignored(stats_config, line):
    (stats_config.log_dir / "events.log").write_bytes(line)
    result = runner(stats_config).run_once()
    assert result.lines == 1 and result.shelf_changes == result.added == 0
    assert rows(stats_config, "shelf") == rows(stats_config, "shelf_total") == rows(stats_config, "meta") == []


@pytest.mark.parametrize(("install", "book"), [("aZ09-123", "1"), ("Z" * 64, "1234567890"), ("valid-id", "１０００")])
def test_valid_event_field_boundaries(stats_config, install, book):
    (stats_config.log_dir / "events.log").write_bytes(event(install=install, book=book))
    assert runner(stats_config).run_once().shelf_changes == 1
    assert rows(stats_config, "shelf_total") == [(book, 1)]


def test_event_order_deduplication_removal_and_version(stats_config):
    config = stats_config
    path = config.log_dir / "events.log"
    path.write_bytes(event() + event() + event(action="remove") + event()
                     + event(install="INSTALL-PRIVATE-0002") + event(book="2000", action="remove"))
    result = runner(config).run_once()
    assert result.lines == 6 and result.shelf_changes == 4
    assert rows(config, "shelf_total") == [("1000", 2)]
    assert len(rows(config, "shelf")) == 2
    assert dict(rows(config, "meta"))["stats_version"] == "1"
    with path.open("ab") as stream:
        stream.write(event(action="remove") * 2)
    assert runner(config).run_once().shelf_changes == 1
    assert rows(config, "shelf_total") == [("1000", 1)]
    with path.open("ab") as stream:
        stream.write(event(install="INSTALL-PRIVATE-0002", action="remove") * 2)
    assert runner(config).run_once().shelf_changes == 1
    assert rows(config, "shelf_total") == [("1000", 0)] and rows(config, "shelf") == []
    version = dict(rows(config, "meta"))["stats_version"]
    with path.open("ab") as stream:
        stream.write(event(action="remove"))
    assert runner(config).run_once().shelf_changes == 0
    assert rows(config, "shelf_total") == [("1000", 0)]
    assert dict(rows(config, "meta"))["stats_version"] == version == "3"
    with path.open("ab") as stream:
        stream.write(event() + event(action="remove"))
    assert runner(config).run_once().shelf_changes == 2
    assert rows(config, "shelf_total") == [("1000", 0)]
    assert dict(rows(config, "meta"))["stats_version"] == "4"


def test_install_salt_is_permanent_and_raw_ids_are_not_saved(stats_config, monkeypatch):
    config = stats_config
    generated = []

    def salt(size):
        generated.append(size)
        return "a" * 32

    monkeypatch.setattr(module.secrets, "token_hex", salt)
    path = config.log_dir / "events.log"
    installs = ("INSTALL-PRIVATE-0001", "INSTALL-PRIVATE-0002")
    path.write_bytes(b"".join(event(install=install) for install in installs))
    runner(config).run_once()
    assert generated == [16]
    expected = {hashlib.sha1(("a" * 32 + install).encode()).hexdigest()[:16] for install in installs}
    assert {row[0] for row in rows(config, "shelf")} == expected
    with path.open("ab") as stream:
        stream.write(event(book="1001") + event(action="remove"))
    module.Stats(config, date_provider=lambda: "2027-10-17").run_once()
    assert generated == [16] and dict(rows(config, "meta"))["install_salt"] == "a" * 32
    with closing(sqlite3.connect(config.stats_path)) as connection:
        dump = "\n".join(connection.iterdump())
    assert all(install not in dump for install in installs)
    assert rows(config, "shelf_total") == [("1000", 1), ("1001", 1)]


def test_events_rotation_and_partial_line_keep_order(stats_config):
    config = stats_config
    path = config.log_dir / "events.log"
    path.write_bytes(event() + event(action="remove")[:-1])
    stats = runner(config)
    assert stats.run_once().shelf_changes == 1
    first_cursor = rows(config, "cursor")[0]
    assert first_cursor[0] == 2 and first_cursor[2] == len(event())
    assert stats.run_once().shelf_changes == 0
    with path.open("ab") as stream:
        stream.write(b"\n")
    path.rename(config.log_dir / "events.log.1")
    path.write_bytes(event() + event(install="INSTALL-PRIVATE-0002")[:-1])
    assert stats.run_once().shelf_changes == 2
    assert rows(config, "shelf_total") == [("1000", 1)]
    cursor = rows(config, "cursor")[0]
    assert cursor[1] != first_cursor[1] and cursor[2] == len(event())
    with path.open("ab") as stream:
        stream.write(b"\n")
    assert stats.run_once().shelf_changes == 1
    assert rows(config, "shelf_total") == [("1000", 2)]
    assert stats.run_once().shelf_changes == 0


def test_events_truncation_and_missing_rotation(stats_config):
    config = stats_config
    path = config.log_dir / "events.log"
    path.write_bytes(event() * 10)
    runner(config).run_once()
    path.write_bytes(event(action="remove"))
    assert runner(config).run_once().shelf_changes == 1
    assert rows(config, "shelf_total") == [("1000", 0)]
    path.rename(config.log_dir / "events.log.1.gz")
    path.write_bytes(event())
    assert runner(config).run_once().shelf_changes == 1
    assert rows(config, "shelf_total") == [("1000", 1)]


def test_cursor_migration_keeps_old_download_cursor_and_adds_events(stats_config):
    config = stats_config
    config.data_dir.mkdir()
    downloads = config.log_dir / "files.log"
    downloads.write_bytes(b"1729123456.789|203.0.113.7|/files/1000/1.epub|200\n")
    events = config.log_dir / "events.log"
    events.write_bytes(event() + log_line(config))
    with closing(sqlite3.connect(config.stats_path)) as connection:
        connection.executescript(SCHEMA.replace("CHECK(id IN (1,2))", "CHECK(id=1)"))
        connection.execute("DROP TABLE shelf")
        connection.execute("DROP TABLE shelf_total")
        connection.execute("INSERT INTO cursor VALUES (1, ?, ?)", (downloads.stat().st_ino, 7))
        connection.execute("INSERT INTO total VALUES ('1000', 1)")
        connection.execute("INSERT INTO meta VALUES ('stats_version', '7')")
        connection.commit()
    result = runner(config).run_once()
    assert result.added == result.shelf_changes == 1 and result.lines == 2
    cursors = {row[0]: row[1:] for row in rows(config, "cursor")}
    # The download log is no longer read; its old cursor stays as it was.
    assert cursors == {1: (downloads.stat().st_ino, 7), 2: (events.stat().st_ino, events.stat().st_size)}
    assert rows(config, "total") == [("1000", 2)] and rows(config, "shelf_total") == [("1000", 1)]
    assert dict(rows(config, "meta"))["stats_version"] == "8"
    assert runner(config).run_once().lines == 0
    with closing(sqlite3.connect(config.stats_path)) as connection:
        with pytest.raises(sqlite3.IntegrityError):
            connection.execute("INSERT INTO cursor VALUES (3, 0, 0)")


def test_reads_shelf_changes_and_cursor_roll_back_together(stats_config, monkeypatch):
    config = stats_config
    (config.log_dir / "events.log").write_bytes(log_line(config) + event())
    original = module.increment_version

    def fail(connection):
        original(connection)
        raise RuntimeError("before commit")

    monkeypatch.setattr(module, "increment_version", fail)
    with pytest.raises(RuntimeError, match="before commit"):
        runner(config).run_once()
    for table in ("daily", "total", "seen", "salt", "shelf", "shelf_total", "cursor", "meta"):
        assert rows(config, table) == []
    monkeypatch.setattr(module, "increment_version", original)
    result = runner(config).run_once()
    assert result.added == result.shelf_changes == 1
    assert dict(rows(config, "meta"))["stats_version"] == "1"


def test_events_endpoint_is_empty_no_store_and_bypasses_cache(stats_config, monkeypatch):
    with TestClient(create_app(stats_config)) as client:
        def fail(*args):
            raise AssertionError("events must not access the catalog, ranks, or LRU")

        monkeypatch.setattr(client.app.state.responses, "get", fail)
        monkeypatch.setattr(client.app.state.responses, "put", fail)
        monkeypatch.setattr(client.app.state.store, "snapshot", fail)
        monkeypatch.setattr(client.app.state.rank_store, "snapshot", fail)
        for query in ("", "?type=shelf&book=1000&action=add&install=INSTALL-PRIVATE-0001"):
            response = client.get("/api/v1/events" + query, headers={"If-None-Match": "*"})
            assert response.status_code == 204 and response.content == b""
            assert response.headers["cache-control"] == "no-store" and "etag" not in response.headers
    assert not stats_config.stats_path.exists()
