"""CJ_REGION: news edition, search locale, Wikipedia language, currency and formats follow where the user lives."""
from cj import region
from cj.modes import common


def test_india_stays_the_default(monkeypatch):
    monkeypatch.delenv("CJ_REGION", raising=False)
    r = region.current()
    assert r.code == "IN" and r.currency == "INR" and r.news["gl"] == "IN"
    assert "lakh" in common.persona()


def test_spain(monkeypatch):
    monkeypatch.setenv("CJ_REGION", "es")
    r = region.current()
    assert r.news == {"hl": "es", "gl": "ES", "ceid": "ES:es"} and r.duckduckgo == "es-es"
    assert r.wikipedia == "es" and r.currency == "EUR"
    persona = common.persona()
    assert "euros" in persona and "lakh" not in persona and "{formats}" not in persona


def test_unknown_region_falls_back_to_the_default(monkeypatch):
    monkeypatch.setenv("CJ_REGION", "ZZ")
    assert region.current().code == "IN"
