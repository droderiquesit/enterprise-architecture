import pytest


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):  # diagnostics: lets fixtures print container logs on failure
    outcome = yield
    rep = outcome.get_result()
    setattr(item, "rep_" + rep.when, rep)
