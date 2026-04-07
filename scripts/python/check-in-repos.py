#!/usr/bin/env python3
# =============================================================
#  starport — check-in-repos.py
#  Check if a URL exists in repos.yml
#  Usage: python3 check-in-repos.py <repos.yml> <url>
#  Output: yes | no
# =============================================================

import sys
import yaml

repos_file = sys.argv[1]
url        = sys.argv[2].strip()

try:
    with open(repos_file) as f:
        data = yaml.safe_load(f) or {}
except Exception:
    print("no")
    sys.exit(0)

all_urls = [r.get("url", "") for r in (data.get("repos") or [])]
print("yes" if url in all_urls else "no")