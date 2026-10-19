import os
from dataclasses import dataclass, field
from pathlib import Path
from zoneinfo import ZoneInfo


@dataclass(frozen=True)
class Config:
    library_dir: Path = field(default_factory=lambda: Path(os.getenv("LIBRARY_DIR", "/library")))
    data_dir: Path = field(default_factory=lambda: Path(os.getenv("DATA_DIR", "/data")))
    files_link_root: Path | None = None
    index_interval: float = field(default_factory=lambda: float(os.getenv("INDEX_INTERVAL", "600")))
    cover_workers: int = field(default_factory=lambda: int(os.getenv("COVER_WORKERS", "4")))
    timezone: str = field(default_factory=lambda: os.getenv("TIMEZONE", "Asia/Shanghai"))
    public_base: str = field(default_factory=lambda: os.getenv("PUBLIC_BASE", ""))
    reload_check_seconds: float = field(
        default_factory=lambda: float(os.getenv("RELOAD_CHECK_SECONDS", "5"))
    )
    curation_dir: Path = field(default_factory=lambda: Path(os.getenv("CURATION_DIR", "/curation")))
    log_dir: Path = field(default_factory=lambda: Path(os.getenv("LOG_DIR", "/nginxlog")))
    stats_interval: float = field(default_factory=lambda: float(os.getenv("STATS_INTERVAL", "300")))
    rank_reload_seconds: float = field(default_factory=lambda: float(os.getenv("RANK_RELOAD_SECONDS", "300")))

    def __post_init__(self):
        if self.files_link_root is None:
            object.__setattr__(self, "files_link_root", Path(os.getenv("FILES_LINK_ROOT", str(self.library_dir))))

    @property
    def tz(self) -> ZoneInfo:
        return ZoneInfo(self.timezone)

    @property
    def catalog_path(self) -> Path:
        return self.data_dir / "catalog.sqlite"

    @property
    def stats_path(self) -> Path:
        return self.data_dir / "stats.sqlite"
