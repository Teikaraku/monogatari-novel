import io

import orjson
import pytest
from PIL import Image

from novel.config import Config
from novel.indexer import Indexer


@pytest.mark.perf
def test_indexer_performance(tmp_path, pytestconfig):
    library = tmp_path / "library"
    library.mkdir()
    image = Image.linear_gradient("L").resize((600, 900)).convert("RGB")
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG")
    cover = buffer.getvalue()
    for i in range(5101):
        title = f"测试小说{i + 1}"
        directory = library / f"{i + 1}_{title}"
        directory.mkdir()
        (directory / "meta.json").write_bytes(orjson.dumps({
            "title": title, "author": "测试作者", "status": "连载", "last_update": "2026-10-17",
            "word_count": "14.2 万", "tags": ["校园", "冒险"], "description": "描述" * 40,
        }))
        (directory / "cover.jpg").write_bytes(cover)
        for n in range(1, (4 if i < 3705 else 3) + 1):
            (directory / f"{n:02d}_{title} 第{n}卷.epub").write_bytes(b"synthetic epub")
    config = Config(library_dir=library, data_dir=tmp_path / "data", cover_workers=4)
    indexer = Indexer(config)
    full = indexer.run_once(full=True)
    unchanged = indexer.run_once()
    assert full.books == unchanged.books == 5101
    assert full.volumes == unchanged.volumes == 19008
    assert full.covers == 10202 and full.changed == 5101 and full.rebuilt
    assert unchanged.changed == unchanged.covers == 0 and not unchanged.rebuilt
    metrics = getattr(pytestconfig, "performance_metrics", {})
    metrics.update({
        "indexer full, 4 workers, 5101 JPEG covers (600x900)": f"{full.elapsed:.6f} s (< 300 s)",
        "indexer unchanged": f"{unchanged.elapsed:.6f} s (< 3 s)",
        "indexer link failures": str(full.link_failures),
    })
    pytestconfig.performance_metrics = metrics
    assert full.elapsed < 300
    assert unchanged.elapsed < 3
