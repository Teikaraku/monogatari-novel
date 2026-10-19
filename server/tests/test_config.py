from pathlib import Path

from novel.config import Config


def test_defaults(monkeypatch):
    for name in ("LIBRARY_DIR", "DATA_DIR", "FILES_LINK_ROOT", "INDEX_INTERVAL", "COVER_WORKERS", "TIMEZONE",
                 "PUBLIC_BASE", "RELOAD_CHECK_SECONDS", "CURATION_DIR", "LOG_DIR", "STATS_INTERVAL", "RANK_RELOAD_SECONDS"):
        monkeypatch.delenv(name, raising=False)
    config = Config()
    assert config.library_dir == config.files_link_root == Path("/library")
    assert config.data_dir == Path("/data")
    assert config.index_interval == 600 and config.cover_workers == 4
    assert config.timezone == "Asia/Shanghai" and config.public_base == "" and config.reload_check_seconds == 5
    assert config.curation_dir == Path("/curation") and config.log_dir == Path("/nginxlog")
    assert config.stats_interval == 60 and config.rank_reload_seconds == 15


def test_environment(monkeypatch, tmp_path):
    values = {"LIBRARY_DIR": str(tmp_path / "library"), "DATA_DIR": str(tmp_path / "data"),
              "FILES_LINK_ROOT": str(tmp_path / "host"), "INDEX_INTERVAL": "12", "COVER_WORKERS": "2",
              "TIMEZONE": "UTC", "PUBLIC_BASE": "https://example.test", "RELOAD_CHECK_SECONDS": "0",
              "CURATION_DIR": str(tmp_path / "curation"), "LOG_DIR": str(tmp_path / "logs"),
              "STATS_INTERVAL": "12", "RANK_RELOAD_SECONDS": "0"}
    for key, value in values.items():
        monkeypatch.setenv(key, value)
    config = Config()
    assert config.library_dir == tmp_path / "library" and config.data_dir == tmp_path / "data"
    assert config.files_link_root == tmp_path / "host" and config.index_interval == 12 and config.cover_workers == 2
    assert config.timezone == "UTC" and config.public_base == "https://example.test" and config.reload_check_seconds == 0
    assert config.curation_dir == tmp_path / "curation" and config.log_dir == tmp_path / "logs"
    assert config.stats_interval == 12 and config.rank_reload_seconds == 0


def test_real_iana_timezone():
    from datetime import datetime, timedelta
    from zoneinfo import ZoneInfo
    zone = ZoneInfo("Asia/Shanghai")
    assert datetime(2026, 10, 17, tzinfo=zone).utcoffset() == timedelta(hours=8)
    assert datetime(1990, 7, 1, tzinfo=zone).utcoffset() == timedelta(hours=9)
