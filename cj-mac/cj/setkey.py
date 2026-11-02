"""Saves an API key to ~/.cj/config.json (mode 600) from a hidden prompt:
    python -m cj.setkey [gemini|groq|openrouter|ollama|azure_speech|claude|openai|deepseek|alexa|garmin]
azure_speech also asks for the Azure region. claude, openai and deepseek ask whether to make them CJ's main brain
and for an optional monthly spending limit; openai and openrouter ask which model to use, ollama which local model
(it needs no key). alexa saves the sign-in token for smart home control. garmin signs in to Garmin Connect once
and keeps only its session tokens."""
from __future__ import annotations

import getpass
import re
import sys

from . import prefs


def main() -> None:
    provider = sys.argv[1] if len(sys.argv) > 1 else "gemini"
    if provider == "alexa":
        return alexa()
    if provider == "ollama":
        return ollama()
    if provider == "garmin":
        from . import garmin
        return garmin.setup()
    value = getpass.getpass(f"Paste your {provider} API key (hidden), then press Enter: ").strip()
    if len(value) < 20 or "YOUR_KEY" in value:
        sys.exit("That doesn't look like a real key (placeholder or too short). Nothing was saved.")
    cfg = prefs.load()
    if provider == "azure_speech":
        region = input("Azure region of that key (e.g. centralindia, eastus): ").strip().lower()
        if not re.fullmatch(r"[a-z0-9]+", region):
            sys.exit("That doesn't look like an Azure region. Nothing was saved.")
        cfg["azure_region"] = region
    if provider == "openai":
        model = input("Which GPT model should CJ use? (the exact model name from your OpenAI dashboard): ").strip()
        if not re.fullmatch(r"[\w.\-:]+", model):
            sys.exit("That doesn't look like a model name. Nothing was saved.")
        cfg["openai_model"] = model
    if provider == "openrouter":
        model = input("Which OpenRouter model? (from openrouter.ai/models; names ending in :free cost nothing): ").strip()
        if not re.fullmatch(r"[\w.\-:/]+", model):
            sys.exit("That doesn't look like a model name. Nothing was saved.")
        cfg["openrouter_model"] = model
    if provider == "claude":
        model = input("Claude model [claude-sonnet-5-5]: ").strip() or "claude-sonnet-5-5"
        cfg["claude_model"] = model
    if provider in PAID:
        if input(f"Make {provider} CJ's main brain? [Y/n] ").strip().lower() != "n":
            cfg["provider"] = provider
        spending_limit(cfg, provider)
    prefs.save(cfg)
    prefs.set_key(provider, value)
    print(f"Saved {provider} key to {prefs.home() / 'config.json'}. The running server picks it up automatically.")


PAID = ("claude", "openai", "deepseek")


def spending_limit(cfg: dict, provider: str) -> None:
    """Optional monthly cap. CJ adds up each call's cost from the prices you enter here (see llm/spend.py)."""
    cap = input(f"Monthly spending limit for {provider} in US dollars (Enter = no limit): ").strip()
    if not cap:
        cfg.get("limits", {}).pop(provider, None)
        return
    try:
        cap_usd = float(cap)
        print(f"Prices are on {provider}'s pricing page, in dollars per million tokens.")
        price_in = float(input("Price per million input tokens: ").strip())
        price_out = float(input("Price per million output tokens: ").strip())
    except ValueError:
        sys.exit("Please enter plain numbers, like 10 or 0.27. Nothing was saved.")
    cfg.setdefault("limits", {})[provider] = cap_usd
    cfg.setdefault("prices", {})[provider] = {"in": price_in, "out": price_out}


def ollama() -> None:
    """A model running in Ollama on this Mac. No key: just its name, as shown by  ollama list."""
    model = input("Which Ollama model should CJ use? (as shown by: ollama list, e.g. llama3.2): ").strip()
    if not re.fullmatch(r"[\w.\-:/]+", model):
        sys.exit("That doesn't look like a model name. Nothing was saved.")
    cfg = prefs.load()
    cfg["ollama_model"] = model
    if input("Make it CJ's main brain? (otherwise it's the last free fallback) [y/N] ").strip().lower() == "y":
        cfg["provider"] = "ollama"
    prefs.save(cfg)
    print(f"Saved. CJ will use {model} from Ollama.")


def alexa() -> None:
    """Smart home through Alexa. The token comes from signing in with alexa-cookie-cli (your password never reaches CJ)."""
    print("Get a refresh token: download alexa-cookie-cli from https://github.com/adn77/alexa-cookie-cli/releases,\n"
          "run it with your Amazon site (India: ./alexa-cookie-cli-macos -p amazon.in -a en_IN -L en-IN), open\n"
          "http://127.0.0.1:8080, sign in to Amazon, and copy the refresh token it prints (starts with Atnr|).")
    value = getpass.getpass("Paste the refresh token (hidden), then press Enter: ").strip()
    if not value.startswith("Atnr|") or len(value) < 100:
        sys.exit("That doesn't look like an Alexa refresh token (it starts with Atnr|). Nothing was saved.")
    domain = input("Your Amazon site [amazon.com] (e.g. amazon.in, amazon.co.uk, amazon.de): ").strip().lower() or "amazon.com"
    if not re.fullmatch(r"amazon\.[a-z.]{2,6}", domain):
        sys.exit("That isn't an Amazon site like amazon.in. Nothing was saved.")
    locale = input("Alexa's language [en-IN] (e.g. en-US, en-GB, hi-IN, de-DE): ").strip() or "en-IN"
    echo = input("Name of the Echo to use, as in the Alexa app (Enter = the first one online): ").strip()
    cfg = prefs.load()
    cfg.update({"alexa_domain": domain, "alexa_locale": locale, "alexa_device": echo})
    prefs.save(cfg)
    prefs.set_key("alexa", value)
    print("Saved. Try: \"CJ, turn off the lights\".")


if __name__ == "__main__":
    main()
