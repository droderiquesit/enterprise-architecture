import os
import sys
from pathlib import Path

APP = Path(__file__).resolve().parents[1]
REPO = APP.parents[2]
for p in (str(APP), str(REPO), str(REPO / "applications/shared/python/hello_common/src"), str(REPO / "tests/review")):
    if p not in sys.path:
        sys.path.insert(0, p)

os.environ.setdefault("DD_ENV", "test")
os.environ.setdefault("DSV_AUTH", "none")
os.environ.pop("OTEL_EXPORTER_OTLP_ENDPOINT", None)
os.environ.setdefault("REVIEW_QUEUE_NAME", "pr-review")
