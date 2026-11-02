"""Where the user lives: news edition, web-search locale, Wikipedia language, currency and number formats.

Set CJ_REGION (IN, ES, US, GB, MX…). Without it CJ keeps its original Indian defaults.
"""
from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Region:
    code: str
    news: dict            # Google News RSS edition
    accept_language: str  # what web pages are asked for
    duckduckgo: str       # DuckDuckGo "kl" region
    bing: dict            # Bing market
    wikipedia: str        # Wikipedia language
    currency: str
    formats: str          # for the persona: how to say money, dates and numbers
    money_example: str    # how a price sounds out loud


REGIONS = {
    "IN": Region("IN", {"hl": "en-IN", "gl": "IN", "ceid": "IN:en"}, "en-IN,en;q=0.9", "in-en",
                 {"setlang": "en", "cc": "IN"}, "en", "INR",
                 "in India: rupees, lakh and crore, DD/MM dates", "about 95 rupees"),
    "ES": Region("ES", {"hl": "es", "gl": "ES", "ceid": "ES:es"}, "es-ES,es;q=0.9,en;q=0.6", "es-es",
                 {"setlang": "es", "cc": "ES"}, "es", "EUR",
                 "in Spain: euros, a comma for decimals, DD/MM dates, the 24-hour clock, kilometres", "unos 12 euros"),
    "MX": Region("MX", {"hl": "es-419", "gl": "MX", "ceid": "MX:es-419"}, "es-MX,es;q=0.9,en;q=0.6", "mx-es",
                 {"setlang": "es", "cc": "MX"}, "es", "MXN",
                 "in Mexico: pesos, DD/MM dates", "unos 200 pesos"),
    "US": Region("US", {"hl": "en-US", "gl": "US", "ceid": "US:en"}, "en-US,en;q=0.9", "us-en",
                 {"setlang": "en", "cc": "US"}, "en", "USD",
                 "in the US: dollars, MM/DD dates, miles and Fahrenheit", "about 12 dollars"),
    "GB": Region("GB", {"hl": "en-GB", "gl": "GB", "ceid": "GB:en"}, "en-GB,en;q=0.9", "uk-en",
                 {"setlang": "en", "cc": "GB"}, "en", "GBP",
                 "in the UK: pounds, DD/MM dates", "about 12 pounds"),
}


def current() -> Region:
    return REGIONS.get(os.environ.get("CJ_REGION", "IN").strip().upper(), REGIONS["IN"])
