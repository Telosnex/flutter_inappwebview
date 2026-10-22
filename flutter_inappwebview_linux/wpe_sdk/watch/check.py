#!/usr/bin/env python3
"""WebKit security watch for the pinned WPE SDK (sources.env).

Reads the newest stable WPE WebKit release (even minor) from
https://wpewebkit.org/releases/ and the newest WebKitGTK/WPE security
advisory from https://webkitgtk.org/security.html. Prints one JSON line:
{pinned, latest, advisory, advisory_fixed_in, behind, reason}. Exit 0.
"""
import json, re, sys, urllib.request
from pathlib import Path

def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "telosnex-wpe-watch"})
    return urllib.request.urlopen(req, timeout=30).read().decode("utf-8", "replace")

def ver(s):
    return tuple(int(x) for x in s.split("."))

def newest_stable(listing):
    found = {m for m in re.findall(r"wpewebkit-(2\.\d+\.\d+)\.tar\.xz", listing)}
    stable = [v for v in found if ver(v)[1] % 2 == 0]
    return max(stable, key=ver)

def newest_advisory(index):
    ids = sorted(set(re.findall(r"WSA-(\d{4})-(\d{4})", index)))
    y, n = ids[-1]
    return f"WSA-{y}-{n}"

def fixed_in(advisory_html):
    text = re.sub(r"<[^>]+>", " ", advisory_html)
    # "Versions affected: WebKitGTK and WPE WebKit before 2.54.0 or earlier."
    vs = re.findall(r"WPE WebKit before (2\.\d+\.\d+)", text)
    return max(vs, key=ver) if vs else None

def main():
    env = Path(sys.argv[1]).read_text()
    pinned = re.search(r"^WPEWEBKIT_VERSION=(\S+)", env, re.M).group(1)
    latest = newest_stable(get("https://wpewebkit.org/releases/"))
    advisory = newest_advisory(get("https://webkitgtk.org/security.html"))
    fixed = fixed_in(get(f"https://webkitgtk.org/security/{advisory}.html"))
    reasons = []
    if fixed and ver(pinned) < ver(fixed):
        reasons.append(f"{advisory} fixes issues in versions before {fixed}")
    if ver(pinned) < ver(latest):
        reasons.append(f"WPE WebKit {latest} is out")
    print(json.dumps({"pinned": pinned, "latest": latest, "advisory": advisory,
                      "advisory_fixed_in": fixed, "behind": bool(reasons),
                      "reason": "; ".join(reasons)}))

if __name__ == "__main__":
    main()
