#!/usr/bin/env python3
"""Converts herdr's agent manifests (TOML, one per agent) into the one JSON
file Libertty reads, Resources/agent-rules/rules.json, and copies their
license beside it.

    scripts/update-agent-rules.py DIR

DIR holds the manifests: herdr's (github.com/ogulcancelik/herdr, Apache-2.0)
or a copy of them, such as Kero's internal/detect/manifests. Needs Python
3.11 (tomllib) or the tomli package.
"""
import json
import os
import shutil
import sys

try:
    import tomllib
except ImportError:
    import tomli as tomllib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources", "agent-rules")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    src = sys.argv[1]
    manifests = []
    for name in sorted(os.listdir(src)):
        if not name.endswith(".toml"):
            continue
        with open(os.path.join(src, name), "rb") as f:
            m = tomllib.load(f)
        m.setdefault("id", name[:-5])
        manifests.append(m)
    if not manifests:
        sys.exit(f"no manifests in {src}")
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "rules.json"), "w", encoding="utf-8") as f:
        json.dump({"manifests": manifests}, f, ensure_ascii=False, indent=1, sort_keys=True)
        f.write("\n")
    license = os.path.join(src, "LICENSE")
    if os.path.exists(license):
        shutil.copy(license, os.path.join(OUT, "LICENSE"))
    print(f"{len(manifests)} manifests: {', '.join(m['id'] for m in manifests)}")


main()
