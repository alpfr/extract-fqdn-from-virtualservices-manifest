# Extract FQDNs from Istio VirtualService Manifests

Recursively scans a local Git/VS Code workspace for Istio `VirtualService` YAML manifests and builds an external FQDN inventory for Confluence and CSV reporting.

## No `yq` requirement

This version does **not** use `yq`.

YAML parsing is performed with Python 3 and the `PyYAML` module. This is safer than parsing Kubernetes YAML with `grep`, `sed`, or `awk`, especially for multi-document manifests, lists, comments, and different indentation styles.

## What it does

- Searches all `*.yaml` and `*.yml` files below a workspace root.
- Handles multi-document YAML.
- Extracts `spec.hosts[]` from Istio `VirtualService` resources.
- Excludes Kubernetes internal hosts ending in `.svc.cluster.local`.
- Detects environment from path, namespace, and hostname (`DEV`, `TEST`, `QA`, `UAT`, `STAGE`, `PROD`).
- Captures project/repository, namespace, VirtualService, gateway, owner/team label, Git branch, Git remote URL, and manifest path.
- Flags wildcard and malformed hostnames.
- Flags VirtualServices without explicit gateways.
- Performs static VirtualService-to-Gateway host validation against Gateway manifests in the same Git repository.
- Produces a duplicate FQDN list.
- Generates a Markdown page that can be pasted into Confluence.

## Requirements

- Bash 4+
- Git
- Python 3
- Python `PyYAML` module

Verify:

```bash
git --version
python3 --version
python3 -c 'import yaml; print(yaml.__version__)'
```

If PyYAML is not installed and your environment permits user-local Python packages:

```bash
python3 -m pip install --user pyyaml
```

If package installation is restricted, ask your platform team to provide the `python3-pyyaml` OS package or an approved Python environment containing PyYAML.

## Usage

```bash
chmod +x extract-vservice-fqdns.sh
./extract-vservice-fqdns.sh /path/to/git/workspace
```

Example:

```bash
./extract-vservice-fqdns.sh /opt/apps/git
```

Custom output directory:

```bash
OUTPUT_DIR=/tmp/fqdn-report ./extract-vservice-fqdns.sh /opt/apps/git
```

## Output

The script creates:

```text
eks-virtualservice-report/
├── virtualservice_fqdns.csv
├── virtualservice_fqdns_confluence.md
├── virtualservice_issues.csv
└── duplicate_fqdns.txt
```

### Main inventory columns

| Column | Purpose |
|---|---|
| Environment | Detected DEV/TEST/QA/UAT/STAGE/PROD environment |
| Project | Git repository/project name |
| Namespace | Kubernetes namespace |
| VirtualService | Istio VirtualService resource name |
| Gateway | Referenced Istio Gateway(s) |
| FQDN | External/application hostname |
| Owner | Owner/team label when available |
| Status | Static validation result |
| GitBranch | Current local repository branch |
| GitRemote | Git origin URL |
| Manifest | Manifest path relative to the workspace root |

## Sample VirtualService

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: elasticsearch-vservice
  namespace: elasticsearch
spec:
  gateways:
    - istio-system/public-gateway
  hosts:
    - elasticsearch.dev.mesh.abc.mod.com
    - elasticsearch.svc.cluster.local
```

Only the external/application hostname is reported:

```text
elasticsearch.dev.mesh.abc.mod.com
```

The internal hostname is excluded:

```text
elasticsearch.svc.cluster.local
```

## Status values

| Status | Meaning |
|---|---|
| `VALID` | External FQDN passed basic static checks |
| `WILDCARD` | Host is a wildcard FQDN |
| `NONSTANDARD` | Host does not match basic FQDN syntax |
| `MISSING_GATEWAY` | VirtualService has no explicit gateway |
| `GATEWAY_HOST_MISMATCH` | Host was not found on the referenced Gateway in repository manifests |

## Gateway validation

When a VirtualService references an explicit Gateway, the script searches YAML manifests in the same Git repository for that Gateway. It checks whether the FQDN is accepted by `Gateway.spec.servers[].hosts`, including exact hosts, `*`, wildcard domains such as `*.example.com`, and namespace-qualified Istio host patterns.

This is a static source-control validation. It does not prove that the deployed EKS/Istio configuration, DNS, load balancer, certificate, or backend service is healthy.

## Environment detection

Environment is inferred from the manifest path, namespace, and FQDN. Recognized values are:

```text
PROD
UAT
STAGE
QA
TEST
DEV
UNKNOWN
```

Treat this as an inventory convenience rather than an authoritative environment classification. For stronger governance, use a standardized Kubernetes label or repository metadata field and extend the script to prefer it.

## Confluence sample

| Environment | Project | Namespace | VirtualService | Gateway | FQDN | Owner | Status | Manifest |
|---|---|---|---|---|---|---|---|---|
| DEV | elasticsearch-project | elasticsearch | elasticsearch-vservice | istio-system/public-gateway | `elasticsearch.dev.mesh.abc.mod.com` | search-team | VALID | `elasticsearch-project/k8s/dev/virtualservice.yaml` |

## Exclusions

Hosts ending in `.svc.cluster.local` are intentionally excluded from the Confluence and primary CSV inventory because the report is focused on application/external FQDNs.

Example excluded host:

```text
elasticsearch.svc.cluster.local
```

## Recommended workflow

1. Open or identify the parent directory containing the Git repositories used by VS Code.
2. Run the script against that workspace root.
3. Review `virtualservice_fqdns.csv` for the complete external FQDN inventory.
4. Review `virtualservice_issues.csv` for static configuration findings.
5. Review `duplicate_fqdns.txt` for FQDNs appearing more than once.
6. Copy or import `virtualservice_fqdns_confluence.md` into the appropriate Confluence page.
7. Investigate validation findings before treating the inventory as authoritative.

## Recommended CI usage

Run the script in CI and retain the generated files as build artifacts. Review `virtualservice_issues.csv` and `duplicate_fqdns.txt` during configuration changes.

For stricter governance, a later version can fail CI only for selected conditions, such as malformed production FQDNs, duplicate production FQDNs, or Gateway host mismatches.

## Security and operational notes

- The script reads local manifest files; it does not require Kubernetes/EKS cluster access.
- It does not query Kubernetes Secrets or output secret values.
- Do not store TLS private keys or other credentials in generated reports.
- DNS resolution and TLS certificate validation are outside the current static-analysis scope.
- Generated reports are ignored by Git by default so environment-specific inventories are not accidentally committed.
