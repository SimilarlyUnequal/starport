#!/usr/bin/env python3
# =============================================================
#  starport — make-temp-repos.py
#  Creates a minimal repos.yml from a plain-text list of URLs
#  Usage: python3 make-temp-repos.py <urls_file> [output_path]
# =============================================================

import sys
import yaml

urls_file = sys.argv[1]
output    = sys.argv[2] if len(sys.argv) > 2 else "/tmp/newly-added.yml"

with open(urls_file) as f:
    urls = [l.strip() for l in f if l.strip()]

data = {"repos": [{"url": u} for u in urls]}

with open(output, "w") as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True)

print(f"✅ Temp repos.yml created with {len(urls)} URL(s)")