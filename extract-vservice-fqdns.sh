#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=false
SEARCH_ROOT=""
REQUESTED_OUTPUT_DIR="${OUTPUT_DIR:-./eks-virtualservice-report}"
TEMP_OUTPUT_DIR=""

usage() {
  cat <<USAGE
Usage:
  $0 [--dry-run|-n] /path/to/git/workspace

Options:
  -n, --dry-run   Scan and validate without persisting report files.
  -h, --help      Show this help message.

Environment variables:
  OUTPUT_DIR      Output directory for a normal run
                  (default: ./eks-virtualservice-report)

Requirements:
  bash 4+
  git
  python3
  Python PyYAML module

Examples:
  $0 /opt/apps/git
  $0 --dry-run /opt/apps/git
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "ERROR: Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$SEARCH_ROOT" ]]; then
        echo "ERROR: Only one workspace path may be specified." >&2
        exit 1
      fi
      SEARCH_ROOT="$1"
      shift
      ;;
  esac
done

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

if [[ "$DRY_RUN" == true ]]; then
  TEMP_OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/eks-vservice-fqdn-dryrun.XXXXXX")"
  trap 'rm -rf "$TEMP_OUTPUT_DIR"' EXIT INT TERM
  OUTPUT_DIR="$TEMP_OUTPUT_DIR"
else
  OUTPUT_DIR="$REQUESTED_OUTPUT_DIR"
fi

mkdir -p "$OUTPUT_DIR"

CSV_FILE="${OUTPUT_DIR}/virtualservice_fqdns.csv"
TEXT_FILE="${OUTPUT_DIR}/virtualservice_fqdns.txt"
CONFLUENCE_FILE="${OUTPUT_DIR}/virtualservice_fqdns_confluence.md"
ISSUES_FILE="${OUTPUT_DIR}/virtualservice_issues.csv"
DUP_FILE="${OUTPUT_DIR}/duplicate_fqdns.txt"

printf '"Environment","Project","Namespace","VirtualService","HTTPS_URL","DestinationPort","GitRemote","Manifest"\n' > "$CSV_FILE"
printf '"Environment","Project","Namespace","VirtualService","HTTPS_URL","Issue","Manifest"\n' > "$ISSUES_FILE"

cat > "$TEXT_FILE" <<EOF2
EKS ISTIO VIRTUALSERVICE - EXTERNAL FQDN INVENTORY
=================================================
Generated: $(date '+%Y-%m-%d %H:%M:%S')
Search Root: ${SEARCH_ROOT}
Mode: $([[ "$DRY_RUN" == true ]] && printf 'DRY-RUN' || printf 'NORMAL')

Internal Kubernetes hosts ending in .svc.cluster.local are excluded.
External hosts are rendered as HTTPS URLs.
Namespace is read from the project's config.json first, then VirtualService metadata.namespace as a fallback.
Environment detection prioritizes namespace suffix, then FQDN, then manifest path.

FQDN INVENTORY
--------------
EOF2

FILES_SCANNED=0
INTERNAL_HOSTS_EXCLUDED=0

get_repo_root() {
  local file="$1" dir
  dir="$(dirname "$file")"
  while [[ "$dir" != "/" ]]; do
    if [[ -d "$dir/.git" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
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

get_git_remote() {
  local file="$1" repo
  repo="$(get_repo_root "$file" 2>/dev/null || true)"
  if [[ -n "$repo" ]]; then
    git -C "$repo" config --get remote.origin.url 2>/dev/null || printf '%s' '-'
  else
    printf '%s' '-'
  fi
}

extract_namespace_from_config() {
  local config_file="$1"

  python3 - "$config_file" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, 'r', encoding='utf-8') as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)

preferred_paths = [
    ('namespace',),
    ('kubernetes', 'namespace'),
    ('eks', 'namespace'),
    ('deployment', 'namespace'),
    ('metadata', 'namespace'),
    ('config', 'namespace'),
]

def get_path(obj, parts):
    cur = obj
    for part in parts:
        if not isinstance(cur, dict):
            return None
        match = next((k for k in cur if str(k).lower() == part.lower()), None)
        if match is None:
            return None
        cur = cur[match]
    return cur

for parts in preferred_paths:
    value = get_path(data, parts)
    if isinstance(value, (str, int, float)) and str(value).strip():
        print(str(value).strip())
        sys.exit(0)

# Fallback: recursively locate the first scalar key named "namespace".
def find_namespace(obj):
    if isinstance(obj, dict):
        for key, value in obj.items():
            if str(key).lower() == 'namespace' and isinstance(value, (str, int, float)):
                text = str(value).strip()
                if text:
                    return text
        for value in obj.values():
            found = find_namespace(value)
            if found:
                return found
    elif isinstance(obj, list):
        for value in obj:
            found = find_namespace(value)
            if found:
                return found
    return None

value = find_namespace(data)
if value:
    print(value)
PY
}

get_config_namespace() {
  local file="$1" repo dir config_file

  repo="$(get_repo_root "$file" 2>/dev/null || true)"
  [[ -n "$repo" ]] || return 0

  # Prefer a config.json closest to the manifest by walking upward
  # from the manifest directory to the Git repository root.
  dir="$(dirname "$file")"
  while true; do
    if [[ -f "$dir/config.json" ]]; then
      extract_namespace_from_config "$dir/config.json"
      return 0
    fi
    [[ "$dir" == "$repo" || "$dir" == "/" ]] && break
    dir="$(dirname "$dir")"
  done

  # Fallback for repositories where config.json is stored elsewhere.
  config_file="$(find "$repo" \
    \( -type d \( -name .git -o -name node_modules -o -name vendor -o -name .terraform -o -name dist -o -name build \) -prune \) -o \
    \( -type f -name 'config.json' -print \) 2>/dev/null | head -n 1)"

  if [[ -n "$config_file" ]]; then
    extract_namespace_from_config "$config_file"
  fi
}

detect_environment() {
  local file="$1" namespace="$2" host="$3"
  local ns_lower host_lower file_lower

  ns_lower="$(printf '%s' "$namespace" | tr '[:upper:]' '[:lower:]')"
  case "$ns_lower" in
    *-prod|*-production) printf '%s' 'PROD'; return ;;
    *-shadow)            printf '%s' 'SHADOW'; return ;;
    *-uat)               printf '%s' 'UAT'; return ;;
    *-stage|*-staging)   printf '%s' 'STAGE'; return ;;
    *-qa)                printf '%s' 'QA'; return ;;
    *-test|*-tst)        printf '%s' 'TEST'; return ;;
    *-dev|*-development) printf '%s' 'DEV'; return ;;
  esac

  host_lower="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  case "$host_lower" in
    *.prod.*|*.production.*|*-prod.*) printf '%s' 'PROD'; return ;;
    *.shadow.*|*-shadow.*)            printf '%s' 'SHADOW'; return ;;
    *.uat.*|*-uat.*)                  printf '%s' 'UAT'; return ;;
    *.stage.*|*.staging.*|*-stage.*|*-staging.*) printf '%s' 'STAGE'; return ;;
    *.qa.*|*-qa.*)                    printf '%s' 'QA'; return ;;
    *.test.*|*.tst.*|*-test.*|*-tst.*) printf '%s' 'TEST'; return ;;
    *.dev.*|*.development.*|*-dev.*|*-development.*) printf '%s' 'DEV'; return ;;
  esac

  file_lower="$(printf '%s' "$file" | tr '[:upper:]' '[:lower:]')"
  case "$file_lower" in
    */prod/*|*/production/*|*-prod/*) printf '%s' 'PROD'; return ;;
    */shadow/*|*-shadow/*)            printf '%s' 'SHADOW'; return ;;
    */uat/*|*-uat/*)                  printf '%s' 'UAT'; return ;;
    */stage/*|*/staging/*|*-stage/*|*-staging/*) printf '%s' 'STAGE'; return ;;
    */qa/*|*-qa/*)                    printf '%s' 'QA'; return ;;
    */test/*|*/tst/*|*-test/*|*-tst/*) printf '%s' 'TEST'; return ;;
    */dev/*|*/development/*|*-dev/*|*-development/*) printf '%s' 'DEV'; return ;;
  esac

  printf '%s' 'UNKNOWN'
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

def clean(value):
    return str(value).replace('\t', ' ').replace('\n', ' ')

def unique(values):
    result = []
    seen = set()
    for value in values:
        value = clean(value)
        if value and value not in seen:
            seen.add(value)
            result.append(value)
    return result

for doc in docs:
    if not isinstance(doc, dict) or doc.get('kind') != 'VirtualService':
        continue

    meta = doc.get('metadata') or {}
    spec = doc.get('spec') or {}
    manifest_namespace = meta.get('namespace') or 'UNKNOWN'
    name = meta.get('name') or 'unknown'

    raw_gateways = spec.get('gateways') or []
    if not isinstance(raw_gateways, list):
        raw_gateways = [raw_gateways]
    raw_gateways = unique(raw_gateways)
    mesh_routing = 'Yes' if 'mesh' in raw_gateways else 'No'
    external_gateways = [g for g in raw_gateways if g != 'mesh']
    gateway_text = ','.join(external_gateways) if external_gateways else '-'

    destination_ports = []
    for http in spec.get('http') or []:
        if not isinstance(http, dict):
            continue
        for route in http.get('route') or []:
            if not isinstance(route, dict):
                continue
            destination = route.get('destination') or {}
            port = destination.get('port') or {}
            if isinstance(port, dict) and port.get('number') is not None:
                destination_ports.append(port.get('number'))

    port_text = ','.join(unique(destination_ports)) if destination_ports else '-'

    hosts = spec.get('hosts') or []
    if not isinstance(hosts, list):
        hosts = [hosts]

    for host in hosts:
        if host is None:
            continue
        values = [manifest_namespace, name, gateway_text, mesh_routing, clean(host), port_text]
        print('\t'.join(clean(v) for v in values))
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
    if pattern == '*' or pattern == value:
        return True
    if '/' in pattern:
        pattern = pattern.split('/', 1)[1]
    return pattern == '*' or pattern == value or (pattern.startswith('*.') and fnmatch.fnmatch(value, pattern))

for current, dirs, files in os.walk(root):
    dirs[:] = [d for d in dirs if d not in exclude_dirs]
    for name in files:
        if not name.endswith(('.yaml', '.yml')):
            continue
        path = os.path.join(current, name)
        try:
            with open(path, 'r', encoding='utf-8') as fh:
                for doc in yaml.safe_load_all(fh):
                    if not isinstance(doc, dict) or doc.get('kind') != 'Gateway':
                        continue
                    meta = doc.get('metadata') or {}
                    if meta.get('name') != gateway_name:
                        continue
                    explicit_ns = meta.get('namespace')
                    if gateway_ns and explicit_ns and explicit_ns != gateway_ns:
                        continue
                    for server in (doc.get('spec') or {}).get('servers') or []:
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
  REMOTE="$(get_git_remote "$FILE")"
  RELATIVE_FILE="${FILE#${SEARCH_ROOT}/}"
  CONFIG_NAMESPACE="$(get_config_namespace "$FILE" 2>/dev/null || true)"

  while IFS=$'\t' read -r MANIFEST_NAMESPACE VS_NAME GATEWAY MESH_ROUTING HOST DEST_PORT; do
    [[ -n "$HOST" ]] || continue

    if [[ -n "$CONFIG_NAMESPACE" ]]; then
      NAMESPACE="$CONFIG_NAMESPACE"
    else
      NAMESPACE="${MANIFEST_NAMESPACE:-UNKNOWN}"
    fi

    VS_NAME="${VS_NAME:-unknown}"
    GATEWAY="${GATEWAY:--}"
    MESH_ROUTING="${MESH_ROUTING:-No}"
    DEST_PORT="${DEST_PORT:--}"

    if ! is_external_host "$HOST"; then
      ((INTERNAL_HOSTS_EXCLUDED+=1))
      continue
    fi

    ENVIRONMENT="$(detect_environment "$RELATIVE_FILE" "$NAMESPACE" "$HOST")"
    HTTPS_URL="https://${HOST}"
    ISSUE=""

    if [[ "$HOST" == \*.* ]]; then
      ISSUE="Wildcard hostname"
    elif ! valid_hostname "$HOST"; then
      ISSUE="Hostname does not match expected FQDN syntax"
    fi

    if [[ -z "$ISSUE" && "$GATEWAY" == "-" && "$MESH_ROUTING" != "Yes" ]]; then
      ISSUE="VirtualService has no explicit gateway"
    fi

    if [[ -z "$ISSUE" && "$GATEWAY" != "-" ]]; then
      IFS=',' read -ra GW_ARRAY <<< "$GATEWAY"
      for GW in "${GW_ARRAY[@]}"; do
        GW="${GW#${GW%%[![:space:]]*}}"
        GW="${GW%${GW##*[![:space:]]}}"
        set +e
        gateway_accepts_host "$FILE" "$GW" "$HOST"
        rc=$?
        set -e
        if [[ $rc -eq 1 ]]; then
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
      csv_escape "$HTTPS_URL"; printf ','
      csv_escape "$DEST_PORT"; printf ','
      csv_escape "$REMOTE"; printf ','
      csv_escape "$RELATIVE_FILE"; printf '\n'
    } >> "$CSV_FILE"

    cat >> "$TEXT_FILE" <<EOF2
Environment      : ${ENVIRONMENT}
Project          : ${PROJECT}
Namespace        : ${NAMESPACE}
VirtualService   : ${VS_NAME}
HTTPS URL        : ${HTTPS_URL}
Destination Port : ${DEST_PORT}
Git Remote       : ${REMOTE}
Manifest         : ${RELATIVE_FILE}
------------------------------------------------------------
EOF2

    if [[ -n "$ISSUE" ]]; then
      {
        csv_escape "$ENVIRONMENT"; printf ','
        csv_escape "$PROJECT"; printf ','
        csv_escape "$NAMESPACE"; printf ','
        csv_escape "$VS_NAME"; printf ','
        csv_escape "$HTTPS_URL"; printf ','
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
        url = (row.get('HTTPS_URL') or '').strip()
        if url:
            counts[url] += 1

with open(dup_file, 'w', encoding='utf-8') as out:
    for url in sorted(k for k, v in counts.items() if v > 1):
        out.write(f'{url}\t{counts[url]}\n')
PY

read -r TOTAL_RECORDS TOTAL_ISSUES TOTAL_URLS TOTAL_PROJECTS < <(
  python3 - "$CSV_FILE" "$ISSUES_FILE" <<'PY'
import csv
import sys

csv_file, issues_file = sys.argv[1:3]
with open(csv_file, newline='', encoding='utf-8') as fh:
    rows = list(csv.DictReader(fh))
with open(issues_file, newline='', encoding='utf-8') as fh:
    issues = list(csv.DictReader(fh))
urls = {r.get('HTTPS_URL', '') for r in rows if r.get('HTTPS_URL')}
projects = {r.get('Project', '') for r in rows if r.get('Project')}
print(len(rows), len(issues), len(urls), len(projects))
PY
)
DUP_COUNT="$(wc -l < "$DUP_FILE" | tr -d ' ')"

cat >> "$TEXT_FILE" <<EOF2

SUMMARY
-------
YAML Files Scanned            : ${FILES_SCANNED}
Projects with URL Records     : ${TOTAL_PROJECTS}
Unique External HTTPS URLs    : ${TOTAL_URLS}
VirtualService/URL Mappings   : ${TOTAL_RECORDS}
Validation Issues             : ${TOTAL_ISSUES}
Duplicate URLs                : ${DUP_COUNT}
Internal Hosts Excluded       : ${INTERNAL_HOSTS_EXCLUDED}
EOF2

python3 - "$CSV_FILE" "$ISSUES_FILE" "$DUP_FILE" "$CONFLUENCE_FILE" "$SEARCH_ROOT" "$FILES_SCANNED" "$TOTAL_PROJECTS" "$TOTAL_URLS" "$TOTAL_RECORDS" "$TOTAL_ISSUES" "$DUP_COUNT" "$INTERNAL_HOSTS_EXCLUDED" <<'PY'
import csv
import datetime
import sys

(csv_file, issues_file, dup_file, output_file, search_root, files_scanned,
 total_projects, total_urls, total_records, total_issues, duplicate_count,
 internal_excluded) = sys.argv[1:]

with open(csv_file, newline='', encoding='utf-8') as fh:
    rows = list(csv.DictReader(fh))
with open(issues_file, newline='', encoding='utf-8') as fh:
    issues = list(csv.DictReader(fh))

duplicates = []
with open(dup_file, encoding='utf-8') as fh:
    for line in fh:
        line = line.rstrip('\n')
        if line:
            parts = line.split('\t', 1)
            duplicates.append((parts[0], parts[1] if len(parts) > 1 else '2'))

def md(value):
    return str(value or '-').replace('|', '\\|').replace('\n', ' ')

def code(value):
    return f'`{md(value)}`'

rows.sort(key=lambda r: (r.get('Environment',''), r.get('Project',''), r.get('HTTPS_URL','')))
issues.sort(key=lambda r: (r.get('Environment',''), r.get('Project',''), r.get('HTTPS_URL','')))
now = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')

with open(output_file, 'w', encoding='utf-8') as out:
    out.write('# EKS Istio VirtualService – External FQDN Inventory\n\n')

    out.write('## Overview\n\n')
    out.write('This page provides an inventory of external HTTPS URLs configured from Istio VirtualService hosts across application Git repositories.\n\n')
    out.write('Kubernetes internal hosts ending in `.svc.cluster.local` are excluded. Namespace values are sourced from each project\'s `config.json` when available.\n\n')
    out.write(f'**Last Generated:** {now}  \n')
    out.write(f'**Source:** Git repositories under `{search_root}`  \n')
    out.write('**Resource:** Istio VirtualService  \n')
    out.write('**Namespace Source:** `config.json` first, `metadata.namespace` fallback  \n')
    out.write('**Internal Hosts:** Excluded  \n')
    out.write('**URL Scheme:** HTTPS\n\n')
    out.write('---\n\n')

    out.write('## Summary\n\n')
    out.write('| Metric | Count |\n|---|---:|\n')
    out.write(f'| Projects Scanned | {total_projects} |\n')
    out.write(f'| YAML Files Scanned | {files_scanned} |\n')
    out.write(f'| VirtualService/URL Mappings | {total_records} |\n')
    out.write(f'| Unique External HTTPS URLs | {total_urls} |\n')
    out.write(f'| Validation Issues | {total_issues} |\n')
    out.write(f'| Duplicate URLs | {duplicate_count} |\n')
    out.write(f'| Internal Hosts Excluded | {internal_excluded} |\n\n')
    out.write('---\n\n')

    out.write('## External FQDN Inventory\n\n')
    out.write('| Environment | Project | Namespace | VirtualService | HTTPS URL | Destination Port | Git Remote | Manifest |\n')
    out.write('|---|---|---|---|---|---:|---|---|\n')
    if rows:
        for r in rows:
            out.write(f"| {md(r.get('Environment'))} | {md(r.get('Project'))} | {md(r.get('Namespace'))} | {md(r.get('VirtualService'))} | {code(r.get('HTTPS_URL'))} | {md(r.get('DestinationPort'))} | {md(r.get('GitRemote'))} | {code(r.get('Manifest'))} |\n")
    else:
        out.write('| - | - | - | - | - | - | - | No external URLs found |\n')
    out.write('\n---\n\n')

    out.write('## Validation Issues\n\n')
    out.write('| Environment | Project | VirtualService | HTTPS URL | Issue |\n')
    out.write('|---|---|---|---|---|\n')
    if issues:
        for i in issues:
            out.write(f"| {md(i.get('Environment'))} | {md(i.get('Project'))} | {md(i.get('VirtualService'))} | {code(i.get('HTTPS_URL'))} | {md(i.get('Issue'))} |\n")
    else:
        out.write('| - | - | - | - | No validation issues found |\n')
    out.write('\n---\n\n')

    out.write('## Duplicate URLs\n\n')
    out.write('| HTTPS URL | Occurrences |\n|---|---:|\n')
    if duplicates:
        for url, count in duplicates:
            out.write(f'| {code(url)} | {md(count)} |\n')
    else:
        out.write('| - | 0 |\n')
    out.write('\n---\n\n')

    out.write('## Validation Rules\n\n')
    out.write('- Excludes `*.svc.cluster.local`.\n')
    out.write('- Adds the `https://` prefix to each reported external host.\n')
    out.write('- Reads namespace from the project `config.json` first and falls back to VirtualService `metadata.namespace`.\n')
    out.write('- Determines environment primarily from the namespace suffix, then FQDN, then manifest path.\n')
    out.write('- Detects malformed and wildcard hostnames.\n')
    out.write('- Uses Gateway data internally for static validation but does not display Gateway details in the primary report.\n')
    out.write('- Detects duplicate external HTTPS URLs.\n\n')
    out.write('---\n\n')

    out.write('## Important Notes\n\n')
    out.write('The script searches for the nearest `config.json` from the VirtualService manifest up to the Git repository root. If none is found there, it searches the repository for a `config.json`.\n\n')
    out.write('The JSON parser first checks common namespace locations and then recursively searches for a scalar key named `namespace`.\n\n')
    out.write('The `https://` prefix is added for reporting convenience. This static report does not verify that TLS is configured or that the URL is reachable.\n\n')
    out.write('This report analyzes Git manifests only and does not verify live EKS resources, DNS resolution, certificates, load balancers, or application availability.\n')
PY

echo
echo "============================================================"
if [[ "$DRY_RUN" == true ]]; then
  echo "VirtualService FQDN inventory dry-run completed"
else
  echo "VirtualService FQDN inventory completed"
fi
echo "============================================================"
echo "Search root:              $SEARCH_ROOT"
echo "YAML files scanned:       $FILES_SCANNED"
echo "Projects:                 $TOTAL_PROJECTS"
echo "Unique external URLs:     $TOTAL_URLS"
echo "Validation issues:        $TOTAL_ISSUES"
echo "Duplicate URLs:           $DUP_COUNT"
echo "Internal hosts excluded:  $INTERNAL_HOSTS_EXCLUDED"

if [[ "$DRY_RUN" == true ]]; then
  echo
  echo "DRY-RUN: No report files were written to:"
  echo "  $REQUESTED_OUTPUT_DIR"
  echo
  echo "==================== DRY-RUN REPORT PREVIEW ===================="
  cat "$TEXT_FILE"
  echo "================== END DRY-RUN REPORT PREVIEW =================="
else
  echo
  echo "CSV report:               $CSV_FILE"
  echo "Text report:              $TEXT_FILE"
  echo "Issues report:            $ISSUES_FILE"
  echo "Duplicate URL list:       $DUP_FILE"
  echo "Confluence report:        $CONFLUENCE_FILE"
fi
