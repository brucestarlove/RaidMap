"""Cached access to wago.tools: build list, DB2 CSV exports, per-build listfile.

Everything keyed by an exact build is immutable, so it is cached forever under
tools/cache/. Only the build list expires.
"""

import csv
import io
import json
import os
import time
import urllib.error
import urllib.request

BASE = "https://wago.tools"
UA = "RaidMap-mapdata/1.0 (personal addon tooling)"
CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cache")


def _get(url, timeout=300, retries=5):
    delay = 2
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            # 4xx other than 429 will not get better by retrying.
            if e.code < 500 and e.code != 429:
                raise
            err = e
        except (urllib.error.URLError, TimeoutError) as e:
            err = e
        if attempt < retries - 1:
            time.sleep(delay)
            delay *= 2
    raise RuntimeError(f"giving up on {url}: {err}")


def _cached(name, url, max_age=None):
    path = os.path.join(CACHE, name)
    if os.path.exists(path):
        if max_age is None or time.time() - os.path.getmtime(path) < max_age:
            with open(path, "rb") as f:
                return f.read()
    data = _get(url)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".tmp", "wb") as f:
        f.write(data)
    os.replace(path + ".tmp", path)
    return data


def builds():
    """{product: [{version, created_at, ...}, ...]}"""
    return json.loads(_cached("builds.json", f"{BASE}/api/builds", max_age=3600))


def latest_build(product):
    entries = builds().get(product)
    if not entries:
        raise SystemExit(f"wago.tools has no builds for product '{product}'")
    return max(entries, key=lambda b: b["created_at"])["version"]


def db2(table, build):
    """Rows of a DB2 table as a list of dicts (all values are strings)."""
    raw = _cached(f"db2/{build}/{table}.csv", f"{BASE}/db2/{table}/csv?build={build}")
    return list(csv.DictReader(io.StringIO(raw.decode("utf-8"))))


def listfile(prefix, build):
    """{fileDataID(int): path} for files under prefix that ship in this build.

    With version= the listfile is filtered to the build's own root, and also
    carries names only known for that build (Forever's new art). Checked
    against per-file CASC probes: 345 of 345 agreed, so membership here means
    the file ships. It does not mean the client can load it by path; see
    mapdata.loadable_art."""
    name = f"listfile/{build}/" + prefix.strip("/").replace("/", "_") + ".json"
    raw = _cached(name, f"{BASE}/api/files?search={prefix}&version={build}")
    return {int(k): v for k, v in json.loads(raw).items()}
