import logging
import posixpath
import sqlite3
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import unquote, urlsplit
from xml.etree.ElementTree import TreeBuilder
from xml.parsers import expat
from zipfile import BadZipFile, ZipFile

import orjson

logger = logging.getLogger(__name__)
EPUB_TYPE = "{http://www.idpf.org/2007/ops}type"
CACHE_SCHEMA = """
CREATE TABLE IF NOT EXISTS toc_cache(
    book_id TEXT, n INTEGER, size INTEGER, mtime INTEGER, entries_json TEXT, ok INTEGER,
    PRIMARY KEY(book_id, n)
);
"""


def _xml(content: bytes):
    builder = TreeBuilder()
    parser = expat.ParserCreate(namespace_separator="}")
    parser.buffer_text = True

    def name(value):
        return "{" + value if "}" in value else value

    def reject_entity(*_):
        raise ValueError("XML entities are disabled")

    parser.StartElementHandler = lambda tag, attrs: builder.start(
        name(tag), {name(key): value for key, value in attrs.items()})
    parser.EndElementHandler = lambda tag: builder.end(name(tag))
    parser.CharacterDataHandler = builder.data
    parser.EntityDeclHandler = reject_entity
    parser.ExternalEntityRefHandler = reject_entity
    parser.SetParamEntityParsing(expat.XML_PARAM_ENTITY_PARSING_NEVER)
    parser.Parse(content, True)
    return builder.close()


def _local(element):
    return element.tag.rsplit("}", 1)[-1]


def _children(element, name):
    return [child for child in element if _local(child) == name]


def _path(base: str, href: str) -> str:
    parts = urlsplit(href.replace("\\", "/"))
    if parts.scheme or parts.netloc:
        raise ValueError("TOC target is outside the EPUB archive")
    path = posixpath.normpath(posixpath.join(posixpath.dirname(base), parts.path))
    if path == ".." or path.startswith("../") or path.startswith("/"):
        raise ValueError("TOC target is outside the EPUB archive")
    if not parts.path:
        path = base
    return path + ("?" + parts.query if parts.query else "") + ("#" + parts.fragment if parts.fragment else "")


def _document(archive, base, href):
    path = _path(base, href)
    return path, _xml(archive.read(unquote(urlsplit(path).path)))


def _entry(title: str, href: str, level: int, base: str):
    title = " ".join(title.split())[:120]
    return {"title": title, "href": _path(base, href), "level": level} if title else None


def _nav_entries(nav, base):
    def walk(ordered, level):
        for item in _children(ordered, "li"):
            for child in item:
                if _local(child) == "a":
                    entry = _entry("".join(child.itertext()), child.get("href", ""), level, base)
                    if entry is not None:
                        yield entry
                elif _local(child) == "ol":
                    yield from walk(child, level + 1)

    for ordered in _children(nav, "ol"):
        yield from walk(ordered, 0)


def _ncx_entries(nav_map, base):
    def walk(parent, level):
        for item in _children(parent, "navPoint"):
            labels = _children(item, "navLabel")
            content = _children(item, "content")
            if labels and content:
                text = " ".join("".join(child.itertext()) for child in _children(labels[0], "text"))
                entry = _entry(text, content[0].get("src", ""), level, base)
                if entry is not None:
                    yield entry
            yield from walk(item, level + 1)

    yield from walk(nav_map, 0)


def extract_toc(path: Path) -> list[dict] | None:
    """Return None for unreadable files so a later round can retry them."""
    try:
        with ZipFile(path) as archive:
            container = _xml(archive.read("META-INF/container.xml"))
            rootfile = next(node for node in container.iter() if _local(node) == "rootfile")
            opf_path, opf = _document(archive, "", rootfile.attrib["full-path"])
            manifest = next(node for node in opf if _local(node) == "manifest")
            items = _children(manifest, "item")
            nav_item = next((item for item in items if "nav" in item.get("properties", "").split()), None)
            if nav_item is not None:
                nav_path, root = _document(archive, opf_path, nav_item.attrib["href"])
                navs = [node for node in root.iter() if _local(node) == "nav"]
                nav = next((node for node in navs if "toc" in node.get(EPUB_TYPE, "").split()), None)
                if nav is None:
                    nav = navs[0]
                entries = _nav_entries(nav, nav_path)
            else:
                spine = next((node for node in opf if _local(node) == "spine"), None)
                toc_id = spine.get("toc") if spine is not None else None
                ncx = next((item for item in items if toc_id and item.get("id") == toc_id), None)
                if ncx is None:
                    ncx = next(item for item in items if item.get("media-type") == "application/x-dtbncx+xml")
                ncx_path, root = _document(archive, opf_path, ncx.attrib["href"])
                nav_map = next(node for node in root.iter() if _local(node) == "navMap")
                entries = _ncx_entries(nav_map, ncx_path)
            result = []
            for entry in entries:
                result.append(entry)
                if len(result) == 500:
                    break
            if not result:
                raise ValueError("TOC is empty")
            return result
    except OSError:
        return None
    except Exception as exc:
        # ZipFile wraps OSError while reading the central directory as BadZipFile.
        if isinstance(exc, BadZipFile) and isinstance(exc.__context__, OSError):
            return None
        logger.warning("Cannot extract TOC from %s: %s", path, exc)
        return []


def sync_toc(config, books: dict[str, dict], sources: dict) -> bool:
    connection = sqlite3.connect(config.data_dir / "toc_cache.sqlite")
    try:
        connection.executescript(CACHE_SCHEMA)
        if "ok" not in {row[1] for row in connection.execute("PRAGMA table_info(toc_cache)")}:
            connection.execute("ALTER TABLE toc_cache ADD COLUMN ok INTEGER")
        present = {(book_id, volume["n"]) for book_id, book in books.items() for volume in book["volume_list"]}
        pending = {}
        for book_id, book in books.items():
            source = sources.get(book_id)
            if source is None:
                continue
            files = dict(source.volumes)
            for volume in book["volume_list"]:
                info = files.get(volume["file"])
                if info is None:
                    continue
                key = (book_id, volume["n"])
                pending[key] = ((info.st_size, info.st_mtime_ns), source.directory / volume["file"], None)
        cached_keys = set()
        verified = []
        for book_id, n, size, mtime, encoded, ok in connection.execute(
                "SELECT book_id, n, size, mtime, entries_json, ok FROM toc_cache"):
            key = (book_id, n)
            cached_keys.add(key)
            if key not in pending and ok == 1:
                continue
            try:
                entries = orjson.loads(encoded)
            except ValueError:
                logger.warning("Ignoring invalid TOC cache for %s volume %s", *key)
            else:
                if ok != 1 and entries:
                    verified.append(key)
                    ok = 1
                if key not in pending:
                    continue
                signature, path, _ = pending[key]
                if signature == (size, mtime) and ok == 1:
                    del pending[key]
                else:
                    pending[key] = (signature, path, entries)
        connection.executemany("UPDATE toc_cache SET ok=1 WHERE book_id=? AND n=?", verified)
        removed = cached_keys - present
        changed = bool(removed)
        unreadable = 0
        unreadable_example = None
        if pending:
            logger.info("Extracting TOCs: 0/%d volumes (4 workers)", len(pending))
            with ThreadPoolExecutor(max_workers=4, thread_name_prefix="toc-extract") as pool:
                futures = {pool.submit(extract_toc, path): (key, signature, previous)
                           for key, (signature, path, previous) in pending.items()}
                for completed, future in enumerate(as_completed(futures), 1):
                    key, signature, previous = futures[future]
                    entries = future.result()
                    if entries is None:
                        unreadable += 1
                        if unreadable_example is None:
                            unreadable_example = pending[key][1]
                        # Discard any obsolete result, but never persist a read failure.
                        removed.add(key)
                        changed |= key in cached_keys
                    else:
                        changed |= entries != previous
                        connection.execute(
                            "INSERT OR REPLACE INTO toc_cache "
                            "(book_id, n, size, mtime, entries_json, ok) VALUES (?, ?, ?, ?, ?, 1)",
                            (*key, *signature, orjson.dumps(entries).decode()))
                    if completed % 100 == 0 or completed == len(pending):
                        logger.info("Extracting TOCs: %d/%d volumes", completed, len(pending))
        if unreadable:
            logger.warning("%d 个卷无法读取，例如 %s", unreadable, unreadable_example)
        connection.executemany("DELETE FROM toc_cache WHERE book_id=? AND n=?", removed)
        connection.commit()
        return changed
    finally:
        connection.close()


def load_cached_toc(config, books: dict[str, dict]):
    volumes = {}
    for book_id, book in books.items():
        for volume in book["volume_list"]:
            volume["toc"] = []
            volumes[book_id, volume["n"]] = volume
    connection = sqlite3.connect((config.data_dir / "toc_cache.sqlite").resolve().as_uri() + "?mode=ro", uri=True)
    try:
        for book_id, n, encoded in connection.execute("SELECT book_id, n, entries_json FROM toc_cache"):
            volume = volumes.get((book_id, n))
            if volume is not None:
                volume["toc"] = orjson.loads(encoded)
    finally:
        connection.close()
