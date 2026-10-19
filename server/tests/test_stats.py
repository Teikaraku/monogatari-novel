import os
import signal
import sqlite3
import subprocess
import sys
from contextlib import closing
from datetime import datetime, timedelta

import pytest

from novel import stats as module
from novel.catalog import Catalog
from novel.config import Config
from novel.rank import load_rankings
from novel.stats import Stats
from conftest import synthetic_book


@pytest.fixture
def stats_config(tmp_path):
    logs = tmp_path / "logs"
    logs.mkdir()
    return Config(data_dir=tmp_path / "data", log_dir=logs)


def log_line(config, install="install-0001", book="1000", day="2026-10-17", action="read:open"):
    """One events.log line as nginx writes it: msec|type:action|book|install."""
    stamp = datetime.fromisoformat(day).replace(hour=12, tzinfo=config.tz).timestamp()
    return f"{stamp:.3f}|{action}|{book}|{install}\n".encode()


def rows(config, table):
    with closing(sqlite3.connect(config.stats_path)) as connection:
        return connection.execute(f"SELECT * FROM {table}").fetchall()


def runner(config):
    return Stats(config, date_provider=lambda: "2026-10-17")


def test_parsing_and_partial_lines(stats_config):
    config = stats_config
    valid = log_line(config)
    partial = log_line(config, install="install-0002")[:-1]
    invalid = [b"invalid\n", valid.replace(b"read:open", b"read:close"), valid.replace(b"read:open", b"READ:open"),
               valid.replace(b"|1000|", b"|12345678901|"), valid.replace(b"|1000|", b"|10x|"),
               valid.replace(b"install-0001", b"short"), valid.replace(b"install-0001", b"bad_install"),
               valid[:-1] + b"|extra\n", b"nan|read:open|1|install-0001\n",
               b"inf|read:open|1|install-0001\n", b"bad|read:open|1|install-0001\n"]
    complete = valid + b"".join(invalid)
    path = config.log_dir / "events.log"
    path.write_bytes(complete + partial)
    result = runner(config).run_once()
    assert result.added == 1 and result.lines == len(invalid) + 1
    assert rows(config, "cursor")[0][2] == len(complete)
    assert rows(config, "total") == [("1000", 1)]
    assert runner(config).run_once().added == 0
    with path.open("ab") as stream:
        stream.write(b"\n")
    assert runner(config).run_once().added == 1
    assert rows(config, "cursor")[0][2] == path.stat().st_size
    assert rows(config, "total") == [("1000", 2)]


def test_deduplication_real_timezone_and_privacy(stats_config):
    config = stats_config
    path = config.log_dir / "events.log"
    lines = [log_line(config), log_line(config), log_line(config, day="2026-10-16"),
             log_line(config, install="install-0002"), log_line(config, book="1001"),
             log_line(config, action="shelf:add")]
    path.write_bytes(b"".join(lines))
    result = runner(config).run_once()
    assert result.added == 4 and result.shelf_changes == 1
    assert rows(config, "daily") == [("2026-10-16", "1000", 1), ("2026-10-17", "1000", 2), ("2026-10-17", "1001", 1)]
    assert rows(config, "total") == [("1000", 3), ("1001", 1)]
    meta = dict(rows(config, "meta"))
    assert len(meta["install_salt"]) == 32 and meta["stats_version"] == "1"
    assert all(len(row[2]) == 16 for row in rows(config, "seen"))
    with closing(sqlite3.connect(config.stats_path)) as connection:
        assert connection.execute("PRAGMA journal_mode").fetchone()[0] == "delete"
        dump = "\n".join(connection.iterdump())
    assert "install-0001" not in dump and "install-0002" not in dump
    version = rows(config, "meta")
    assert runner(config).run_once().added == 0
    assert rows(config, "meta") == version


def test_log_date_uses_configured_timezone(stats_config):
    config = stats_config
    utc_midnight_boundary = datetime.fromisoformat("2026-10-16T16:00:00+00:00").timestamp()
    (config.log_dir / "events.log").write_bytes(f"{utc_midnight_boundary}|read:open|1|install-0001\n".encode())
    runner(config).run_once()
    assert rows(config, "daily") == [("2026-10-17", "1", 1)]


def test_book_digit_regex_and_invalid_utf8(stats_config):
    config = stats_config
    valid = log_line(config, book="１０００")
    invalid = log_line(config).replace(b"|1000|", b"|\xff|")
    (config.log_dir / "events.log").write_bytes(valid + invalid)
    assert runner(config).run_once().added == 1
    assert rows(config, "total") == [("１０００", 1)]


def test_download_log_no_longer_counts_readers(stats_config):
    config = stats_config
    stamp = datetime.fromisoformat("2026-10-17").replace(hour=12, tzinfo=config.tz).timestamp()
    (config.log_dir / "files.log").write_bytes(f"{stamp:.3f}|203.0.113.7|/files/1000/1.epub|200\n".encode())
    result = runner(config).run_once()
    assert result.added == result.lines == 0
    assert rows(config, "total") == [] and rows(config, "cursor") == []


def test_rotation_reads_old_tail_and_new_file(stats_config):
    config = stats_config
    path = config.log_dir / "events.log"
    path.write_bytes(log_line(config))
    stats = runner(config)
    stats.run_once()
    old_inode = rows(config, "cursor")[0][1]
    with path.open("ab") as stream:
        stream.write(log_line(config, install="install-0002"))
    path.rename(config.log_dir / "events.log.1")
    path.write_bytes(log_line(config, install="install-0003") + log_line(config))
    result = stats.run_once()
    assert result.added == 2 and rows(config, "total") == [("1000", 3)]
    assert rows(config, "cursor")[0][1] != old_inode
    assert stats.run_once().added == 0
    assert rows(config, "total") == [("1000", 3)]


def test_truncation_restarts_at_zero(stats_config):
    config = stats_config
    path = config.log_dir / "events.log"
    path.write_bytes(log_line(config) * 10)
    stats = runner(config)
    stats.run_once()
    path.write_bytes(log_line(config, install="install-0002"))
    assert stats.run_once().added == 1
    assert rows(config, "total") == [("1000", 2)]
    assert rows(config, "cursor")[0][2] == path.stat().st_size


def test_retention_preserves_total(stats_config):
    config = stats_config
    today = datetime.fromisoformat("2026-10-17")
    days = [(today - timedelta(days=age)).date().isoformat() for age in (36, 35, 34)]
    (config.log_dir / "events.log").write_bytes(b"".join(log_line(config, day=day) for day in days))
    runner(config).run_once()
    for table in ("seen", "daily"):
        assert {row[0] for row in rows(config, table)} == set(days[1:])
    assert rows(config, "total") == [("1000", 3)]


def test_transaction_rolls_back_counts_and_cursor(stats_config, monkeypatch):
    config = stats_config
    path = config.log_dir / "events.log"
    path.write_bytes(log_line(config))
    stats = runner(config)
    stats.run_once()
    before = {table: rows(config, table) for table in ("seen", "daily", "total", "meta", "cursor")}
    with path.open("ab") as stream:
        stream.write(log_line(config, install="install-0002", day="2026-10-15"))
    original = module.increment_version

    def fail(connection):
        original(connection)
        raise RuntimeError("failure before commit")

    monkeypatch.setattr(module, "increment_version", fail)
    with pytest.raises(RuntimeError, match="before commit"):
        stats.run_once()
    assert {table: rows(config, table) for table in before} == before
    monkeypatch.setattr(module, "increment_version", original)
    assert stats.run_once().added == 1
    assert dict(rows(config, "meta"))["stats_version"] == "2"


def test_version_increments_once_per_round_with_new_readers(stats_config):
    config = stats_config
    path = config.log_dir / "events.log"
    path.write_bytes(b"")
    stats = runner(config)
    assert stats.run_once().added == 0
    assert rows(config, "meta") == []
    for expected in ("1", "2", "3"):
        with path.open("ab") as stream:
            stream.write(log_line(config, install=f"install-{int(expected) * 2:04d}"))
            stream.write(log_line(config, install=f"install-{int(expected) * 2 + 1:04d}"))
        # Reopening the service must continue the persisted sequence.
        stats = runner(config)
        assert stats.run_once().added == 2
        assert dict(rows(config, "meta"))["stats_version"] == expected
        with path.open("ab") as stream:
            stream.write(log_line(config, install=f"install-{int(expected) * 2:04d}"))
        assert stats.run_once().added == 0
        assert dict(rows(config, "meta"))["stats_version"] == expected


@pytest.mark.parametrize("old_version", ["9", "20261017000000", str(2**63 - 1)])
def test_version_increments_existing_integer_string(stats_config, old_version):
    config = stats_config
    path = config.log_dir / "events.log"
    path.write_bytes(b"")
    runner(config).run_once()
    with closing(sqlite3.connect(config.stats_path)) as connection:
        connection.execute("INSERT INTO meta VALUES ('stats_version', ?)", (old_version,))
        connection.commit()
    path.write_bytes(log_line(config))
    assert runner(config).run_once().added == 1
    assert dict(rows(config, "meta"))["stats_version"] == str(int(old_version) + 1)


@pytest.mark.parametrize("signum", [signal.SIGINT, signal.SIGTERM])
def test_stats_signal_finishes_round(monkeypatch, signum):
    handlers, calls = {}, []
    monkeypatch.setattr(signal, "signal", lambda number, handler: handlers.update({number: handler}))

    def run(self):
        calls.append("start")
        handlers[signum](None, None)
        calls.append("finish")

    monkeypatch.setattr(Stats, "run_once", run)
    assert module.main([]) == 0 and calls == ["start", "finish"]


def test_stats_cli_once(stats_config):
    config = stats_config
    (config.log_dir / "events.log").write_bytes(log_line(config))
    env = {**os.environ, "DATA_DIR": str(config.data_dir), "LOG_DIR": str(config.log_dir)}
    result = subprocess.run([sys.executable, "-m", "novel.stats", "--once"], env=env,
                            capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stderr
    assert "added=1" in result.stderr and rows(config, "total") == [("1000", 1)]


@pytest.mark.parametrize("existing_wal", [False, True])
def test_closed_stats_database_is_readable_without_sidecars(stats_config, existing_wal):
    config = stats_config
    if existing_wal:
        config.data_dir.mkdir()
        with closing(sqlite3.connect(config.stats_path)) as connection:
            assert connection.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
    (config.log_dir / "events.log").write_bytes(log_line(config))
    stats = runner(config)
    stats.run_once()
    assert not config.stats_path.with_name("stats.sqlite-wal").exists()
    assert not config.stats_path.with_name("stats.sqlite-shm").exists()
    with closing(sqlite3.connect(config.stats_path.as_uri() + "?mode=ro", uri=True)) as connection:
        assert connection.execute("PRAGMA journal_mode").fetchone()[0] == "delete"
        assert connection.execute("SELECT readers FROM total").fetchone()[0] == 1
        with pytest.raises(sqlite3.OperationalError, match="readonly"):
            connection.execute("DELETE FROM total")
    catalog = Catalog(config, {}, {"1000": synthetic_book(1000)})
    rankings = load_rankings(config, catalog, "2026-10-17")
    for items in rankings.items.values():
        assert [(item["id"], item["readers"]) for item in items] == [("1000", 1)]
    assert stats.run_once().added == 0
