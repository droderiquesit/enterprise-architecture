import os

os.environ.setdefault("DD_ENV", "test")
os.environ.setdefault("DD_SERVICE", "hello-catalog-api")
os.environ.setdefault("DD_VERSION", "1.0.0-test")
os.environ.pop("OTEL_EXPORTER_OTLP_ENDPOINT", None)

import pytest  # noqa: E402

from hello_catalog.settings import RedisSettings  # noqa: E402


class FakeRedis:
    def __init__(self, fail: bool = False):
        self.data: dict[str, str] = {}
        self.ttl: dict[str, int] = {}
        self.fail = fail

    async def get(self, key):
        if self.fail:
            raise ConnectionError("redis down")
        return self.data.get(key)

    async def set(self, key, value, ex=None):
        if self.fail:
            raise ConnectionError("redis down")
        self.data[key] = value
        self.ttl[key] = ex

    async def delete(self, key):
        self.data.pop(key, None)

    async def ping(self):
        if self.fail:
            raise ConnectionError("redis down")
        return True

    async def aclose(self):
        pass


def redis_settings(**kw) -> RedisSettings:
    base = dict(host="fake", port=10000, auth="none", password=None, tls=False, cluster=False, required=False, ttl_seconds=60, prefix="catalog:")
    base.update(kw)
    return RedisSettings(**base)


@pytest.fixture(autouse=True)
def _clear_faults():
    from hello_common.faults import REGISTRY

    REGISTRY.clear()
    yield
    REGISTRY.clear()
