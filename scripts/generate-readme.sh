#!/bin/bash
# =============================================================
#  starport — generate-readme.sh
#  Generates a dashboard README.md for the remote group page
#  - Syncs mode: merges results, backs up state + results to GitHub
#  - README-only mode: reads state from GitHub private repo
#  - Fallback: if merge fails, retries from backed-up results
#  - All JSON ops wrapped in try/except
# =============================================================

set -euo pipefail

export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false

# ── Required variables ────────────────────────────────────────
: "${REMOTE_TOKEN:?❌  REMOTE_TOKEN is not set}"
: "${PARENT_FOLDER:?❌  PARENT_FOLDER is not set}"
: "${PROFILE_REPO:?❌  PROFILE_REPO is not set}"
: "${REPOS_FILE:?❌  REPOS_FILE is not set}"
: "${STATE_REPO_URL:?❌  STATE_REPO_URL is not set}"
: "${STATE_REPO_TOKEN:?❌  STATE_REPO_TOKEN is not set}"
: "${GITHUB_TOKEN:?❌  GITHUB_TOKEN is not set}"
: "${GITHUB_WORKSPACE:?❌  GITHUB_WORKSPACE is not set}"

# ── Config ────────────────────────────────────────────────────
PROFILE_WORK="/tmp/starport-profile"
STATE_WORK="/tmp/starport-state"
RESULTS_FILE="/tmp/sync-results.json"
README_ONLY="${README_ONLY:-false}"
NOW=$(date '+%Y-%m-%d %H:%M UTC')
TODAY=$(date '+%Y-%m-%d')
NEXT_SUNDAY=$(python3 -c "
from datetime import date, timedelta
d = date.today()
days = (6 - d.weekday()) % 7
days = 7 if days == 0 else days
print((d + timedelta(days=days)).strftime('%Y-%m-%d'))
")

REPOS_FILE=$(realpath "$REPOS_FILE")
export REPOS_FILE

# Profile is a standard GitHub personal repo
PROFILE_REMOTE="https://x-access-token:${REMOTE_TOKEN}@github.com/${PARENT_FOLDER}/${PROFILE_REPO}.git"
STATE_REMOTE="https://${STATE_REPO_TOKEN}@${STATE_REPO_URL#https://}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ── Ensure profile repo exists (GitHub) ──────────────────────
ensure_profile_repo() {
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    --header "Authorization: Bearer $REMOTE_TOKEN" \
    "https://api.github.com/repos/${PARENT_FOLDER}/${PROFILE_REPO}")

  [ "$status" = "200" ] && return 0

  log "🆕 Creating profile repo on GitHub..."
  local result
  result=$(curl -s -w "\n%{http_code}" \
    --request POST \
    --header "Authorization: Bearer $REMOTE_TOKEN" \
    --header "Content-Type: application/json" \
    --data "{\"name\":\"${PROFILE_REPO}\",\"private\":false,\"auto_init\":true}" \
    "https://api.github.com/user/repos" | tail -1)

  if [ "$result" = "201" ]; then
    log "✅ Profile repo created"
    sleep 2
  else
    log "❌ Failed to create profile repo (HTTP $result)"
    return 1
  fi
}

# ── Clone or init ─────────────────────────────────────────────
clone_or_init() {
  local dir="$1"
  local remote="$2"
  local label="$3"

  rm -rf "$dir"
  if git clone "$remote" "$dir" 2>/dev/null; then
    log "📦 Cloned $label"
  else
    log "🆕 Init fresh $label"
    mkdir -p "$dir"
    cd "$dir"
    git init
    git remote add origin "$remote"
    cd /
  fi
  cd "$dir"
  git config user.email "starport@noreply"
  git config user.name "starport"
  cd /
}

# ── Merge sync results into state ────────────────────────────
merge_results() {
  local state_file="$1"
  local results_file="$2"

  python3 - "$state_file" "$results_file" "$TODAY" << 'PYEOF'
import json, sys

state_file   = sys.argv[1]
results_file = sys.argv[2]
today        = sys.argv[3]

try:
    with open(state_file) as f:
        state = json.load(f)
except (json.JSONDecodeError, FileNotFoundError, Exception) as e:
    print(f"[merge] state load warning: {e} — starting fresh", file=sys.stderr)
    state = {}

try:
    with open(results_file) as f:
        results = json.load(f)
except (json.JSONDecodeError, FileNotFoundError, Exception) as e:
    print(f"[merge] results load error: {e}", file=sys.stderr)
    sys.exit(1)

for url, metrics in results.items():
    existing = state.get(url, {})
    status   = metrics.get("status", "failed")

    if "first_synced" not in existing:
        existing["first_synced"] = today

    existing["last_attempt"] = today
    existing["status"]       = status
    existing["topics"]       = existing.get("topics", None)

    sha = metrics.get("last_commit_sha", "")
    if sha:
        existing["last_commit_sha"] = sha

    if status == "skipped":
        pass  # keep all previous values unchanged
    elif status == "success":
        existing["last_success"] = today
        existing["clone_time"]   = metrics.get("clone_time", 0)
        existing["push_time"]    = metrics.get("push_time", 0)
        existing["total_time"]   = metrics.get("total_time", 0)
        existing["size"]         = metrics.get("size", "—")
        existing["branches"]     = metrics.get("branches", 0)
        existing["tags"]         = metrics.get("tags", 0)
        existing["retries"]      = metrics.get("retries", 0)
    else:
        existing["clone_time"]   = metrics.get("clone_time", 0)
        existing["push_time"]    = metrics.get("push_time", 0)
        existing["total_time"]   = metrics.get("total_time", 0)
        existing["retries"]      = metrics.get("retries", 0)

    state[url] = existing

try:
    with open(state_file, "w") as f:
        json.dump(state, f, indent=2)
    print("✅ State merged")
except Exception as e:
    print(f"[merge] state write error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# ── Fetch GitHub topics (cached) ──────────────────────────────
fetch_topics() {
  local state_file="$1"

  python3 - "$state_file" "$REPOS_FILE" << PYEOF
import json, sys, urllib.request

state_file   = sys.argv[1]
repos_file   = sys.argv[2]
github_token = "$GITHUB_TOKEN"

try:
    with open(state_file) as f:
        state = json.load(f)
except Exception as e:
    print(f"[topics] state load error: {e}", file=sys.stderr)
    state = {}

def fetch(owner, repo):
    url = f"https://api.github.com/repos/{owner}/{repo}/topics"
    req = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github.mercy-preview+json",
        "User-Agent": "starport",
        **({"Authorization": f"Bearer {github_token}"} if github_token else {})
    })
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read()).get("names", [])
    except Exception:
        return []

try:
    with open(repos_file) as f:
        lines = f.readlines()
except Exception as e:
    print(f"[topics] repos file error: {e}", file=sys.stderr)
    sys.exit(1)

for line in lines:
    line = line.strip()
    if not line or line.startswith("#") or not line.startswith("http"):
        continue
    parts = line.rstrip("/").rstrip(".git").split("/")
    if len(parts) < 2:
        continue
    owner, repo = parts[-2], parts[-1]
    if line in state and state[line].get("topics") is not None:
        continue
    topics = fetch(owner, repo)
    if line not in state:
        state[line] = {}
    state[line]["topics"] = topics
    print(f"  🏷️  {repo}: {topics if topics else 'no topics'}")

try:
    with open(state_file, "w") as f:
        json.dump(state, f, indent=2)
    print("✅ Topics updated")
except Exception as e:
    print(f"[topics] state write error: {e}", file=sys.stderr)
PYEOF
}

# ── Generate README.md ────────────────────────────────────────
generate_readme() {
  local state_file="$1"
  local readme="$2"

  python3 - "$state_file" "$REPOS_FILE" "$readme" "$NOW" "$TODAY" "$NEXT_SUNDAY" << 'PYEOF'
import json, sys, re
from collections import defaultdict

state_file  = sys.argv[1]
repos_file  = sys.argv[2]
readme_file = sys.argv[3]
now         = sys.argv[4]
today       = sys.argv[5]
next_sunday = sys.argv[6]

try:
    with open(state_file) as f:
        state = json.load(f)
except Exception as e:
    print(f"[readme] state load error: {e} — using empty state", file=sys.stderr)
    state = {}

try:
    with open(repos_file) as f:
        lines = f.readlines()
except Exception as e:
    print(f"[readme] repos file error: {e}", file=sys.stderr)
    sys.exit(1)

# Parse repos.yml — new flat format
import yaml as _yaml
url_meta  = {}   # url → {name, build_type}
all_urls  = []

try:
    with open(repos_file) as yf:
        ydata = _yaml.safe_load(yf) or {}
except Exception as e:
    print(f"[readme] repos.yml parse error: {e}", file=sys.stderr)
    ydata = {}

for entry in (ydata.get("repos") or []):
    url = entry.get("url", "").strip().rstrip("/")
    if not url:
        continue
    all_urls.append(url)
    url_meta[url] = {
        "name":       entry.get("name", ""),
        "build_type": (entry.get("build") or {}).get("type", ""),
        "targets":    (entry.get("build") or {}).get("targets", []),
    }

def get_category(url):
    # Use first GitHub topic as category, fallback to build type, then General
    topics = state.get(url, {}).get("topics") or []
    if topics:
        return topics[0].replace("-", " ").title()
    build_type = url_meta.get(url, {}).get("build_type", "")
    if build_type:
        return build_type.title()
    return "General"

def fmt_time(secs):
    try:
        secs = int(secs)
        if secs == 0:  return "—"
        if secs < 60:  return f"{secs}s"
        return f"{secs//60}m {secs%60}s"
    except Exception:
        return "—"

categories = defaultdict(list)
for url in all_urls:
    categories[get_category(url)].append(url)

total   = len(all_urls)
success = sum(1 for u in all_urls if state.get(u, {}).get("status") == "success")
skipped = sum(1 for u in all_urls if state.get(u, {}).get("status") == "skipped")
failed  = sum(1 for u in all_urls if state.get(u, {}).get("status") == "failed")
pending = total - success - skipped - failed

total_sync_time = sum(
    state.get(u, {}).get("total_time", 0) or 0
    for u in all_urls if state.get(u, {}).get("status") == "success"
)
timed   = [(u, state.get(u,{}).get("total_time",0) or 0) for u in all_urls if state.get(u,{}).get("status")=="success"]
slowest = max(timed, key=lambda x: x[1], default=None)
fastest = min(timed, key=lambda x: x[1], default=None)

out = []
out.append("# 🪐 starport\n\n")
out.append("> A curated backup of essential open source projects.\n\n")
out.append("| | |\n|---|---|\n")
out.append(f"| 🕐 Last sync | {now} |\n")
out.append(f"| 📅 Next sync | {next_sunday} |\n")
out.append(f"| ⏱️ Active sync duration | {fmt_time(total_sync_time)} |\n")
if slowest:
    sname = slowest[0].rstrip('/').split('/')[-1]
    out.append(f"| 🐢 Slowest | {sname} ({fmt_time(slowest[1])}) |\n")
if fastest:
    fname = fastest[0].rstrip('/').split('/')[-1]
    out.append(f"| 🐇 Fastest | {fname} ({fmt_time(fastest[1])}) |\n")
out.append("\n")
out.append(
    f"![total](https://img.shields.io/badge/total-{total}-blue) "
    f"![synced](https://img.shields.io/badge/synced-{success}-brightgreen) "
    f"![skipped](https://img.shields.io/badge/skipped-{skipped}-lightgrey) "
    f"![failed](https://img.shields.io/badge/failed-{failed}-red) "
    f"![pending](https://img.shields.io/badge/pending-{pending}-yellow)\n\n"
)

out.append("## Contents\n\n")
for cat in sorted(categories.keys()):
    anchor = cat.lower().replace(" ", "-")
    out.append(f"- [{cat}](#{anchor}) ({len(categories[cat])})\n")
out.append("\n")

for cat in sorted(categories.keys()):
    out.append(f"## {cat}\n\n")
    out.append(
        "| Repo | Build | Topics | First Synced | Last Synced | Size | "
        "Branches | Tags | Clone | Push | Total | Retries | Status |\n"
    )
    out.append(
        "|------|-------|--------|-------------|-------------|------|"
        "----------|------|-------|------|-------|---------|--------|\n"
    )
    for url in categories[cat]:
        meta         = url_meta.get(url, {})
        name         = meta.get("name") or url.rstrip("/").split("/")[-1].replace(".git", "")
        build_type   = meta.get("build_type", "—") or "—"
        info         = state.get(url, {})
        status       = info.get("status", "pending")
        topics       = info.get("topics") or []
        topic_str    = " ".join(f"<code>{t}</code>" for t in topics[:3]) if topics else "—"
        first_synced = info.get("first_synced", "—")
        last_success = info.get("last_success") or "—"
        size         = info.get("size", "—") or "—"
        branches     = info.get("branches", "—")
        tags         = info.get("tags", "—")
        clone_t      = fmt_time(info.get("clone_time", 0))
        push_t       = fmt_time(info.get("push_time", 0))
        total_t      = fmt_time(info.get("total_time", 0))
        retries      = info.get("retries", 0)

        if status == "success":
            badge = "✅"; date_str = last_success
        elif status == "skipped":
            badge = "⏭️"; date_str = last_success
            clone_t = push_t = total_t = "—"
        elif status == "failed":
            badge = "❌"; date_str = f"last ok: {last_success}"
        else:
            badge = "⏳"; date_str = "—"
            clone_t = push_t = total_t = "—"

        out.append(
            f"| [{name}]({url}) | {build_type} | {topic_str} | {first_synced} | {date_str} |"
            f" {size} | {branches} | {tags} | {clone_t} | {push_t} | {total_t} |"
            f" {retries} | {badge} |\n"
        )
    out.append("\n")

out.append("---\n\n*Auto-generated — do not edit manually.*\n")

try:
    with open(readme_file, "w") as f:
        f.writelines(out)
    print("✅ README.md generated")
except Exception as e:
    print(f"[readme] write error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# ── Commit and push ───────────────────────────────────────────
commit_and_push() {
  local dir="$1"
  local message="$2"

  cd "$dir"
  git add -A

  if git diff --cached --quiet; then
    log "📋 No changes to commit"
    cd /
    return 0
  fi

  git commit -m "$message"
  git push origin HEAD:main 2>/dev/null || \
  git push origin HEAD:master 2>/dev/null || {
    log "⚠️  Push failed — trying force"
    git push --force origin HEAD:main 2>/dev/null || true
  }
  cd /
}

# ── Backup state + results to GitHub private repo ────────────
backup_to_state_repo() {
  local state_file="$1"

  log "💾 Backing up to private repo..."
  clone_or_init "$STATE_WORK" "$STATE_REMOTE" "state backup"
  
  # Use starport prefix to avoid conflicts with other systems in the same repo
  cp "$state_file" "$STATE_WORK/starport-state.json"

  # Also backup raw results if available
  if [ -f "$RESULTS_FILE" ]; then
    cp "$RESULTS_FILE" "$STATE_WORK/starport-sync-results.json"
  fi

  commit_and_push "$STATE_WORK" "starport state update: $TODAY"
  log "✅ Backed up starport-state.json + starport-sync-results.json"
}

# ── Main ──────────────────────────────────────────────────────
main() {
  log "📝 Starting README generation (mode: ${README_ONLY})"

  ensure_profile_repo

  local state_file

  if [ "$README_ONLY" = "true" ]; then
    # ── README-only: read state from GitHub private backup ─────
    log "📥 Fetching state from private backup..."
    clone_or_init "$STATE_WORK" "$STATE_REMOTE" "state backup"
    state_file="$STATE_WORK/starport-state.json"

    if [ ! -f "$state_file" ]; then
      log "⚠️  No starport-state.json found. Trying legacy state.json..."
      state_file="$STATE_WORK/state.json"
    fi

    if [ ! -f "$state_file" ]; then
      log "❌ No state file found in private backup — cannot generate README"
      exit 1
    fi

    clone_or_init "$PROFILE_WORK" "$PROFILE_REMOTE" "profile repo"
    cp "$state_file" "$PROFILE_WORK/starport-state.json"

  else
    # ── Sync mode ──────────────────────────────────────────────
    clone_or_init "$PROFILE_WORK" "$PROFILE_REMOTE" "profile repo"
    
    # Prefer starport-state.json, fallback to state.json for migration
    if [ -f "$PROFILE_WORK/starport-state.json" ]; then
      state_file="$PROFILE_WORK/starport-state.json"
    elif [ -f "$PROFILE_WORK/state.json" ]; then
      state_file="$PROFILE_WORK/state.json"
      log "🔄 Migrating legacy state.json to starport-state.json"
    else
      state_file="$PROFILE_WORK/starport-state.json"
      echo "{}" > "$state_file"
    fi

    if [ -f "$RESULTS_FILE" ]; then
      log "🔀 Merging sync results..."
      if ! merge_results "$state_file" "$RESULTS_FILE"; then
        # ── Fallback: try backed-up results from private repo ──
        log "⚠️  Merge failed — trying fallback from private backup..."
        clone_or_init "$STATE_WORK" "$STATE_REMOTE" "state backup"

        if [ -f "$STATE_WORK/starport-sync-results.json" ]; then
          log "📥 Using backed-up starport-sync-results.json"
          merge_results "$state_file" "$STATE_WORK/starport-sync-results.json" || {
            log "❌ Fallback merge also failed — generating README from existing state only"
          }
        elif [ -f "$STATE_WORK/sync-results.json" ]; then
          log "📥 Using legacy sync-results.json"
          merge_results "$state_file" "$STATE_WORK/sync-results.json" || {
             log "❌ Legacy merge also failed"
          }
        else
          log "⚠️  No backup results found — generating README from existing state only"
        fi
      fi
    else
      log "⚠️  No sync results — using existing state"
    fi

    log "🏷️  Fetching topics..."
    fetch_topics "$state_file" || log "⚠️  Topics fetch failed — continuing"

    backup_to_state_repo "$state_file"
  fi

  log "📄 Generating README..."
  generate_readme "$state_file" "$PROFILE_WORK/README.md"

  commit_and_push "$PROFILE_WORK" "readme: $TODAY"
  log "✅ README pushed"
  log "🏁 Done"
}

main