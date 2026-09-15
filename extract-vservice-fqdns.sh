#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=false
SEARCH_ROOT=""
REQUESTED_OUTPUT_DIR="${OUTPUT_DIR:-./eks-virtualservice-report}"

usage() {
  cat <<EOF
Usage: $0 [--dry-run|-n] /path/to/git/workspace

Options:
  -n, --dry-run   Scan without persisting report files
  -h, --help      Show this help

Requirements: bash 4+, git, python, PyYAML
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
    *) [[ -z "$SEARCH_ROOT" ]] || { echo "ERROR: Only one workspace path may be specified." >&2; exit 1; }; SEARCH_ROOT="$1"; shift ;;
  esac
done

[[ -n "$SEARCH_ROOT" && -d "$SEARCH_ROOT" ]] || { usage; exit 1; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git is required." >&2; exit 1; }
command -v python >/dev/null 2>&1 || { echo "ERROR: python is required." >&2; exit 1; }
python -c 'import yaml' >/dev/null 2>&1 || {
  echo "ERROR: Python PyYAML module is required." >&2
  echo "Install with: python -m pip install --user pyyaml" >&2
  exit 1
}

SEARCH_ROOT="$(cd "$SEARCH_ROOT" && pwd)"
if [[ "$DRY_RUN" == true ]]; then
  OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/eks-vservice-fqdn-dryrun.XXXXXX")"
  trap 'rm -rf "$OUTPUT_DIR"' EXIT INT TERM
else
  OUTPUT_DIR="$REQUESTED_OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR"

CSV_FILE="$OUTPUT_DIR/virtualservice_fqdns.csv"
TEXT_FILE="$OUTPUT_DIR/virtualservice_fqdns.txt"
CONFLUENCE_FILE="$OUTPUT_DIR/virtualservice_fqdns_confluence.md"
ISSUES_FILE="$OUTPUT_DIR/virtualservice_issues.csv"
DUP_FILE="$OUTPUT_DIR/duplicate_fqdns.txt"
printf '"Environment","Project","Namespace","VirtualService","HTTPS_URL","DestinationPort","GitRemote","Manifest"\n' > "$CSV_FILE"
printf '"Environment","Project","Namespace","VirtualService","HTTPS_URL","Issue","Manifest"\n' > "$ISSUES_FILE"

FILES_SCANNED=0
INTERNAL_HOSTS_EXCLUDED=0

get_repo_root() {
  git -C "$(dirname "$1")" rev-parse --show-toplevel 2>/dev/null || true
}

get_project_name() {
  local repo rel
  repo="$(get_repo_root "$1")"
  if [[ -n "$repo" ]]; then basename "$repo"; else rel="${1#${SEARCH_ROOT}/}"; printf '%s\n' "${rel%%/*}"; fi
}

get_git_remote() {
  local repo
  repo="$(get_repo_root "$1")"
  [[ -n "$repo" ]] && git -C "$repo" config --get remote.origin.url 2>/dev/null || printf '%s' '-'
}

extract_namespace_from_config() {
  python - "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f: data=json.load(f)
except Exception: sys.exit(0)

def find(o):
    if isinstance(o, dict):
        for k,v in o.items():
            if str(k).lower() == 'namespace' and isinstance(v,(str,int,float)) and str(v).strip():
                return str(v).strip()
        for v in o.values():
            x=find(v)
            if x: return x
    elif isinstance(o,list):
        for v in o:
            x=find(v)
            if x: return x
    return None
x=find(data)
if x: print(x)
PY
}

get_config_namespace() {
  local file="$1" repo dir cfg
  repo="$(get_repo_root "$file")"
  [[ -n "$repo" ]] || return 0
  dir="$(dirname "$file")"
  while true; do
    if [[ -f "$dir/config.json" ]]; then extract_namespace_from_config "$dir/config.json"; return; fi
    [[ "$dir" == "$repo" || "$dir" == / ]] && break
    dir="$(dirname "$dir")"
  done
  cfg="$(find "$repo" -type d \( -name .git -o -name node_modules -o -name vendor -o -name .terraform -o -name dist -o -name build \) -prune -o -type f -name config.json -print 2>/dev/null | head -n1)"
  [[ -n "$cfg" ]] && extract_namespace_from_config "$cfg"
}

detect_environment() {
  local ns host file
  ns="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  host="$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')"
  file="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$ns" in *-prod|*-production) echo PROD; return;; *-shadow) echo SHADOW; return;; *-uat) echo UAT; return;; *-stage|*-staging) echo STAGE; return;; *-qa) echo QA; return;; *-test|*-tst) echo TEST; return;; *-dev|*-development) echo DEV; return;; esac
  case "$host" in *.prod.*|*.production.*|*-prod.*) echo PROD; return;; *.shadow.*|*-shadow.*) echo SHADOW; return;; *.uat.*|*-uat.*) echo UAT; return;; *.stage.*|*.staging.*|*-stage.*|*-staging.*) echo STAGE; return;; *.qa.*|*-qa.*) echo QA; return;; *.test.*|*.tst.*|*-test.*|*-tst.*) echo TEST; return;; *.dev.*|*.development.*|*-dev.*|*-development.*) echo DEV; return;; esac
  case "$file" in */prod/*|*/production/*) echo PROD;; */shadow/*) echo SHADOW;; */uat/*) echo UAT;; */stage/*|*/staging/*) echo STAGE;; */qa/*) echo QA;; */test/*|*/tst/*) echo TEST;; */dev/*|*/development/*) echo DEV;; *) echo UNKNOWN;; esac
}

extract_virtualservices() {
  python - "$1" <<'PY'
import sys,yaml
try:
    with open(sys.argv[1],encoding='utf-8') as f: docs=list(yaml.safe_load_all(f))
except Exception: sys.exit(0)
def clean(v): return str(v).replace('\t',' ').replace('\n',' ')
def uniq(a): return list(dict.fromkeys(clean(x) for x in a if x is not None))
for d in docs:
    if not isinstance(d,dict) or d.get('kind')!='VirtualService': continue
    m=d.get('metadata') or {}; s=d.get('spec') or {}
    ns=m.get('namespace') or 'UNKNOWN'; name=m.get('name') or 'unknown'
    g=s.get('gateways') or []; g=[g] if not isinstance(g,list) else g
    mesh='Yes' if 'mesh' in g else 'No'; ext=[x for x in uniq(g) if x!='mesh']; gateways=','.join(ext) or '-'
    ports=[]
    for h in s.get('http') or []:
        if not isinstance(h,dict): continue
        for r in h.get('route') or []:
            dest=(r or {}).get('destination') or {}; p=dest.get('port') or {}
            if isinstance(p,dict) and p.get('number') is not None: ports.append(p['number'])
    port=','.join(uniq(ports)) or '-'
    hosts=s.get('hosts') or []; hosts=[hosts] if not isinstance(hosts,list) else hosts
    for host in hosts:
        if host is not None: print('\t'.join(map(clean,[ns,name,gateways,mesh,host,port])))
PY
}

csv_escape() { local s="${1//\"/\"\"}"; printf '"%s"' "$s"; }

cat > "$TEXT_FILE" <<EOF
EKS ISTIO VIRTUALSERVICE - EXTERNAL FQDN INVENTORY
=================================================
Generated: $(date '+%Y-%m-%d %H:%M:%S')
Search Root: $SEARCH_ROOT

FQDN INVENTORY
--------------
EOF

while IFS= read -r -d '' FILE; do
  ((FILES_SCANNED+=1))
  PROJECT="$(get_project_name "$FILE")"; REMOTE="$(get_git_remote "$FILE")"; RELATIVE_FILE="${FILE#${SEARCH_ROOT}/}"
  CONFIG_NAMESPACE="$(get_config_namespace "$FILE" 2>/dev/null || true)"
  while IFS=$'\t' read -r MANIFEST_NAMESPACE VS_NAME GATEWAY MESH HOST DEST_PORT; do
    [[ -n "$HOST" ]] || continue
    if [[ "$HOST" == *.svc.cluster.local ]]; then ((INTERNAL_HOSTS_EXCLUDED+=1)); continue; fi
    NAMESPACE="${CONFIG_NAMESPACE:-${MANIFEST_NAMESPACE:-UNKNOWN}}"
    ENVIRONMENT="$(detect_environment "$RELATIVE_FILE" "$NAMESPACE" "$HOST")"
    HTTPS_URL="https://$HOST"
    ISSUE=""
    [[ "$HOST" == \*.* ]] && ISSUE="Wildcard hostname"
    [[ "$HOST" =~ ^(\*\.)?([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || ISSUE="Hostname does not match expected FQDN syntax"
    { csv_escape "$ENVIRONMENT"; printf ','; csv_escape "$PROJECT"; printf ','; csv_escape "$NAMESPACE"; printf ','; csv_escape "$VS_NAME"; printf ','; csv_escape "$HTTPS_URL"; printf ','; csv_escape "$DEST_PORT"; printf ','; csv_escape "$REMOTE"; printf ','; csv_escape "$RELATIVE_FILE"; printf '\n'; } >> "$CSV_FILE"
    cat >> "$TEXT_FILE" <<EOF
Environment      : $ENVIRONMENT
Project          : $PROJECT
Namespace        : $NAMESPACE
VirtualService   : $VS_NAME
HTTPS URL        : $HTTPS_URL
Destination Port : $DEST_PORT
Git Remote       : $REMOTE
Manifest         : $RELATIVE_FILE
------------------------------------------------------------
EOF
    if [[ -n "$ISSUE" ]]; then
      { csv_escape "$ENVIRONMENT"; printf ','; csv_escape "$PROJECT"; printf ','; csv_escape "$NAMESPACE"; printf ','; csv_escape "$VS_NAME"; printf ','; csv_escape "$HTTPS_URL"; printf ','; csv_escape "$ISSUE"; printf ','; csv_escape "$RELATIVE_FILE"; printf '\n'; } >> "$ISSUES_FILE"
    fi
  done < <(extract_virtualservices "$FILE")
done < <(find "$SEARCH_ROOT" -type d \( -name .git -o -name node_modules -o -name vendor -o -name .terraform -o -name dist -o -name build \) -prune -o -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)

{ head -1 "$CSV_FILE"; tail -n +2 "$CSV_FILE" | sort -u; } > "$CSV_FILE.tmp" && mv "$CSV_FILE.tmp" "$CSV_FILE"
{ head -1 "$ISSUES_FILE"; tail -n +2 "$ISSUES_FILE" | sort -u; } > "$ISSUES_FILE.tmp" && mv "$ISSUES_FILE.tmp" "$ISSUES_FILE"

python - "$CSV_FILE" "$ISSUES_FILE" "$DUP_FILE" "$CONFLUENCE_FILE" <<'PY'
import csv,collections,datetime,sys
csvf,issuesf,dupf,mdf=sys.argv[1:]
with open(csvf,newline='',encoding='utf-8') as f: rows=list(csv.DictReader(f))
with open(issuesf,newline='',encoding='utf-8') as f: issues=list(csv.DictReader(f))
c=collections.Counter(r['HTTPS_URL'] for r in rows if r.get('HTTPS_URL'))
with open(dupf,'w',encoding='utf-8') as f:
    for u,n in sorted(c.items()):
        if n>1: f.write(f'{u}\t{n}\n')
def esc(v): return str(v or '-').replace('|','\\|')
with open(mdf,'w',encoding='utf-8') as f:
    f.write('# EKS Istio VirtualService – External FQDN Inventory\n\n')
    f.write(f'Generated: {datetime.datetime.now():%Y-%m-%d %H:%M:%S}\n\n')
    f.write('| Environment | Project | Namespace | VirtualService | HTTPS URL | Destination Port | Git Remote | Manifest |\n|---|---|---|---|---|---:|---|---|\n')
    for r in sorted(rows,key=lambda x:(x['Environment'],x['Project'],x['HTTPS_URL'])):
        f.write('| '+' | '.join(esc(r.get(k)) for k in ['Environment','Project','Namespace','VirtualService','HTTPS_URL','DestinationPort','GitRemote','Manifest'])+' |\n')
    f.write('\n## Validation Issues\n\n| Environment | Project | VirtualService | HTTPS URL | Issue |\n|---|---|---|---|---|\n')
    for r in issues: f.write('| '+' | '.join(esc(r.get(k)) for k in ['Environment','Project','VirtualService','HTTPS_URL','Issue'])+' |\n')
print(len(rows),len(issues),len(c),sum(1 for n in c.values() if n>1))
PY

read -r TOTAL_RECORDS TOTAL_ISSUES TOTAL_URLS DUP_COUNT < <(python - "$CSV_FILE" "$ISSUES_FILE" <<'PY'
import csv,collections,sys
with open(sys.argv[1],newline='',encoding='utf-8') as f:r=list(csv.DictReader(f))
with open(sys.argv[2],newline='',encoding='utf-8') as f:i=list(csv.DictReader(f))
c=collections.Counter(x['HTTPS_URL'] for x in r if x.get('HTTPS_URL'))
print(len(r),len(i),len(c),sum(1 for n in c.values() if n>1))
PY
)

cat >> "$TEXT_FILE" <<EOF

SUMMARY
-------
YAML Files Scanned          : $FILES_SCANNED
Unique External HTTPS URLs  : $TOTAL_URLS
VirtualService/URL Mappings : $TOTAL_RECORDS
Validation Issues           : $TOTAL_ISSUES
Duplicate URLs              : $DUP_COUNT
Internal Hosts Excluded     : $INTERNAL_HOSTS_EXCLUDED
EOF

echo "VirtualService FQDN inventory completed"
echo "YAML files scanned: $FILES_SCANNED"
echo "Unique external URLs: $TOTAL_URLS"
if [[ "$DRY_RUN" == true ]]; then
  echo "DRY-RUN: No persistent report files were written."
  cat "$TEXT_FILE"
else
  echo "CSV report: $CSV_FILE"
  echo "Text report: $TEXT_FILE"
  echo "Issues report: $ISSUES_FILE"
  echo "Duplicate URL list: $DUP_FILE"
  echo "Confluence report: $CONFLUENCE_FILE"
fi
