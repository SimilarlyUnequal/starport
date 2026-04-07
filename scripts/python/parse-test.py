#!/usr/bin/env python3
# =============================================================
#  starport — parse-test.py
#  Parses test.yml (same format as repos.yml) and prints
#  repo entries to stdout in the same format as parse-repos.py
#  Usage: python3 scripts/python/parse-test.py test.yml
#  Output: URL NAME BRANCH BUILD_TYPE (one per line)
# =============================================================

import sys
import yaml

if len(sys.argv) < 2:
    print("Usage: parse-test.py <test.yml>", file=sys.stderr)
    sys.exit(1)

test_file = sys.argv[1]

try:
    with open(test_file) as f:
        data = yaml.safe_load(f) or {}
except Exception as e:
    print(f"Error reading test.yml: {e}", file=sys.stderr)
    sys.exit(1)

for repo in data.get("repos") or []:
    url        = repo.get("url", "").strip()
    name       = repo.get("name", "").strip()
    branch     = repo.get("branch", "").strip()
    build_type = ""
    if isinstance(repo.get("build"), dict):
        build_type = repo["build"].get("type", "")
    if url and url.startswith("http"):
        print(f"{url} {name} {branch} {build_type}")

print(f"✅ Test repos.yml written to {output}")