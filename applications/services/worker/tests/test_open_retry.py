import asyncio

import pytest

from hello_worker.__main__ import open_with_retry


class Flaky:
    def __init__(self, failures: int):
        self.failures = failures
        self.calls = 0

    async def open(self) -> None:
        self.calls += 1
        if self.calls <= self.failures:
            raise ConnectionError("not yet")


def test_open_retries_until_success():
    f = Flaky(failures=2)
    asyncio.run(open_with_retry(f, "x", attempts=5, base_delay=0.001))
    assert f.calls == 3


def test_open_gives_up_after_bounded_attempts():
    f = Flaky(failures=10)
    with pytest.raises(ConnectionError):
        asyncio.run(open_with_retry(f, "x", attempts=3, base_delay=0.001))
    assert f.calls == 3
