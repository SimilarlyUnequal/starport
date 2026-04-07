#!/usr/bin/env python3
# =============================================================
#  starport — parse-repos.py
# =============================================================

import sys
import yaml

if len(sys.argv) < 2:
    print("Usage: parse-repos.py <repos.yml>", file=sys.stderr)
    sys.exit(1)

repos_file = sys.argv[1]

try:
    with open(repos_file) as f:
        data = yaml.safe_load(f)
except Exception as e:
    print(f"Error reading repos.yml: {e}", file=sys.stderr)
    sys.exit(1)

if not isinstance(data, dict) or "repos" not in data:
    print("Invalid repos.yml format (missing 'repos' key)", file=sys.stderr)
    sys.exit(1)

# New flat structure
for repo in data.get("repos", []):
    url = repo.get("url", "").strip()
    name = repo.get("name", "").strip()
    branch = repo.get("branch", "").strip()
    build_type = ""
    if isinstance(repo.get("build"), dict):
        build_type = repo["build"].get("type", "")

    if url and url.startswith("http"):
        # Output: URL NAME BRANCH BUILD_TYPE
        print(f"{url} {name} {branch} {build_type}")
