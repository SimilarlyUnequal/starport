#!/usr/bin/env python3
# =============================================================
#  starport — split-urls.py
# =============================================================

import sys, re
text = sys.stdin.read()
urls = re.findall(r'https://[^\s]+', text)
for url in urls:
    print(url)
