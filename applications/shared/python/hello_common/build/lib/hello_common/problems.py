"""RFC 7807 (application/problem+json) errors for FastAPI services."""

from __future__ import annotations

import logging
from http import HTTPStatus
from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from .propagation import current_trace_ids

PROBLEM_CONTENT_TYPE = "application/problem+json"
log = logging.getLogger("hello_common.problems")


class Problem(Exception):
    """Raise anywhere in a request to return a problem+json response."""

    def __init__(self, status: int, title: str | None = None, detail: str | None = None, *, type_: str = "about:blank", **extensions: Any) -> None:
        self.status = int(status)
        self.title = title or HTTPStatus(self.status).phrase
        self.detail = detail
        self.type = type_
        self.extensions = extensions
        super().__init__(detail or self.title)


def problem_body(
    status: int, title: str | None = None, detail: str | None = None, *, instance: str | None = None, type_: str = "about:blank", **extensions: Any
) -> dict[str, Any]:
    body: dict[str, Any] = {"type": type_, "title": title or HTTPStatus(status).phrase, "status": status}
    if detail:
        body["detail"] = detail
    if instance:
        body["instance"] = instance
    ids = current_trace_ids()
    if ids:
        body["trace_id"] = ids[0]
    body.update({k: v for k, v in extensions.items() if v is not None})
    return body


def problem_response(
    status: int, title: str | None = None, detail: str | None = None, *, instance: str | None = None, headers: dict[str, str] | None = None, **extensions: Any
) -> JSONResponse:
    return JSONResponse(
        problem_body(status, title, detail, instance=instance, **extensions),
        status_code=status,
        media_type=PROBLEM_CONTENT_TYPE,
        headers=headers,
    )


def install_problem_handlers(app: FastAPI) -> None:
    @app.exception_handler(Problem)
    async def _problem(request: Request, exc: Problem) -> JSONResponse:
        return problem_response(exc.status, exc.title, exc.detail, instance=request.url.path, type_=exc.type, **exc.extensions)

    @app.exception_handler(StarletteHTTPException)
    async def _http(request: Request, exc: StarletteHTTPException) -> JSONResponse:
        detail = exc.detail if isinstance(exc.detail, str) else None
        return problem_response(exc.status_code, None, detail, instance=request.url.path, headers=getattr(exc, "headers", None))

    @app.exception_handler(RequestValidationError)
    async def _validation(request: Request, exc: RequestValidationError) -> JSONResponse:
        errors = [{"loc": list(e.get("loc", [])), "msg": e.get("msg"), "type": e.get("type")} for e in exc.errors()]
        return problem_response(422, "Validation failed", "request body or parameters are invalid", instance=request.url.path, errors=errors)

    @app.exception_handler(Exception)
    async def _unhandled(request: Request, exc: Exception) -> JSONResponse:
        log.exception("unhandled error", extra={"http.route": request.url.path})
        return problem_response(500, "Internal Server Error", "an unexpected error occurred", instance=request.url.path)
