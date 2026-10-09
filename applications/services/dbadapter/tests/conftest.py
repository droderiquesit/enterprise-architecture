import os

os.environ.setdefault("DD_ENV", "test")
os.environ.setdefault("DD_VERSION", "1.0.0-test")
os.environ.pop("OTEL_EXPORTER_OTLP_ENDPOINT", None)
os.environ.pop("DB_SERVICE_NAME", None)

import pytest  # noqa: E402


@pytest.fixture(autouse=True)
def _clear_faults():
    from hello_common.faults import REGISTRY

    REGISTRY.clear()
    yield
    REGISTRY.clear()


async def exercise_contract(driver, *, check_list: bool = True):
    """Shared CRUD contract every driver must satisfy."""
    await driver.open()
    await driver.ping()
    rec = await driver.create({"a": 1})
    assert rec.id and rec.payload == {"a": 1}
    got = await driver.get(rec.id)
    assert got is not None and got.payload == {"a": 1} and got.created_at
    upd = await driver.update(rec.id, {"a": 2})
    assert upd is not None and upd.payload == {"a": 2}
    assert (await driver.get(rec.id)).payload == {"a": 2}
    # upsert with explicit id keeps created_at
    again = await driver.create({"a": 3}, rec.id)
    assert again.id == rec.id and (await driver.get(rec.id)).payload == {"a": 3}
    if check_list:
        ids = [r.id for r in await driver.list(10)]
        assert rec.id in ids
    assert await driver.delete(rec.id) is True
    assert await driver.get(rec.id) is None
    assert await driver.delete(rec.id) is False
    assert await driver.update("missing-id", {"x": 1}) is None
    assert await driver.seed(3) == 3
    assert len(await driver.list(10)) >= 3 if check_list else True
