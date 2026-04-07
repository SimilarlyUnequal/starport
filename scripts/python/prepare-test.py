#!/usr/bin/env python3
# =============================================================
#  starport — prepare-test.py
#  Reads test.yml (same format as repos.yml) and writes a
#  single-entry repos.yml to /tmp/test-repos.yml
#  Usage: python3 prepare-test.py test.yml [index]
#  index: 0-based repo index to test (default: 0)
# =============================================================

import sys
import yaml

test_file = sys.argv[1]
index     = int(sys.argv[2]) if len(sys.argv) > 2 else 0
output    = "/tmp/test-repos.yml"

try:
    with open(test_file) as f:
        config = yaml.safe_load(f) or {}
except Exception as e:
    print(f"❌ Error reading test.yml: {e}", file=sys.stderr)
    sys.exit(1)

repos = config.get("repos") or []
if not repos:
    print("❌ No repos found in test.yml", file=sys.stderr)
    sys.exit(1)

if index >= len(repos):
    print(f"❌ Index {index} out of range (test.yml has {len(repos)} repo(s))", file=sys.stderr)
    sys.exit(1)

entry = repos[index]
data  = {"repos": [entry]}
name  = entry.get("name") or entry.get("url", "").split("/")[-1]
print(f"🎯 Testing: {name}")

with open(output, "w") as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True)

print(f"✅ Test repos.yml written to {output}")