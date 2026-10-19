import pytest

from novel.indexer import Indexer
from test_toc import library_config, write_epub


@pytest.mark.perf
def test_2000_epubs_full_and_unchanged_performance(tmp_path, pytestconfig):
    config = library_config(tmp_path)
    for book_id in range(1, 101):
        directory = config.library_dir / f"{book_id}_book"
        directory.mkdir()
        for n in range(1, 21):
            write_epub(directory / f"{n:02d}_book.epub")
    indexer = Indexer(config)
    full = indexer.run_once(full=True)
    unchanged = indexer.run_once()
    assert full.books == unchanged.books == 100
    assert full.volumes == unchanged.volumes == 2000
    assert full.rebuilt and not unchanged.rebuilt
    metrics = getattr(pytestconfig, "performance_metrics", {})
    metrics.update({
        "TOC full, 2000 small EPUBs, 4 workers": f"{full.elapsed:.6f} s (< 30 s)",
        "TOC unchanged, 2000 small EPUBs": f"{unchanged.elapsed:.6f} s (< 3 s)",
    })
    pytestconfig.performance_metrics = metrics
    assert full.elapsed < 30
    assert unchanged.elapsed < 3
