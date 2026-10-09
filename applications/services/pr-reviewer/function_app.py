"""eh-pr-reviewer - Azure Functions Python v2 programming model (Flex Consumption, Python 3.13).

Functions
  ado_webhook   HTTP POST /api/ado-webhook. auth_level ANONYMOUS at the Functions level on purpose: Azure DevOps
                service hooks authenticate with HTTP Basic (webhook secret from Delinea DSV), validated in constant
                time by tools.review.webhook before anything else is read. Returns 202 after enqueueing.
  review_worker Storage queue trigger (%REVIEW_QUEUE_NAME%, identity-based connection "ReviewQueue":
                ReviewQueue__queueServiceUri / __credential=managedidentity / __clientId). Retries with the host's
                visibility back-off (host.json), poison queue after maxDequeueCount.
  healthz / readyz / version  HTTP GET.
Deployed only from `main` by the platform pipeline (never from a PR build). It never executes PR code.
"""

import json
import logging
import os

import azure.functions as func
from pr_reviewer import bootstrap

bootstrap.configure()

from pr_reviewer import handlers  # noqa: E402 - needs bootstrap.ensure_path()
from pr_reviewer.settings import Settings  # noqa: E402

log = logging.getLogger("pr_reviewer")
app = func.FunctionApp()
_settings = Settings.from_env()
_queue = None
_lease = None


def _json(status: int, body: dict) -> func.HttpResponse:
    return func.HttpResponse(json.dumps(body), status_code=status, mimetype="application/json")


def _q():
    global _queue
    if _queue is None:
        _queue = handlers.StorageQueue(_settings)
    return _queue


def _l():
    global _lease
    if _lease is None and _settings.lock_container_uri:
        _lease = handlers.BlobLease(_settings)
    return _lease


@app.function_name(name="ado_webhook")
@app.route(route="ado-webhook", methods=["POST"], auth_level=func.AuthLevel.ANONYMOUS)
def ado_webhook(req: func.HttpRequest) -> func.HttpResponse:
    status, body = handlers.webhook(req.get_body(), req.headers.get("Authorization"), _settings, _q())
    return _json(status, body)


@app.function_name(name="review_worker")
@app.queue_trigger(arg_name="msg", queue_name="%REVIEW_QUEUE_NAME%", connection="ReviewQueue")
def review_worker(msg: func.QueueMessage) -> None:
    out = handlers.process_message(msg.get_body().decode("utf-8"), _settings, _q(), lease=_l())
    log.info("review job done", extra={k: v for k, v in out.items() if k != "actions"})


@app.function_name(name="healthz")
@app.route(route="healthz", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def healthz(req: func.HttpRequest) -> func.HttpResponse:
    return _json(*handlers.health())


@app.function_name(name="readyz")
@app.route(route="readyz", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def readyz(req: func.HttpRequest) -> func.HttpResponse:
    return _json(*handlers.ready(_settings))


@app.function_name(name="version")
@app.route(route="version", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def version(req: func.HttpRequest) -> func.HttpResponse:
    return _json(
        200,
        {
            "service": bootstrap.SERVICE,
            "version": os.environ.get("DD_VERSION", "0.0.0-dev"),
            "commit": os.environ.get("GIT_COMMIT", "unknown"),
            "build_time": os.environ.get("BUILD_TIME", "unknown"),
        },
    )
