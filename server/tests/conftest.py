import os
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

import orjson
import pytest
from PIL import Image

from novel.config import Config
from novel.indexer import Indexer


def pytest_configure(config):
    config.addinivalue_line("markers", "perf: required catalog performance checks")
    if config.option.basetemp is None:
        config.option.basetemp = str(Path(__file__).resolve().parents[1] / ".pytest-tmp")


def pytest_terminal_summary(terminalreporter):
    metrics = getattr(terminalreporter.config, "performance_metrics", {})
    if metrics:
        terminalreporter.write_sep("-", "Measured performance")
        for key, value in metrics.items():
            terminalreporter.write_line(f"{key}: {value}")


@pytest.fixture
def mini_library(tmp_path):
    library = tmp_path / "library"
    library.mkdir()
    directories = {}
    timestamp = datetime(2024, 1, 1, 18, 0, tzinfo=timezone.utc).timestamp()

    def add(book_id, title, filenames, meta=None, cover=None):
        directory = library / f"{book_id}_{title}"
        directory.mkdir()
        directories[book_id] = directory
        for i, filename in enumerate(filenames):
            path = directory / filename
            path.write_bytes(b"epub fixture" * (i + 1))
            os.utime(path, (timestamp - i * 86400, timestamp - i * 86400))
        if meta is not None:
            (directory / "meta.json").write_bytes(orjson.dumps(meta))
        if cover:
            filename, mode, size, color = cover
            Image.new(mode, size, color).save(directory / filename)
        return directory

    title = "圈、叉与三角——王牌，就此展开"
    normal = add("1000", title, [f"02_{title} 2 决赛.epub", f"01_{title} 1 乱七八糟湿透了的赛璐璐.epub"], {
        "id": "wrong", "title": "  " + title + "  ", "author": " 月本一 ", "illustrator": " 插画师 ",
        "publisher": " Fami通文库 ", "status": "完结", "word_count": "14.2 万", "chapter_count": "8",
        "last_update": "2020-02-22", "tags": ["校园", "竞技", "青春", "恋爱", "青梅竹马", "第六标签", "校园", " ", 3],
        "description": " 描述" + "很长的故事" * 30 + " ", "volume_count": 999,
    }, ("cover.jpg", "RGB", (800, 1200), "red"))
    for name in ("01_fake.epub.rev", "02_fake.epub.bak", "03_fake.epub.skipped", "index.html"):
        (normal / name).write_bytes(b"ignored")
    add("01001", "无元数据", ["02_无元数据 终.epub"])
    broken = add("1002", "损坏元数据", ["01_损坏元数据.epub"])
    (broken / "meta.json").write_bytes(b"{bad json")
    add("1003", "没有卷", [], {"title": "不收录"}, ("cover.jpg", "RGB", (10, 10), "blue"))
    add("1004", "为了N", ["01_为了女 1.epub"], {"title": "为了N"})
    add("1005", "X", ["03_X.epub"], {"title": "X"})
    add("1006", "ＡＢＣ　之旅", ["01_abc 之旅—_： 1.epub"], {
        "title": "ＡＢＣ　之旅", "status": "连载", "word_count": "123456", "tags": [" 恋爱 ", "恋爱", "旅行"],
        "author": 3, "illustrator": None, "publisher": [], "description": {},
    }, ("cover.png", "RGBA", (160, 80), (0, 0, 255, 0)))
    bad_cover = add("1007", "坏封面", ["01_坏封面.epub"], {
        "status": "", "word_count": "未知", "chapter_count": "bad", "tags": "wrong",
    })
    (bad_cover / "cover.jpg").write_bytes(b"not an image")
    custom = add("1008", "封面优先", ["01_封面优先.epub"], {"cover_file": "custom.png"},
                 ("custom.png", "RGB", (320, 160), "green"))
    Image.new("RGB", (900, 600), "blue").save(custom / "cover.jpg")
    for name in ("_quarantine_x", ".incoming", "_archived_removed", "abc_book"):
        directory = library / name
        directory.mkdir()
        (directory / "01_ignored.epub").write_bytes(b"ignored")
    (library / "_index.log").write_text("ignored", encoding="utf-8")
    (library / "999_rootfile").write_text("ignored", encoding="utf-8")
    config = Config(library_dir=library, data_dir=tmp_path / "data", files_link_root=tmp_path / "host-library")
    return SimpleNamespace(config=config, directories=directories, timestamp=timestamp)


@pytest.fixture
def built_library(mini_library):
    indexer = Indexer(mini_library.config)
    stats = indexer.run_once()
    return SimpleNamespace(**vars(mini_library), indexer=indexer, stats=stats)


@pytest.fixture
def symlinks_available(tmp_path):
    target = tmp_path / "target"
    link = tmp_path / "link"
    target.write_bytes(b"test")
    try:
        link.symlink_to(target)
    except OSError:
        pytest.skip("This platform does not permit symbolic links")
    link.unlink()


def synthetic_book(book_id, **overrides):
    book = {
        "id": str(book_id), "directory": f"{book_id}_fixture", "title": f"故事{book_id}",
        "author": "作者", "illustrator": "画师", "publisher": "文库", "status": "ongoing",
        "words": 100000, "chapters": 8, "updated": "2024-01-01", "description": "故事内容" * 30,
        "first_seen": "2024-01-01",
        "tags": ["校园", "冒险"], "volume_count": 2, "cover_key": "0123456789ab",
        "sort_title": f"gu shi {book_id}", "pinyin_full": f"gushi{book_id}", "pinyin_initials": f"gs{book_id}",
        "volume_list": [{"n": n, "label": f"第{n}卷", "file": f"{n}_fixture.epub", "size": 10, "mtime": 1700000000}
                        for n in range(1, 3)],
    }
    book.update(overrides)
    if "volume_list" in overrides:
        book["volume_count"] = len(book["volume_list"])
    return book
