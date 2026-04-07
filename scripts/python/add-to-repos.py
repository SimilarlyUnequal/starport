#!/usr/bin/env python3
# =============================================================
#  starport — add-to-repos.py
#  Add or remove a URL from repos.yml
#  Usage:
#    Add:    python3 add-to-repos.py repos.yml <url> <group>
#    Remove: python3 add-to-repos.py --remove repos.yml <url>
# =============================================================

import sys
import yaml

# Parse args
if sys.argv[1] == "--remove":
    repos_file = sys.argv[2]
    url        = sys.argv[3].strip()
    config     = None
else:
    repos_file = sys.argv[1]
    url        = sys.argv[2].strip()
    # Long-form: url, name, branch, build_type, targets, runner
    if len(sys.argv) > 3:
        config = {
            "url": url,
            "name": sys.argv[3].strip(),
            "branch": sys.argv[4].strip() if len(sys.argv) > 4 else "",
            "build": {
                "type": sys.argv[5].strip() if len(sys.argv) > 5 else "",
                "targets": [t.strip() for t in sys.argv[6].split(",")] if len(sys.argv) > 6 and sys.argv[6] else [],
                "runner": sys.argv[7].strip() if len(sys.argv) > 7 else "ubuntu-latest"
            }
        }
    else:
        config = {"url": url}

try:
    with open(repos_file) as f:
        data = yaml.safe_load(f) or {}
except Exception:
    data = {}

if not isinstance(data.get("repos"), list):
    data["repos"] = []

if config is None:
    # Remove mode
    data["repos"] = [r for r in data["repos"] if r.get("url") != url]
    print(f"✅ Removed {url} from repos.yml")
else:
    # Add/Update mode
    exists_idx = -1
    for i, r in enumerate(data["repos"]):
        if r.get("url") == url:
            exists_idx = i
            break
    
    if exists_idx != -1:
        data["repos"][exists_idx] = config
        print(f"✅ Updated {url} in repos.yml")
    else:
        data["repos"].append(config)
        print(f"✅ Added {url} to repos.yml")

with open(repos_file, "w") as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True)
