"""Garmin Connect: "how did I sleep?", "what's my Body Battery?", "how was my last run?".

Garmin's official API takes no new developers (paused in 2026), so this uses the unofficial python-garminconnect
library with the user's own account. Setup once with  ./set-key.sh garmin : it signs in (with the MFA code if the
account has one) and saves only the session tokens in ~/.cj/garmin. The password is never stored. Garmin changes
its login now and then; when that happens CJ says so and `pip install -U garminconnect` usually fixes it.
Unofficial access is against Garmin's terms; at one person's low volume the risk is small, but it is the user's call.
"""
from __future__ import annotations

import asyncio
import datetime
import os
import threading
from zoneinfo import ZoneInfo

from . import prefs


class GarminError(Exception):
    pass


def token_dir() -> str:
    return str(prefs.home() / "garmin")


def available() -> bool:
    return os.path.isdir(token_dir()) and bool(os.listdir(token_dir()))


_client = None
_lock = threading.Lock()


def _connect():
    """A signed-in client from the saved tokens (no password)."""
    global _client
    with _lock:
        if _client is None:
            try:
                from garminconnect import Garmin
            except ImportError as e:
                raise GarminError("Garmin needs the garminconnect package: pip install -r requirements.txt") from e
            client = Garmin()
            try:
                client.login(tokenstore=token_dir())
            except Exception as e:  # expired tokens, Garmin login changes, no network
                raise GarminError("I can't sign in to Garmin right now. Run ./set-key.sh garmin again on the Mac.") from e
            _client = client
        return _client


def _today() -> datetime.date:
    return datetime.datetime.now(ZoneInfo(os.environ.get("CJ_TIMEZONE", "Asia/Kolkata"))).date()


def _hours(seconds) -> str:
    if not seconds:
        return "?"
    h, m = divmod(int(seconds) // 60, 60)
    return f"{h} h {m:02d} min"


def _day_summary(client, day: datetime.date) -> str:
    s = client.get_user_summary(day.isoformat()) or {}
    parts = [f"Garmin, {day.isoformat()}:"]
    if s.get("totalSteps") is not None:
        parts.append(f"steps {s['totalSteps']}" + (f" of {s['dailyStepGoal']} goal" if s.get("dailyStepGoal") else ""))
    if s.get("bodyBatteryMostRecentValue") is not None:
        parts.append(f"Body Battery now {s['bodyBatteryMostRecentValue']}"
                     + (f" (high {s.get('bodyBatteryHighestValue')}, low {s.get('bodyBatteryLowestValue')})"
                        if s.get("bodyBatteryHighestValue") is not None else ""))
    if s.get("averageStressLevel") not in (None, -1, -2):
        parts.append(f"average stress {s['averageStressLevel']}/100")
    if s.get("restingHeartRate"):
        parts.append(f"resting heart rate {s['restingHeartRate']} bpm")
    if s.get("activeKilocalories"):
        parts.append(f"active calories {int(s['activeKilocalories'])}")
    if s.get("floorsAscended"):
        parts.append(f"floors {int(s['floorsAscended'])}")
    return "; ".join(parts) if len(parts) > 1 else f"Garmin has no data for {day.isoformat()} yet."


def _sleep(client, day: datetime.date) -> str:
    data = client.get_sleep_data(day.isoformat()) or {}
    dto = data.get("dailySleepDTO") or {}
    if not dto.get("sleepTimeSeconds"):
        return f"Garmin has no sleep recorded for the night before {day.isoformat()}."
    score = ((dto.get("sleepScores") or {}).get("overall") or {}).get("value")
    parts = [f"Sleep (night before {day.isoformat()}): {_hours(dto.get('sleepTimeSeconds'))}"]
    if score is not None:
        parts.append(f"sleep score {score}/100")
    for key, name in (("deepSleepSeconds", "deep"), ("remSleepSeconds", "REM"), ("lightSleepSeconds", "light"),
                      ("awakeSleepSeconds", "awake")):
        if dto.get(key):
            parts.append(f"{name} {_hours(dto[key])}")
    hrv = (data.get("avgOvernightHrv") or (client.get_hrv_data(day.isoformat()) or {}).get("hrvSummary", {}).get("lastNightAvg"))
    if hrv:
        parts.append(f"overnight HRV {hrv} ms")
    return "; ".join(parts)


def _activities(client, count: int) -> str:
    found = client.get_activities(0, max(1, min(count, 10))) or []
    if not found:
        return "No activities on Garmin."
    lines = []
    for a in found:
        kind = (a.get("activityType") or {}).get("typeKey", "activity").replace("_", " ")
        km = f"{a['distance'] / 1000:.2f} km, " if a.get("distance") else ""
        hr = f", average heart rate {int(a['averageHR'])}" if a.get("averageHR") else ""
        lines.append(f"{(a.get('startTimeLocal') or '')[:16]} {a.get('activityName') or kind} ({kind}): "
                     f"{km}{_hours(a.get('duration'))}{hr}")
    return "\n".join(lines)


def _run(what: str, days_ago: int) -> str:
    client = _connect()
    day = _today() - datetime.timedelta(days=max(0, min(days_ago, 30)))
    if what == "sleep":
        return _sleep(client, day)
    if what == "last_activity":
        return _activities(client, 1)
    if what == "activities":
        return _activities(client, 5)
    if what == "week":
        return "\n".join(_day_summary(client, day - datetime.timedelta(days=i)) for i in range(6, -1, -1))
    return _day_summary(client, day) + "\n" + _sleep(client, day)


async def lookup(what: str = "today", days_ago: int = 0) -> str:
    """For the model: a plain-text fact sheet, or a FAILED note it can explain."""
    if not available():
        return "FAILED: Garmin isn't set up. On the Mac, run ./set-key.sh garmin."
    try:
        return await asyncio.to_thread(_run, what, days_ago)
    except GarminError as e:
        return f"FAILED: {e}"
    except Exception as e:  # Garmin changed something: say it plainly instead of crashing the conversation
        global _client
        _client = None
        return f"FAILED: Garmin didn't answer ({type(e).__name__}). Try again later, or update garminconnect."


def setup() -> None:
    """Interactive sign-in for ./set-key.sh garmin: saves session tokens only."""
    import getpass
    try:
        from garminconnect import Garmin
    except ImportError:
        raise SystemExit("Install it first: .venv/bin/pip install -r requirements.txt")
    print("Garmin uses an unofficial connection (Garmin's official API takes no new developers). "
          "Only session tokens are saved, in ~/.cj/garmin; your password is not stored.")
    email = input("Garmin Connect email: ").strip()
    password = getpass.getpass("Garmin Connect password (hidden): ")
    os.makedirs(token_dir(), mode=0o700, exist_ok=True)
    client = Garmin(email, password, prompt_mfa=lambda: input("Code Garmin sent you (MFA): ").strip())
    try:
        client.login(tokenstore=token_dir())
    except Exception as e:
        raise SystemExit(f"Garmin sign-in failed: {e}")
    for name in os.listdir(token_dir()):
        os.chmod(os.path.join(token_dir(), name), 0o600)
    print(f"Signed in to Garmin. Tokens saved in {token_dir()}. Ask CJ: \"how did I sleep?\"")
