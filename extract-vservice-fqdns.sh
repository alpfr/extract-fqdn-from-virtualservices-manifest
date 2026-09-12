#!/usr/bin/env bash
set -euo pipefail

SEARCH_ROOT="${1:-}"
OUTPUT_DIR="${OUTPUT_DIR:-./eks-virtualservice-report}"
CSV_FILE="${OUTPUT_DIR}/virtualservice_fqdns.csv"
TEXT_FILE="${OUTPUT_DIR}/virtualservice_fqdns.txt"
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

printf '"Environment","Project","Namespace","VirtualService","Gateway","MeshRouting","FQDN","DestinationService","DestinationPort","URIPrefix","Owner","Status","GitBranch","GitRemote","Manifest"\n' > "$CSV_FILE"
printf '"Environment","Project","Namespace","VirtualService","FQDN","Issue","Manifest"\n' > "$ISSUES_FILE"

cat > "$TEXT_FILE" <<EOF2
EKS ISTIO VIRTUALSERVICE - EXTERNAL FQDN & ROUTING INVENTORY
===========================================================
Generated: $(date '+%Y-%m-%d %H:%M:%S')
Search Root: ${SEARCH_ROOT}

Internal Kubernetes hosts ending in .svc.cluster.local are excluded.
The special Istio gateway value "mesh" is reported as Mesh Routing = Yes and skipped during Gateway resource validation.

FQDN INVENTORY
--------------
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
    *shadow*) printf '%s' 'SHADOW' ;;
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
    labels = meta.get('labels') or {}

    namespace = meta.get('namespace') or 'UNKNOWN'
    name = meta.get('name') or 'unknown'
    owner = (
        labels.get('app.kubernetes.io/owner')
        or labels.get('owner')
        or labels.get('team')
        or '-'
    )

    raw_gateways = spec.get('gateways') or []
    if not isinstance(raw_gateways, list):
        raw_gateways = [raw_gateways]
    raw_gateways = unique(raw_gateways)

    mesh_routing = 'Yes' if 'mesh' in raw_gateways else 'No'
    external_gateways = [g for g in raw_gateways if g != 'mesh']
    gateway_text = ','.join(external_gateways) if external_gateways else '-'

    destination_hosts = []
    destination_ports = []
    uri_prefixes = []

    for http in spec.get('http') or []:
        if not isinstance(http, dict):
            continue

        for match in http.get('match') or []:
            if not isinstance(match, dict):
                continue
            uri = match.get('uri') or {}
            if isinstance(uri, dict) and uri.get('prefix') is not None:
                uri_prefixes.append(uri.get('prefix'))

        for route in http.get('route') or []:
            if not isinstance(route, dict):
                continue
            destination = route.get('destination') or {}
            if not isinstance(destination, dict):
                continue
            if destination.get('host') is not None:
                destination_hosts.append(destination.get('host'))
            port = destination.get('port') or {}
            if isinstance(port, dict) and port.get('number') is not None:
                destination_ports.append(port.get('number'))

    destination_hosts = unique(destination_hosts)
    destination_ports = unique(destination_ports)
    uri_prefixes = unique(uri_prefixes)

    destination_text = ','.join(destination_hosts) if destination_hosts else '-'
    port_text = ','.join(destination_ports) if destination_ports else '-'
    prefix_text = ','.join(uri_prefixes) if uri_prefixes else '-'

    hosts = spec.get('hosts') or []
    if not isinstance(hosts, list):
        hosts = [hosts]

    for host in hosts:
        if host is None:
            continue
        values = [
            namespace,
            name,
            owner,
            gateway_text,
            mesh_routing,
            clean(host),
            destination_text,
            port_text,
            prefix_text,
        ]
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
                    explicit_ns = meta.get('namespace')
                    if gateway_ns and explicit_ns and explicit_ns != gateway_ns:
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

  while IFS=$'\t' read -r NAMESPACE VS_NAME OWNER GATEWAY MESH_ROUTING HOST DEST_SERVICE DEST_PORT URI_PREFIX; do
    [[ -n "$HOST" ]] || continue

    NAMESPACE="${NAMESPACE:-UNKNOWN}"
    VS_NAME="${VS_NAME:-unknown}"
    OWNER="${OWNER:--}"
    GATEWAY="${GATEWAY:--}"
    MESH_ROUTING="${MESH_ROUTING:-No}"
    DEST_SERVICE="${DEST_SERVICE:--}"
    DEST_PORT="${DEST_PORT:--}"
    URI_PREFIX="${URI_PREFIX:--}"

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

    if [[ "$GATEWAY" == "-" ]]; then
      if [[ "$MESH_ROUTING" != "Yes" ]]; then
        STATUS="MISSING_GATEWAY"
        ISSUE="VirtualService has no explicit gateway"
      fi
    else
      IFS=',' read -ra GW_ARRAY <<< "$GATEWAY"
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
      csv_escape "$GATEWAY"; printf ','
      csv_escape "$MESH_ROUTING"; printf ','
      csv_escape "$HOST"; printf ','
      csv_escape "$DEST_SERVICE"; printf ','
      csv_escape "$DEST_PORT"; printf ','
      csv_escape "$URI_PREFIX"; printf ','
      csv_escape "$OWNER"; printf ','
      csv_escape "$STATUS"; printf ','
      csv_escape "$BRANCH"; printf ','
      csv_escape "$REMOTE"; printf ','
      csv_escape "$RELATIVE_FILE"; printf '\n'
    } >> "$CSV_FILE"

    cat >> "$TEXT_FILE" <<EOF2
Environment         : ${ENVIRONMENT}
Project             : ${PROJECT}
Namespace           : ${NAMESPACE}
VirtualService      : ${VS_NAME}
Gateway             : ${GATEWAY}
Mesh Routing        : ${MESH_ROUTING}
FQDN                : ${HOST}
Destination Service : ${DEST_SERVICE}
Destination Port    : ${DEST_PORT}
URI Prefix          : ${URI_PREFIX}
Owner               : ${OWNER}
Status              : ${STATUS}
Git Branch          : ${BRANCH}
Git Remote          : ${REMOTE}
Manifest            : ${RELATIVE_FILE}
------------------------------------------------------------
EOF2

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
        out.write(f'{fqdn}\t{counts[fqdn]}\n')
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

cat >> "$TEXT_FILE" <<EOF2

SUMMARY
-------
YAML Files Scanned            : ${FILES_SCANNED}
Projects with FQDN Records    : ${TOTAL_PROJECTS}
Unique External FQDNs         : ${TOTAL_FQDNS}
VirtualService/FQDN Mappings  : ${TOTAL_RECORDS}
Validation Issues             : ${TOTAL_ISSUES}
Duplicate FQDNs               : ${DUP_COUNT}
Internal Hosts Excluded       : ${INTERNAL_HOSTS_EXCLUDED}
EOF2

python3 - "$CSV_FILE" "$ISSUES_FILE" "$DUP_FILE" "$CONFLUENCE_FILE" "$SEARCH_ROOT" "$FILES_SCANNED" "$TOTAL_PROJECTS" "$TOTAL_FQDNS" "$TOTAL_RECORDS" "$TOTAL_ISSUES" "$DUP_COUNT" "$INTERNAL_HOSTS_EXCLUDED" <<'PY'
import csv
import datetime
import sys

(
    csv_file,
    issues_file,
    dup_file,
    output_file,
    search_root,
    files_scanned,
    total_projects,
    total_fqdns,
    total_records,
    total_issues,
    duplicate_count,
    internal_excluded,
) = sys.argv[1:]

with open(csv_file, newline='', encoding='utf-8') as fh:
    rows = list(csv.DictReader(fh))
with open(issues_file, newline='', encoding='utf-8') as fh:
    issues = list(csv.DictReader(fh))

duplicates = []
with open(dup_file, encoding='utf-8') as fh:
    for line in fh:
        line = line.rstrip('\n')
        if not line:
            continue
        parts = line.split('\t', 1)
        duplicates.append((parts[0], parts[1] if len(parts) > 1 else '2'))

def md(value):
    value = str(value or '-')
    return value.replace('|', '\\|').replace('\n', ' ')

def code(value):
    return f'`{md(value)}`'

rows.sort(key=lambda r: (
    r.get('Environment', ''),
    r.get('Project', ''),
    r.get('FQDN', ''),
    r.get('VirtualService', ''),
))
issues.sort(key=lambda r: (
    r.get('Environment', ''),
    r.get('Project', ''),
    r.get('FQDN', ''),
))

now = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')

with open(output_file, 'w', encoding='utf-8') as out:
    out.write('# EKS Istio VirtualService – External FQDN & Routing Inventory\n\n')

    out.write('## Overview\n\n')
    out.write('This page provides an inventory of external FQDNs configured in Istio VirtualService manifests across application Git repositories.\n\n')
    out.write('The inventory is generated from Kubernetes/Istio manifests stored in the Git/VS Code workspace. Kubernetes internal hosts ending in `.svc.cluster.local` are excluded.\n\n')
    out.write(f'**Last Generated:** {now}  \n')
    out.write(f'**Source:** Git repositories under `{search_root}`  \n')
    out.write('**Resource:** Istio VirtualService  \n')
    out.write('**Internal Hosts:** Excluded  \n')
    out.write('**Generation Method:** Automated manifest scan\n\n')
    out.write('---\n\n')

    out.write('## Summary\n\n')
    out.write('| Metric | Count |\n')
    out.write('|---|---:|\n')
    out.write(f'| Projects Scanned | {total_projects} |\n')
    out.write(f'| YAML Files Scanned | {files_scanned} |\n')
    out.write(f'| VirtualService/FQDN Mappings | {total_records} |\n')
    out.write(f'| Unique External FQDNs | {total_fqdns} |\n')
    out.write(f'| Validation Issues | {total_issues} |\n')
    out.write(f'| Duplicate FQDNs | {duplicate_count} |\n')
    out.write(f'| Internal Hosts Excluded | {internal_excluded} |\n\n')
    out.write('---\n\n')

    out.write('## External FQDN & Routing Inventory\n\n')
    out.write('| Environment | Project | Namespace | VirtualService | External FQDN | Gateway | Mesh Routing | Destination Service | Port | URI | Status |\n')
    out.write('|---|---|---|---|---|---|---|---|---:|---|---|\n')
    if rows:
        for row in rows:
            out.write(
                '| {env} | {project} | {namespace} | {vs} | {fqdn} | {gateway} | {mesh} | {dest} | {port} | {uri} | {status} |\n'.format(
                    env=md(row.get('Environment')),
                    project=md(row.get('Project')),
                    namespace=md(row.get('Namespace')),
                    vs=md(row.get('VirtualService')),
                    fqdn=code(row.get('FQDN')),
                    gateway=code(row.get('Gateway')),
                    mesh=md(row.get('MeshRouting')),
                    dest=md(row.get('DestinationService')),
                    port=md(row.get('DestinationPort')),
                    uri=code(row.get('URIPrefix')),
                    status=md(row.get('Status')),
                )
            )
    else:
        out.write('| - | - | - | - | - | - | - | - | - | - | No external FQDNs found |\n')
    out.write('\n---\n\n')

    out.write('## Validation Issues\n\n')
    out.write('| Environment | Project | VirtualService | FQDN | Issue |\n')
    out.write('|---|---|---|---|---|\n')
    if issues:
        for issue in issues:
            out.write(
                f"| {md(issue.get('Environment'))} | {md(issue.get('Project'))} | {md(issue.get('VirtualService'))} | {code(issue.get('FQDN'))} | {md(issue.get('Issue'))} |\n"
            )
    else:
        out.write('| - | - | - | - | No validation issues found |\n')
    out.write('\n---\n\n')

    out.write('## Duplicate FQDNs\n\n')
    out.write('| FQDN | Occurrences |\n')
    out.write('|---|---:|\n')
    if duplicates:
        for fqdn, count in duplicates:
            out.write(f'| {code(fqdn)} | {md(count)} |\n')
    else:
        out.write('| - | 0 |\n')
    out.write('\n---\n\n')

    out.write('## Validation Rules\n\n')
    out.write('- Excludes `*.svc.cluster.local`.\n')
    out.write('- Treats `mesh` as an Istio reserved gateway value rather than a Kubernetes Gateway resource.\n')
    out.write('- Reports `mesh` separately as **Mesh Routing**.\n')
    out.write('- Validates non-mesh Gateway references against Gateway manifests in the same Git repository.\n')
    out.write('- Validates external FQDN syntax.\n')
    out.write('- Detects wildcard FQDNs.\n')
    out.write('- Detects duplicate external FQDNs.\n')
    out.write('- Reports a missing manifest namespace as `UNKNOWN`.\n')
    out.write('- Recognizes `SHADOW` when `shadow` appears in the namespace, manifest path, or FQDN.\n')
    out.write('- Captures HTTP route destination service and port.\n')
    out.write('- Captures HTTP URI prefix.\n\n')
    out.write('---\n\n')

    out.write('## Status Definitions\n\n')
    out.write('| Status | Description |\n')
    out.write('|---|---|\n')
    out.write('| `VALID` | Configuration passed static validation |\n')
    out.write('| `WILDCARD` | VirtualService uses a wildcard hostname |\n')
    out.write('| `NONSTANDARD` | Host does not match expected FQDN syntax |\n')
    out.write('| `MISSING_GATEWAY` | No explicit Gateway or mesh routing is configured |\n')
    out.write('| `GATEWAY_HOST_MISMATCH` | FQDN was not found on the referenced non-mesh Gateway |\n\n')
    out.write('---\n\n')

    out.write('## Important Notes\n\n')
    out.write('`mesh` is an Istio reserved gateway value and is not a Kubernetes Gateway resource. It is therefore shown separately from the external Gateway in this report.\n\n')
    out.write('A namespace of `UNKNOWN` means `metadata.namespace` was not explicitly defined in the manifest. The namespace may be supplied by Kustomize, Helm, Argo CD, or the deployment pipeline.\n\n')
    out.write('Namespaces, manifest paths, or FQDNs containing `shadow` are classified under the `SHADOW` environment.\n\n')
    out.write('This report performs static Git manifest analysis and does not verify live EKS resources, DNS resolution, TLS certificates, load balancers, destination Services, or application availability.\n')
PY

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
echo "Text report:              $TEXT_FILE"
echo "Issues report:            $ISSUES_FILE"
echo "Duplicate FQDN list:      $DUP_FILE"
echo "Confluence report:        $CONFLUENCE_FILE"
