#!/usr/bin/env bash
set -euo pipefail

SEARCH_ROOT="${1:-}"
OUTPUT_DIR="${OUTPUT_DIR:-./eks-virtualservice-report}"
CSV_FILE="${OUTPUT_DIR}/virtualservice_fqdns.csv"
CONFLUENCE_FILE="${OUTPUT_DIR}/virtualservice_fqdns_confluence.md"
ISSUES_FILE="${OUTPUT_DIR}/virtualservice_issues.csv"
DUP_FILE="${OUTPUT_DIR}/duplicate_fqdns.txt"

usage() {
  cat <<USAGE
Usage: $0 /path/to/git/workspace

Environment variables:
  OUTPUT_DIR   Output directory (default: ./eks-virtualservice-report)

Requirements:
  bash 4+
  git
  python3
  Python PyYAML module

Example:
  $0 /opt/apps/git
USAGE
}

[[ -n "$SEARCH_ROOT" ]] || { usage; exit 1; }
[[ -d "$SEARCH_ROOT" ]] || { echo "ERROR: Directory does not exist: $SEARCH_ROOT" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git is required." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required." >&2; exit 1; }
python3 -c 'import yaml' >/dev/null 2>&1 || {
  echo "ERROR: Python PyYAML module is required." >&2
  echo "Install with: python3 -m pip install --user pyyaml" >&2
  exit 1
}

SEARCH_ROOT="$(cd "$SEARCH_ROOT" && pwd)"
mkdir -p "$OUTPUT_DIR"

printf '"Environment","Project","Namespace","VirtualService","Gateway","FQDN","Owner","Status","GitBranch","GitRemote","Manifest"\n' > "$CSV_FILE"
printf '"Environment","Project","Namespace","VirtualService","FQDN","Issue","Manifest"\n' > "$ISSUES_FILE"

cat > "$CONFLUENCE_FILE" <<EOF2
# EKS Istio VirtualService FQDN Inventory

Generated: $(date '+%Y-%m-%d %H:%M:%S')

Search root: \`${SEARCH_ROOT}\`

This inventory lists application/external FQDNs configured in Istio VirtualService manifests found in the Git/VS Code workspace. Kubernetes internal service hostnames ending in \`.svc.cluster.local\` are excluded.

## FQDN Inventory

| Environment | Project | Namespace | VirtualService | Gateway | FQDN | Owner | Status | Manifest |
|---|---|---|---|---|---|---|---|---|
EOF2

FILES_SCANNED=0
INTERNAL_HOSTS_EXCLUDED=0

get_repo_root() {
  local file="$1" dir
  dir="$(dirname "$file")"
  while [[ "$dir" != "/" ]]; do
    if [[ -d "$dir/.git" ]]; then printf '%s\n' "$dir"; return 0; fi
    [[ "$dir" == "$SEARCH_ROOT" ]] && break
    dir="$(dirname "$dir")"
  done
  return 1
}

get_project_name() {
  local file="$1" repo rel
  if repo="$(get_repo_root "$file" 2>/dev/null)"; then
    basename "$repo"
  else
    rel="${file#${SEARCH_ROOT}/}"
    printf '%s\n' "${rel%%/*}"
  fi
}

get_git_branch() {
  local file="$1" repo branch
  repo="$(get_repo_root "$file" 2>/dev/null || true)"
  if [[ -n "$repo" ]] && branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)"; then
    printf '%s' "$branch"
  else
    printf '%s' '-'
  fi
}

get_git_remote() {
  local file="$1" repo
  repo="$(get_repo_root "$file" 2>/dev/null || true)"
  if [[ -n "$repo" ]]; then
    git -C "$repo" config --get remote.origin.url 2>/dev/null || printf '%s' '-'
  else
    printf '%s' '-'
  fi
}

detect_environment() {
  local file="$1" namespace="$2" host="$3" text
  text="$(printf '%s %s %s' "$file" "$namespace" "$host" | tr '[:upper:]' '[:lower:]')"
  case "$text" in
    *prod*|*production*) printf '%s' 'PROD' ;;
    *uat*) printf '%s' 'UAT' ;;
    *stage*|*staging*) printf '%s' 'STAGE' ;;
    *qa*|*quality*) printf '%s' 'QA' ;;
    *test*|*tst*) printf '%s' 'TEST' ;;
    *dev*|*development*) printf '%s' 'DEV' ;;
    *) printf '%s' 'UNKNOWN' ;;
  esac
}

is_external_host() {
  local host="$1"
  [[ -n "$host" ]] || return 1
  [[ "$host" != *.svc.cluster.local ]]
}

valid_hostname() {
  local host="$1"
  [[ "$host" =~ ^(\*\.)?([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

extract_virtualservices() {
  local file="$1"
  python3 - "$file" <<'PY'
import sys
import yaml

path = sys.argv[1]
try:
    with open(path, 'r', encoding='utf-8') as fh:
        docs = list(yaml.safe_load_all(fh))
except Exception:
    sys.exit(0)

for doc in docs:
    if not isinstance(doc, dict) or doc.get('kind') != 'VirtualService':
        continue

    meta = doc.get('metadata') or {}
    spec = doc.get('spec') or {}
    labels = meta.get('labels') or {}

    namespace = meta.get('namespace') or 'default'
    name = meta.get('name') or 'unknown'
    owner = (
        labels.get('app.kubernetes.io/owner')
        or labels.get('owner')
        or labels.get('team')
        or '-'
    )

    gateways = spec.get('gateways') or []
    if not isinstance(gateways, list):
        gateways = [str(gateways)]
    gateway_text = ','.join(str(x) for x in gateways) if gateways else '-'

    hosts = spec.get('hosts') or []
    if not isinstance(hosts, list):
        hosts = [hosts]

    for host in hosts:
        if host is None:
            continue
        values = [namespace, name, owner, gateway_text, str(host)]
        print('\t'.join(v.replace('\t', ' ').replace('\n', ' ') for v in values))
PY
}

gateway_accepts_host() {
  local file="$1" gateway="$2" host="$3" repo_root search_base gw_name gw_ns
  [[ "$gateway" == "-" || -z "$gateway" ]] && return 2

  repo_root="$(get_repo_root "$file" 2>/dev/null || true)"
  search_base="${repo_root:-$(dirname "$file")}"
  gw_name="${gateway##*/}"
  gw_ns="${gateway%/*}"
  [[ "$gw_ns" == "$gateway" ]] && gw_ns=""

  python3 - "$search_base" "$gw_name" "$gw_ns" "$host" <<'PY'
import fnmatch
import os
import sys
import yaml

root, gateway_name, gateway_ns, host = sys.argv[1:5]
exclude_dirs = {'.git', 'node_modules', 'vendor', '.terraform', 'dist', 'build'}

def host_matches(pattern, value):
    if pattern == '*':
        return True
    if pattern == value:
        return True
    if pattern.startswith('*.'):
        return fnmatch.fnmatch(value, pattern)
    if '/' in pattern:
        pattern = pattern.split('/', 1)[1]
        if pattern == '*':
            return True
        if pattern == value:
            return True
        if pattern.startswith('*.'):
            return fnmatch.fnmatch(value, pattern)
    return False

for current, dirs, files in os.walk(root):
    dirs[:] = [d for d in dirs if d not in exclude_dirs]
    for name in files:
        if not name.endswith(('.yaml', '.yml')):
            continue
        path = os.path.join(current, name)
        try:
            with open(path, 'r', encoding='utf-8') as fh:
                docs = yaml.safe_load_all(fh)
                for doc in docs:
                    if not isinstance(doc, dict) or doc.get('kind') != 'Gateway':
                        continue
                    meta = doc.get('metadata') or {}
                    if meta.get('name') != gateway_name:
                        continue
                    ns = meta.get('namespace') or 'default'
                    if gateway_ns and ns != gateway_ns:
                        continue
                    spec = doc.get('spec') or {}
                    for server in spec.get('servers') or []:
                        if not isinstance(server, dict):
                            continue
                        for pattern in server.get('hosts') or []:
                            if host_matches(str(pattern), host):
                                sys.exit(0)
        except Exception:
            continue

sys.exit(1)
PY
}

csv_escape() {
  local s="${1//\"/\"\"}"
  printf '"%s"' "$s"
}

while IFS= read -r -d '' FILE; do
  ((FILES_SCANNED+=1))

  PROJECT="$(get_project_name "$FILE")"
  BRANCH="$(get_git_branch "$FILE")"
  REMOTE="$(get_git_remote "$FILE")"
  RELATIVE_FILE="${FILE#${SEARCH_ROOT}/}"

  while IFS=$'\t' read -r NAMESPACE VS_NAME OWNER GATEWAYS HOST; do
    [[ -n "$HOST" ]] || continue

    NAMESPACE="${NAMESPACE:-default}"
    VS_NAME="${VS_NAME:-unknown}"
    OWNER="${OWNER:--}"
    GATEWAYS="${GATEWAYS:--}"

    if ! is_external_host "$HOST"; then
      ((INTERNAL_HOSTS_EXCLUDED+=1))
      continue
    fi

    ENVIRONMENT="$(detect_environment "$RELATIVE_FILE" "$NAMESPACE" "$HOST")"
    STATUS="VALID"
    ISSUE=""

    if [[ "$HOST" == \*.* ]]; then
      STATUS="WILDCARD"
      ISSUE="Wildcard hostname"
    elif ! valid_hostname "$HOST"; then
      STATUS="NONSTANDARD"
      ISSUE="Hostname does not match expected FQDN syntax"
    fi

    if [[ "$GATEWAYS" == "-" ]]; then
      STATUS="MISSING_GATEWAY"
      ISSUE="VirtualService has no explicit gateway"
    else
      IFS=',' read -ra GW_ARRAY <<< "$GATEWAYS"
      for GW in "${GW_ARRAY[@]}"; do
        GW="${GW#${GW%%[![:space:]]*}}"
        GW="${GW%${GW##*[![:space:]]}}"
        set +e
        gateway_accepts_host "$FILE" "$GW" "$HOST"
        rc=$?
        set -e
        if [[ $rc -eq 1 ]]; then
          STATUS="GATEWAY_HOST_MISMATCH"
          ISSUE="Host not found on referenced Gateway in repository manifests"
          break
        fi
      done
    fi

    {
      csv_escape "$ENVIRONMENT"; printf ','
      csv_escape "$PROJECT"; printf ','
      csv_escape "$NAMESPACE"; printf ','
      csv_escape "$VS_NAME"; printf ','
      csv_escape "$GATEWAYS"; printf ','
      csv_escape "$HOST"; printf ','
      csv_escape "$OWNER"; printf ','
      csv_escape "$STATUS"; printf ','
      csv_escape "$BRANCH"; printf ','
      csv_escape "$REMOTE"; printf ','
      csv_escape "$RELATIVE_FILE"; printf '\n'
    } >> "$CSV_FILE"

    printf '| %s | %s | %s | %s | %s | `%s` | %s | %s | `%s` |\n' \
      "$ENVIRONMENT" "$PROJECT" "$NAMESPACE" "$VS_NAME" "$GATEWAYS" "$HOST" "$OWNER" "$STATUS" "$RELATIVE_FILE" >> "$CONFLUENCE_FILE"

    if [[ -n "$ISSUE" ]]; then
      {
        csv_escape "$ENVIRONMENT"; printf ','
        csv_escape "$PROJECT"; printf ','
        csv_escape "$NAMESPACE"; printf ','
        csv_escape "$VS_NAME"; printf ','
        csv_escape "$HOST"; printf ','
        csv_escape "$ISSUE"; printf ','
        csv_escape "$RELATIVE_FILE"; printf '\n'
      } >> "$ISSUES_FILE"
    fi
  done < <(extract_virtualservices "$FILE")

done < <(
  find "$SEARCH_ROOT" \
    \( -type d \( -name .git -o -name node_modules -o -name vendor -o -name .terraform -o -name dist -o -name build \) -prune \) -o \
    \( -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 \)
)

{ head -1 "$CSV_FILE"; tail -n +2 "$CSV_FILE" | sort -u; } > "$CSV_FILE.tmp" && mv "$CSV_FILE.tmp" "$CSV_FILE"
{ head -1 "$ISSUES_FILE"; tail -n +2 "$ISSUES_FILE" | sort -u; } > "$ISSUES_FILE.tmp" && mv "$ISSUES_FILE.tmp" "$ISSUES_FILE"

python3 - "$CSV_FILE" "$DUP_FILE" <<'PY'
import csv
import collections
import sys

csv_file, dup_file = sys.argv[1:3]
counts = collections.Counter()
with open(csv_file, newline='', encoding='utf-8') as fh:
    for row in csv.DictReader(fh):
        fqdn = (row.get('FQDN') or '').strip()
        if fqdn:
            counts[fqdn] += 1

with open(dup_file, 'w', encoding='utf-8') as out:
    for fqdn in sorted(k for k, v in counts.items() if v > 1):
        out.write(fqdn + '\n')
PY

read -r TOTAL_RECORDS TOTAL_ISSUES TOTAL_FQDNS TOTAL_PROJECTS < <(
  python3 - "$CSV_FILE" "$ISSUES_FILE" <<'PY'
import csv
import sys

csv_file, issues_file = sys.argv[1:3]
with open(csv_file, newline='', encoding='utf-8') as fh:
    rows = list(csv.DictReader(fh))
with open(issues_file, newline='', encoding='utf-8') as fh:
    issues = list(csv.DictReader(fh))

fqdns = {r.get('FQDN', '') for r in rows if r.get('FQDN')}
projects = {r.get('Project', '') for r in rows if r.get('Project')}
print(len(rows), len(issues), len(fqdns), len(projects))
PY
)
DUP_COUNT="$(wc -l < "$DUP_FILE" | tr -d ' ')"

cat >> "$CONFLUENCE_FILE" <<EOF2

## Summary

| Metric | Count |
|---|---:|
| YAML Files Scanned | ${FILES_SCANNED} |
| Projects with FQDN Records | ${TOTAL_PROJECTS} |
| Unique External FQDNs | ${TOTAL_FQDNS} |
| VirtualService / FQDN Mappings | ${TOTAL_RECORDS} |
| Validation Issues | ${TOTAL_ISSUES} |
| Duplicate FQDNs | ${DUP_COUNT} |
| Internal Hosts Excluded | ${INTERNAL_HOSTS_EXCLUDED} |

## Exclusions

Kubernetes internal service hostnames ending in \`.svc.cluster.local\` are excluded from this inventory.
EOF2

echo
echo "============================================================"
echo "VirtualService FQDN inventory completed"
echo "============================================================"
echo "Search root:              $SEARCH_ROOT"
echo "YAML files scanned:       $FILES_SCANNED"
echo "Projects:                 $TOTAL_PROJECTS"
echo "Unique external FQDNs:    $TOTAL_FQDNS"
echo "Validation issues:        $TOTAL_ISSUES"
echo "Duplicate FQDNs:          $DUP_COUNT"
echo "Internal hosts excluded:  $INTERNAL_HOSTS_EXCLUDED"
echo
echo "CSV report:               $CSV_FILE"
echo "Issues report:            $ISSUES_FILE"
echo "Duplicate FQDN list:      $DUP_FILE"
echo "Confluence report:        $CONFLUENCE_FILE"
