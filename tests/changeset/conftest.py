import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
for p in (str(ROOT), str(HERE)):
    if p not in sys.path:
        sys.path.insert(0, p)


def pytest_collection_modifyitems(config, items):
    """TEST_SHARD=<i>/<n>: deterministic sharding in CI (tools/pipeline/shard.py); idempotent across conftests."""
    from tools.pipeline.shard import filter_items

    filter_items(config, items)
