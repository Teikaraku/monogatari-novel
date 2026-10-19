import hashlib
import re
from contextlib import asynccontextmanager
from urllib.parse import urlencode

import orjson
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from starlette.datastructures import MutableHeaders
from starlette.exceptions import HTTPException
from starlette.responses import Response

from .catalog import CatalogStore, LRU, current_date
from .config import Config
from .rank import BOARDS, PERIODS, RankStore
from .textnorm import query

CACHE_CONTROL = "public, max-age=60, stale-while-revalidate=600"


class API(FastAPI):
    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or not scope["path"].startswith("/api/v1/"):
            return await super().__call__(scope, receive, send)

        async def send_response(message):
            # Include 500 responses generated outside the application's middleware.
            if message["type"] == "http.response.start" and message["status"] >= 400:
                headers = MutableHeaders(scope=message)
                headers["Cache-Control"] = "no-store"
                if "ETag" in headers:
                    del headers["ETag"]
            await send(message)

        await super().__call__(scope, receive, send_response)


def normalized_request(request: Request) -> str:
    pairs = sorted(request.query_params.multi_items(), key=lambda pair: pair[0])
    return request.url.path + ("?" + urlencode(pairs) if pairs else "")


def bad_request(message="Invalid parameters"):
    raise HTTPException(status_code=400, detail=message)


def integer(request: Request, name: str, default: int | None, minimum: int, maximum: int | None = None) -> int:
    value = request.query_params.get(name)
    try:
        result = int(value) if value is not None else default
    except (ValueError, TypeError):
        bad_request(f"Invalid {name}")
    if result is None or result < minimum or (maximum is not None and result > maximum):
        bad_request(f"Invalid {name}")
    return result


def pagination(request: Request) -> tuple[int, int]:
    return integer(request, "offset", 0, 0), integer(request, "limit", 30, 1, 60)


def sorting(request: Request):
    sort = request.query_params.get("sort", "updated")
    if sort not in ("updated", "title", "words", "volumes", "random"):
        bad_request("Invalid sort")
    seed = integer(request, "seed", None, 0, 2**31 - 1) if sort == "random" else None
    return sort, seed


def create_app(config: Config | None = None, date_provider=None) -> FastAPI:
    config = config or Config()

    @asynccontextmanager
    async def lifespan(application):
        application.state.store = CatalogStore(config)
        application.state.rank_store = RankStore(config, application.state.store.catalog,
                                                 lambda: application.state.date_provider())
        application.state.rank_cache_date = application.state.rank_store.rankings.date
        try:
            yield
        finally:
            application.state.store.close()
            application.state.rank_store.close()

    application = API(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    application.state.responses = LRU(2048)
    application.state.date_provider = date_provider or (lambda: current_date(config))

    @application.middleware("http")
    async def catalog_request(request: Request, call_next):
        if request.url.path == "/api/v1/events":
            return await call_next(request)
        request.state.catalog = application.state.store.snapshot()
        request.state.date = application.state.date_provider()
        request.state.rankings = application.state.rank_store.snapshot(request.state.catalog, request.state.date)
        if application.state.rank_cache_date != request.state.rankings.date:
            # Discard old rankings cached while the new day's calculation was running.
            application.state.responses = LRU(2048)
            application.state.rank_cache_date = request.state.rankings.date
        if request.url.path.startswith("/api/v1/"):
            normalized = normalized_request(request)
            if (request.url.path in ("/api/v1/home", "/api/v1/tv", "/api/v1/rank", "/api/v1/discover")
                    or re.fullmatch(r"/api/v1/books/\d{1,10}", request.url.path)):
                normalized += "#" + request.state.date
            version = request.state.catalog.content_version
            if request.state.rankings.version:
                version += "." + request.state.rankings.version
            request.state.content_version = version
            request.state.cache_key = version, normalized
            digest = hashlib.sha1(normalized.encode("utf-8")).hexdigest()[:16]
            request.state.etag = f'W/"{version}-{digest}"'
        response = await call_next(request)
        if request.url.path.startswith("/api/v1/") and response.status_code < 400:
            response.headers["Cache-Control"] = CACHE_CONTROL
            response.headers["ETag"] = request.state.etag
        return response

    def respond(request, factory):
        if request.headers.get("if-none-match") == request.state.etag:
            return Response(status_code=304)
        cache = application.state.responses
        content = cache.get(request.state.cache_key)
        if content is None:
            content = orjson.dumps(factory())
            cache.put(request.state.cache_key, content)
        return Response(content, media_type="application/json")

    @application.exception_handler(HTTPException)
    async def http_error(request, exc):
        code = "not_found" if exc.status_code == 404 else "bad_request"
        message = "Not found" if exc.status_code == 404 else str(exc.detail)
        return Response(orjson.dumps({"error": {"code": code, "message": message}}),
                        status_code=exc.status_code, media_type="application/json")

    @application.exception_handler(RequestValidationError)
    async def validation_error(request, exc):
        return await http_error(request, HTTPException(400, "Invalid parameters"))

    @application.exception_handler(Exception)
    async def internal_error(request, exc):
        return Response(orjson.dumps({"error": {"code": "internal", "message": "Internal error"}}),
                        status_code=500, media_type="application/json", headers={"Cache-Control": "no-store"})

    @application.get("/api/v1/meta")
    async def meta(request: Request):
        return respond(request, lambda: {**request.state.catalog.meta, "content_version": request.state.content_version})

    @application.get("/api/v1/events")
    async def events():
        return Response(status_code=204, headers={"Cache-Control": "no-store"})

    @application.get("/api/v1/home")
    async def home(request: Request):
        return respond(request, lambda: request.state.catalog.home(request.state.date, request.state.rankings))

    @application.get("/api/v1/discover")
    async def discover(request: Request):
        return respond(request, lambda: request.state.catalog.discover(request.state.date))

    @application.get("/api/v1/themes/{key}")
    async def theme(key: str, request: Request):
        offset, limit = pagination(request)
        sort, seed = sorting(request)
        if not any(item["key"] == key for item in request.state.catalog.themes):
            raise HTTPException(404, "Not found")
        return respond(request, lambda: request.state.catalog.theme_listing(key, sort, seed, offset, limit))

    @application.get("/api/v1/rank")
    async def rank(request: Request):
        offset, limit = pagination(request)
        board = request.query_params.get("board", "popular")
        if board not in BOARDS:
            bad_request("Invalid board")
        period = request.query_params.get("period")
        if board in ("popular", "completed"):
            if period not in PERIODS:
                bad_request("Invalid period")
        else:
            period = None
        return respond(request, lambda: request.state.rankings.listing(period, offset, limit, board=board))

    @application.get("/api/v1/tv")
    async def tv(request: Request):
        offset, limit = pagination(request)
        section = request.query_params.get("section")
        if section not in ("airing", "upcoming", "completed"):
            bad_request("Invalid section")
        return respond(request, lambda: request.state.catalog.tv_listing(section, request.state.date, offset, limit))

    @application.get("/api/v1/books")
    async def books(request: Request):
        offset, limit = pagination(request)
        tags = request.query_params.getlist("tag")
        status = request.query_params.get("status")
        sort, seed = sorting(request)
        if len(tags) > 3:
            bad_request("Too many tags")
        if status is not None and status not in ("completed", "ongoing"):
            bad_request("Invalid status")
        bounds = {name: integer(request, name, None, 1, 9999) if name in request.query_params else None
                  for name in ("min_volumes", "max_volumes")}
        if bounds["min_volumes"] is not None and bounds["max_volumes"] is not None and bounds["min_volumes"] > bounds["max_volumes"]:
            bad_request("Invalid volume range")
        with_description = request.query_params.get("with_description", "0")
        if with_description not in ("0", "1"):
            bad_request("Invalid with_description")
        return respond(request, lambda: request.state.catalog.listing(
            tags, status, sort, seed, offset, limit, **bounds, with_description=with_description == "1"))

    @application.get("/api/v1/search")
    async def search(request: Request):
        offset, limit = pagination(request)
        q = request.query_params.get("q")
        if q is None or not 1 <= len(query(q)) <= 64:
            bad_request("Invalid q")
        return respond(request, lambda: request.state.catalog.search(q, offset, limit))

    @application.get("/api/v1/tags")
    async def tags(request: Request):
        covers = integer(request, "covers", 0, 0, 4)
        return respond(request, lambda: request.state.catalog.tag_listing(covers, request.state.rankings))

    @application.get("/api/v1/books/{id}")
    async def book_detail(id: str, request: Request):
        if re.fullmatch(r"\d{1,10}", id) is None:
            bad_request("Invalid id")
        if id not in request.state.catalog.books:
            raise HTTPException(404, "Not found")
        return respond(request, lambda: request.state.catalog.detail(id, request.state.date))

    @application.get("/api/v1/books/{id}/volumes/{n}/toc")
    async def volume_toc(id: str, n: int, request: Request):
        if re.fullmatch(r"\d{1,10}", id) is None:
            bad_request("Invalid id")
        book = request.state.catalog.books.get(id)
        if book is None or not any(volume["n"] == n for volume in book["volume_list"]):
            raise HTTPException(404, "Not found")
        return respond(request, lambda: request.state.catalog.volume_toc(id, n))

    @application.get("/healthz")
    async def health(request: Request):
        return Response(orjson.dumps({"ok": True, "version": request.state.catalog.version}),
                        media_type="application/json", headers={"Cache-Control": "no-store"})

    return application


app = create_app()
