#!/bin/bash
# =============================================================
#  starport — sync.sh
#  Syncs selected OSS repos to a remote git host
#  - Reads repos.yml (grouped + ungrouped)
#  - Creates/transfers GitLab subgroups automatically
#  - Detects LFS via API — moves to lfs-repos.txt
#  - Checks latest commit SHA via API — skips unchanged repos
#  - FORCE_FULL=true bypasses SHA check
#  - Fetches only branches + tags (no PR/issue refs)
#  - Writes sync-results.json via Python (safe JSON escaping)
#  - Retries on network failure
#  - Suppresses verbose git output
# =============================================================

set -euo pipefail

export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false

# ── Required variables ────────────────────────────────────────
: "${REMOTE_TOKEN:?❌  REMOTE_TOKEN is not set}"
: "${PARENT_FOLDER:?❌  PARENT_FOLDER is not set}"
: "${REPOS_FILE:?❌  REPOS_FILE is not set}"
: "${GITHUB_TOKEN:?❌  GITHUB_TOKEN is not set}"
: "${GITHUB_WORKSPACE:?❌  GITHUB_WORKSPACE is not set}"

# ── Optional ──────────────────────────────────────────────────
FORCE_FULL="${FORCE_FULL:-false}"

# ── Resolve workspace paths ───────────────────────────────────
REPOS_FILE="$(realpath "$REPOS_FILE")"
LFS_FILE="${GITHUB_WORKSPACE}/lfs-repos.txt"
# ── Internal config ───────────────────────────────────────────
WORK_DIR="/tmp/void-work"
LOG_FILE="/tmp/sync.log"
VERBOSE_LOG="/tmp/sync-verbose.log"
RESULTS_FILE="/tmp/sync-results.json"
PREV_STATE="/tmp/prev-state.json"
MAX_RETRIES=3
RETRY_DELAY=10
API_COOLDOWN=0.5

# ── Counters ──────────────────────────────────────────────────
SUCCESS=0
FAILED=0
SKIPPED=0
LFS_MOVED=0
FAILED_REPOS=()

# ── In-memory results ─────────────────────────────────────────
RESULTS_DATA="{}"

# ── Helpers ───────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
hr()  { log "─────────────────────────────────────────────"; }

# Console: suppressed clean output
# Artifact: full verbose git output in /tmp/sync-verbose.log
silent() {
  local out exit_code=0
  out=$("$@" 2>&1) || exit_code=$?

  # Always write full raw output to verbose log
  if [ -n "$out" ]; then
    echo "--- CMD: $* ---" >> "$VERBOSE_LOG"
    echo "$out" >> "$VERBOSE_LOG"
    echo "" >> "$VERBOSE_LOG"
  fi

  # On failure — show sanitized short error in console only
  if [ $exit_code -ne 0 ]; then
    echo "$out" \
      | sed 's|https://[^ ]*||g' \
      | sed "s|$REMOTE_TOKEN|***|g" \
      | sed "s|$GITHUB_TOKEN|***|g" \
      | grep -v '^\s*$' \
      | head -5 \
      | while IFS= read -r line; do log "   $line"; done
    return $exit_code
  fi
}

# ── Clean up legacy GitLab logic ──────────────────────────────
# (Note: ensure_namespace and transfer_project are no longer used)

github_api() {
  local endpoint="$1"
  sleep $API_COOLDOWN
  curl -sf \
    --max-time 10 \
    --header "Authorization: Bearer $GITHUB_TOKEN" \
    --header "Accept: application/vnd.github+json" \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com${endpoint}" 2>/dev/null || echo ""
}

# ── Detect LFS via GitHub API ─────────────────────────────────
has_lfs() {
  local owner="$1"
  local repo="$2"
  local response
  response=$(github_api "/repos/${owner}/${repo}/contents/.gitattributes")
  [ -z "$response" ] && return 1
  echo "$response" | python3 -c "
import sys, json, base64
try:
    data = json.load(sys.stdin)
    content = base64.b64decode(data.get('content','')).decode('utf-8',errors='ignore')
    sys.exit(0 if 'lfs' in content.lower() else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null
}

# ── Get latest commit SHA ─────────────────────────────────────
get_latest_sha() {
  local owner="$1"
  local repo="$2"
  local branch="${3:-}"
  local response
  local endpoint
  if [ -n "$branch" ]; then
    endpoint="/repos/${owner}/${repo}/commits/${branch}"
    response=$(github_api "$endpoint")
    [ -z "$response" ] && echo "" && return 0
    echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('sha','') if isinstance(data,dict) else '')
except Exception:
    print('')
" 2>/dev/null || echo ""
  else
    # default branch
    endpoint="/repos/${owner}/${repo}/commits?per_page=1"
    response=$(github_api "$endpoint")
    [ -z "$response" ] && echo "" && return 0
    echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data[0].get('sha','') if isinstance(data,list) and data else '')
except Exception:
    print('')
" 2>/dev/null || echo ""
  fi
}


# ── Get last known SHA from previous state ────────────────────
# Pass URL as argument to avoid bash variable expansion in Python
get_last_sha() {
  local url="$1"
  [ ! -f "$PREV_STATE" ] && echo "" && return 0
  python3 - "$PREV_STATE" "$url" << 'PYEOF'
import json, sys
state_file = sys.argv[1]
url        = sys.argv[2]
try:
    with open(state_file) as f:
        state = json.load(f)
    print(state.get(url, {}).get('last_commit_sha', ''))
except Exception:
    print('')
PYEOF
}

# ── Move repo from repos.yml to lfs-repos.txt ─────────────────
move_to_lfs_file() {
  local url="$1"
  python3 "${GITHUB_WORKSPACE}/scripts/python/add-to-repos.py" \
    --remove "$REPOS_FILE" "$url" 2>/dev/null || true
  touch "$LFS_FILE"
  grep -qF "$url" "$LFS_FILE" 2>/dev/null || echo "$url" >> "$LFS_FILE"
}

# ── Add result to in-memory dict ──────────────────────────────
add_result() {
  local url="$1" subgroup="$2" status="$3"
  local clone_time="${4:-0}" push_time="${5:-0}" total_time="${6:-0}"
  local repo_size="${7:-—}" branches="${8:-0}" tags="${9:-0}"
  local retries="${10:-0}" commit_sha="${11:-}"

  RESULTS_DATA=$(python3 - \
    "$RESULTS_DATA" "$url" "$subgroup" "$status" \
    "$clone_time" "$push_time" "$total_time" \
    "$repo_size" "$branches" "$tags" \
    "$retries" "$commit_sha" << 'PYEOF'
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    data = {}

url        = sys.argv[2]
subgroup   = sys.argv[3]
status     = sys.argv[4]
clone_time = int(sys.argv[5])
push_time  = int(sys.argv[6])
total_time = int(sys.argv[7])
repo_size  = sys.argv[8]
branches   = int(sys.argv[9])  if sys.argv[9].isdigit()  else 0
tags       = int(sys.argv[10]) if sys.argv[10].isdigit() else 0
retries    = int(sys.argv[11])
commit_sha = sys.argv[12]

entry = {
    "subgroup":        subgroup,
    "status":          status,
    "last_commit_sha": commit_sha,
}

# Only write timing/size for non-skipped repos
if status != "skipped":
    entry.update({
        "clone_time": clone_time,
        "push_time":  push_time,
        "total_time": total_time,
        "size":       repo_size,
        "branches":   branches,
        "tags":       tags,
        "retries":    retries,
    })

data[url] = entry
print(json.dumps(data))
PYEOF
) || true
}

# ── Detect if PARENT_FOLDER is a user or an org ───────────────
_is_org() {
  local type
  type=$(curl -s \
    --header "Authorization: Bearer $REMOTE_TOKEN" \
    --header "Accept: application/vnd.github+json" \
    "https://api.github.com/users/${PARENT_FOLDER}" \
    | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin).get('type','User'))
except Exception:
    print('User')
" 2>/dev/null)
  [ "$type" = "Organization" ]
}

# ── Ensure destination repo exists ────────────────────────────
ensure_remote_repo() {
  local repo_name="$1"
  local full_name="${PARENT_FOLDER}/${repo_name}"

  # Check if repo already exists
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    --header "Authorization: Bearer $REMOTE_TOKEN" \
    "https://api.github.com/repos/$full_name")

  if [ "$status" = "200" ]; then
    log "   📦 Repo exists: $full_name"
    RESOLVED_REPO_NAME="$full_name"
    return 0
  fi

  # Choose correct creation endpoint: org vs personal account
  log "   🆕 Creating repo: $full_name"
  local create_url
  if _is_org; then
    create_url="https://api.github.com/orgs/${PARENT_FOLDER}/repos"
  else
    create_url="https://api.github.com/user/repos"
  fi

  local response result
  response=$(curl -s -w "\n%{http_code}" \
    --request POST \
    --header "Authorization: Bearer $REMOTE_TOKEN" \
    --header "Content-Type: application/json" \
    --data "{\"name\":\"${repo_name}\",\"private\":true,\"auto_init\":false}" \
    "$create_url")

  result=$(echo "$response" | tail -1)
  if [ "$result" = "201" ]; then
    RESOLVED_REPO_NAME="$full_name"
    return 0
  fi

  local body
  body=$(echo "$response" | head -n -1 | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('message', str(d))[:200])
except Exception:
    print(sys.stdin.read()[:200])
" 2>/dev/null)
  log "   ❌ Failed to create repo (HTTP $result): $body"
  log "   💡 Ensure REMOTE_TOKEN has 'repo' scope (classic) or 'Administration: Read & Write' on all repos (fine-grained)"
  return 1
}

# ── Sync a single repo ────────────────────────────────────────
sync_repo() {
  local source_url="$1"
  local pref_name="$2"
  local target_branch="$3"
  local build_type="$4"

  local repo_name
  [ -n "$pref_name" ] && repo_name="$pref_name" || repo_name=$(basename "$source_url" .git)
  
  local owner
  owner=$(echo "$source_url" | sed 's|https://github.com/||' | cut -d/ -f1)
  local origin_repo_name
  origin_repo_name=$(echo "$source_url" | sed 's|https://github.com/||' | cut -d/ -f2 | sed 's/\.git$//')
  
  local work_dir="$WORK_DIR/$repo_name"
  local dest_path="${PARENT_FOLDER}/${repo_name}.git"

  # GitHub uses prefix-less URLs for personal repos usually
  local dest_url="https://x-access-token:${REMOTE_TOKEN}@github.com/${PARENT_FOLDER}/${repo_name}.git"

  log "⏳ $repo_name (branch: ${target_branch:-default})"

  # ── LFS check ─────────────────────────────────────────────────
  if grep -qF "$source_url" "$LFS_FILE" 2>/dev/null; then
    log "⏭️  $repo_name — already in LFS exclusion list"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi

  if has_lfs "$owner" "$origin_repo_name"; then
    log "🗂️  $repo_name — LFS detected, moving to exclusion list"
    move_to_lfs_file "$source_url"
    LFS_MOVED=$((LFS_MOVED + 1))
    return 0
  fi

  # ── SHA check ─────────────────────────────────────────────────
  local current_sha="" last_sha=""

  if [ "$FORCE_FULL" = "true" ]; then
    log "   🔁 Force full sync"
  else
    current_sha=$(get_latest_sha "$owner" "$origin_repo_name" "$target_branch")
    last_sha=$(get_last_sha "$source_url")

    if [ -n "$current_sha" ] && [ -n "$last_sha" ] && [ "$current_sha" = "$last_sha" ]; then
      log "⏭️  $repo_name — no changes since last sync"
      add_result "$source_url" "" "skipped" 0 0 0 "—" 0 0 0 "$current_sha"
      SKIPPED=$((SKIPPED + 1))
      return 0
    fi
    [ -z "$current_sha" ] && log "   ⚠️  Could not fetch SHA — proceeding anyway"
  fi

  # ── Ensure repo ───────────────────────────────────
  if ! ensure_remote_repo "$repo_name"; then
    log "❌ $repo_name — could not prepare destination repo"
    add_result "$source_url" "" "failed" 0 0 0 "—" 0 0 0 "$current_sha"
    FAILED=$((FAILED + 1))
    FAILED_REPOS+=("$repo_name")
    return 1
  fi

  mkdir -p "$work_dir"

  # ── Fetch only branches + tags ────────────────────────────────
  local clone_start clone_end clone_time
  clone_start=$(date +%s)

  if ! (
    silent git init --bare "$work_dir" && \
    cd "$work_dir" && \
    silent git remote add origin "$source_url" && \
    with_retry git fetch --prune origin       '+refs/heads/*:refs/heads/*'       '+refs/tags/*:refs/tags/*' 2>> "$VERBOSE_LOG"
  ); then
    log "❌ $repo_name — fetch failed"
    rm -rf "$work_dir"
    add_result "$source_url" "" "failed" 0 0 0 "—" 0 0 0 "$current_sha"
    FAILED=$((FAILED + 1))
    FAILED_REPOS+=("$repo_name")
    return 1
  fi


  clone_end=$(date +%s)
  clone_time=$((clone_end - clone_start))

  # ── Metrics ───────────────────────────────────────────────────
  local repo_size repo_size_bytes branch_count tag_count
  repo_size_bytes=$(du -sb "$work_dir" 2>/dev/null | cut -f1 || echo 0)
  repo_size=$(python3 -c "
s=$repo_size_bytes
if s<1024: print(f'{s} B')
elif s<1048576: print(f'{s/1024:.1f} KB')
elif s<1073741824: print(f'{s/1048576:.1f} MB')
else: print(f'{s/1073741824:.2f} GB')
")
  cd "$work_dir"
  branch_count=$(git branch | wc -l | tr -d ' ')
  tag_count=$(git tag | wc -l | tr -d ' ')

  # ── Push ──────────────────────────────────────────────────────
  local push_start push_end push_time retries=0
  push_start=$(date +%s)
  local push_attempt=1 push_ok=false

  while [ $push_attempt -le $MAX_RETRIES ]; do
    if silent git push --prune "$dest_url" \
        '+refs/heads/*:refs/heads/*' \
        '+refs/tags/*:refs/tags/*'; then
      push_ok=true
      break
    fi
    if [ $push_attempt -lt $MAX_RETRIES ]; then
      retries=$((retries + 1))
      log "   ⚠️  Push attempt $push_attempt failed — retrying in ${RETRY_DELAY}s..."
      sleep $RETRY_DELAY
    fi
    push_attempt=$((push_attempt + 1))
  done

  push_end=$(date +%s)
  push_time=$((push_end - push_start))
  local total_time=$((clone_time + push_time))

  cd /
  rm -rf "$work_dir"

  if [ "$push_ok" = false ]; then
    log "❌ $display_name — push failed"
    add_result "$source_url" "$subgroup" "failed" \
      "$clone_time" "$push_time" "$total_time" \
      "$repo_size" "$branch_count" "$tag_count" "$retries" "$current_sha"
    FAILED=$((FAILED + 1))
    FAILED_REPOS+=("$display_name")
    return 1
  fi

  # ── Track Build requirements ──────────────────────────────
  if [ -n "$build_type" ]; then
    log "   🏗️  Queuing build for $repo_name ($build_type)"
    python3 - "$REPOS_FILE" "$source_url" << 'PYEOF' >> /tmp/build-matrix-items.json
import yaml, sys, json
repos_file = sys.argv[1]
source_url = sys.argv[2]
try:
    with open(repos_file) as f:
        data = yaml.safe_load(f)
    for r in data.get('repos', []):
        if r.get('url') == source_url:
            build = r.get('build', {})
            item = {
                "name": r.get('name', 'app'),
                "source_repo": r.get('url').replace('https://github.com/', ''),
                "branch": r.get('branch', ''),
                "build_type": build.get('type', ''),
                "targets": ",".join(build.get('targets', [])),
                "runner": build.get('runner', 'ubuntu-latest')
            }
            print(json.dumps(item))
            break
except Exception:
    pass
PYEOF
    echo "," >> /tmp/build-matrix-items.json
  fi

  log "✅ $display_name (clone: ${clone_time}s push: ${push_time}s total: ${total_time}s size: $repo_size)"
  add_result "$source_url" "$subgroup" "success" \
    "$clone_time" "$push_time" "$total_time" \
    "$repo_size" "$branch_count" "$tag_count" "$retries" "$current_sha"
  SUCCESS=$((SUCCESS + 1))
}


# ── Main ──────────────────────────────────────────────────────
main() {
  hr
  log "🚀 starport sync started (force_full: $FORCE_FULL)"
  hr

  if [ ! -f "$REPOS_FILE" ]; then
    log "❌ Repos file not found: $REPOS_FILE"
    exit 1
  fi

  python3 -c "import yaml" 2>/dev/null || {
    log "📦 Installing PyYAML..."
    pip install pyyaml -q --break-system-packages 2>/dev/null || true
  }

  mkdir -p "$WORK_DIR"
  touch "$LFS_FILE"

  TOTAL_START=$(date +%s)

  mapfile -t REPO_LINES < <(
    python3 "${GITHUB_WORKSPACE}/scripts/python/parse-repos.py" "$REPOS_FILE" 2>/dev/null || true
  )

  for line in "${REPO_LINES[@]}"; do
    [ -z "$line" ] && continue
    local url pref_name target_branch build_type
    url=$(echo "$line" | awk '{print $1}')
    pref_name=$(echo "$line" | awk '{print $2}')
    target_branch=$(echo "$line" | awk '{print $3}')
    build_type=$(echo "$line" | awk '{print $4}')
    
    sync_repo "$url" "${pref_name:-}" "${target_branch:-}" "${build_type:-}"
  done


  TOTAL_END=$(date +%s)
  TOTAL_RUN=$((TOTAL_END - TOTAL_START))

  # ── Prepare Build Matrix ─────────────────────────────────────
  if [ -f /tmp/build-matrix-items.json ]; then
    # Create valid JSON array and remove trailing comma
    local matrix_json="["
    matrix_json+=$(sed '$ s/,$//' /tmp/build-matrix-items.json | tr -d '\n')
    matrix_json+="]"
    echo "$matrix_json" > /tmp/final-build-matrix.json
    log "📦 Build matrix prepared for ${#REPO_LINES[@]} repos"
  fi

  # Write results JSON safely via Python

  echo "$RESULTS_DATA" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    with open('$RESULTS_FILE', 'w') as f:
        json.dump(data, f, indent=2)
    print('✅ Results written')
except Exception as e:
    print(f'❌ Results write error: {e}', file=sys.stderr)
    sys.exit(1)
"

  hr
  log "📊 Done — ✅ $SUCCESS synced  ⏭️  $SKIPPED skipped  🗂️  $LFS_MOVED LFS moved  ❌ ${#FAILED_REPOS[@]} failed  ⏱️  ${TOTAL_RUN}s"

  if [ ${#FAILED_REPOS[@]} -gt 0 ]; then
    log "🔴 Failed:"
    for r in "${FAILED_REPOS[@]}"; do
      log "   - $r"
    done
  fi
  hr

  if [ "${#FAILED_REPOS[@]}" -gt 0 ]; then exit 1; else exit 0; fi
}

main