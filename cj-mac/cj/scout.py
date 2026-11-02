"""Web research: search, open the top pages, and hand the model a short fact sheet with sources.

For anything that changed recently and isn't covered by a dedicated lookup: scores, results, prices, opening
hours, launches, "who won", "is X open now". DuckDuckGo's plain HTML page first, Bing's as a fallback; both are
free and need no key. Page text is data for the model, never instructions (see TOOL_ANSWER in modes/assistant.py).
"""
from __future__ import annotations

import asyncio
import base64
import html
import re
import urllib.parse

import httpx

from . import region

BROWSER = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/537.36 (KHTML, like Gecko) "
                         "Chrome/130.0 Safari/537.36"}
SEARCH_TIMEOUT = httpx.Timeout(8.0, connect=4.0)
PAGE_TIMEOUT = httpx.Timeout(6.0, connect=3.0)
PAGES = 3          # pages opened per question
PAGE_CHARS = 2500  # text kept from each page
SKIP = ("youtube.com", "facebook.com", "instagram.com", "x.com", "twitter.com", "tiktok.com")  # no readable text


class ScoutError(Exception):
    pass


def _strip(fragment: str) -> str:
    return html.unescape(re.sub(r"<[^>]+>", "", fragment)).strip()


def page_text(page: str) -> str:
    """Readable text of an HTML page: no scripts, styles, menus or footers, whitespace squeezed."""
    page = re.sub(r"(?is)<(script|style|noscript|svg|nav|footer|header|form|aside)\b.*?</\1>", " ", page)
    page = re.sub(r"(?i)<(br|p|div|li|h[1-6]|tr)\b[^>]*>", "\n", page)
    text = html.unescape(re.sub(r"<[^>]+>", " ", page))
    lines = (re.sub(r"[ \t\xa0]+", " ", line).strip() for line in text.splitlines())
    return "\n".join(line for line in lines if len(line) > 30)  # short lines are mostly menus and buttons


def parse_duckduckgo(page: str) -> list[dict]:
    links = re.findall(r'class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>', page, re.S)
    snippets = re.findall(r'class="result__snippet"[^>]*>(.*?)</a>', page, re.S)
    results = []
    for i, (href, title) in enumerate(links):
        href = html.unescape(href)
        if "duckduckgo.com/l/?" in href:  # older pages wrap links in a redirect
            href = urllib.parse.parse_qs(urllib.parse.urlparse(href).query).get("uddg", [href])[0]
        if href.startswith("//"):
            href = "https:" + href
        if "duckduckgo.com/y.js" in href:  # ads
            continue
        results.append({"url": href, "title": _strip(title), "snippet": _strip(snippets[i]) if i < len(snippets) else ""})
    return results


def _bing_target(href: str) -> str:
    """Bing wraps results in a click-tracking link; the real address is base64 in its "u" parameter."""
    href = html.unescape(href)
    u = urllib.parse.parse_qs(urllib.parse.urlparse(href).query).get("u", [""])[0]
    if u.startswith("a1"):
        try:
            return base64.urlsafe_b64decode(u[2:] + "=" * (-len(u[2:]) % 4)).decode()
        except (ValueError, UnicodeDecodeError):
            pass
    return href


def parse_bing(page: str) -> list[dict]:
    results = []
    for block in re.findall(r'<li class="b_algo".*?</li>', page, re.S):
        link = re.search(r'<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', block, re.S)
        if not link:
            continue
        snippet = re.search(r"<p[^>]*>(.*?)</p>", block, re.S)
        results.append({"url": _bing_target(link[1]), "title": _strip(link[2]),
                        "snippet": _strip(snippet[1]) if snippet else ""})
    return results


async def search(client: httpx.AsyncClient, query: str) -> list[dict]:
    errors = []
    try:
        r = await client.post("https://html.duckduckgo.com/html/", data={"q": query, "kl": region.current().duckduckgo})
        if r.status_code == 200 and (found := parse_duckduckgo(r.text)):
            return found
        errors.append(f"DuckDuckGo answered {r.status_code}")
    except httpx.HTTPError as e:
        errors.append(f"DuckDuckGo: {type(e).__name__}")
    try:
        r = await client.get("https://www.bing.com/search", params={"q": query, **region.current().bing})
        if r.status_code == 200 and (found := parse_bing(r.text)):
            return found
        errors.append(f"Bing answered {r.status_code}")
    except httpx.HTTPError as e:
        errors.append(f"Bing: {type(e).__name__}")
    raise ScoutError("web search failed (" + "; ".join(errors) + ")")


async def _read(client: httpx.AsyncClient, url: str) -> str:
    try:
        r = await client.get(url, timeout=PAGE_TIMEOUT)
        if r.status_code != 200 or "html" not in r.headers.get("content-type", ""):
            return ""
        return page_text(r.text)[:PAGE_CHARS]
    except httpx.HTTPError:
        return ""


async def research(query: str) -> str:
    """The fact sheet for one question: each source's title, address, snippet and the start of its text."""
    query = query.strip()
    if not query:
        raise ScoutError("nothing to search for")
    headers = {**BROWSER, "Accept-Language": region.current().accept_language}
    async with httpx.AsyncClient(headers=headers, timeout=SEARCH_TIMEOUT, follow_redirects=True) as client:
        results = [r for r in await search(client, query) if not any(s in r["url"] for s in SKIP)][:PAGES + 2]
        if not results:
            raise ScoutError(f"no web results for {query}")
        texts = await asyncio.gather(*(_read(client, r["url"]) for r in results[:PAGES]))
    parts = [f'Web search for "{query}". Answer from these sources only, and say which one when it matters.']
    for i, r in enumerate(results, 1):
        site = urllib.parse.urlparse(r["url"]).netloc.removeprefix("www.")
        body = texts[i - 1] if i <= len(texts) else ""
        parts.append(f"\n[{i}] {r['title']} ({site})\n{r['snippet']}" + (f"\n{body}" if body else ""))
    return "\n".join(parts)
