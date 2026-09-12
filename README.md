# Extract FQDNs from Istio VirtualService Manifests

Recursively scans a local Git/VS Code workspace for Istio `VirtualService` YAML manifests and builds an external FQDN inventory in CSV, plain-text, and Confluence-ready Markdown formats.

## No `yq` requirement

This version does **not** use `yq`. YAML parsing is performed with Python 3 and `PyYAML`, including support for multi-document Kubernetes YAML.

## What it does

- Searches all `*.yaml` and `*.yml` files below a workspace root.
- Extracts `spec.hosts[]` from Istio `VirtualService` resources.
- Excludes Kubernetes internal hosts ending in `.svc.cluster.local`.
- Detects `DEV`, `TEST`, `QA`, `UAT`, `STAGE`, and `PROD` from path, namespace, and hostname.
- Captures project, namespace, VirtualService, Gateway, owner/team, Git branch, Git remote, and manifest path.
- Flags wildcard and malformed hostnames.
- Flags VirtualServices without an explicit Gateway.
- Performs static VirtualService-to-Gateway hostname validation against Gateway manifests in the same Git repository.
- Detects duplicate FQDNs.
- Generates both a human-readable `.txt` report and a Confluence-ready `.md` page.

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

If permitted:

```bash
python3 -m pip install --user pyyaml
```

If package installation is restricted, use an approved Python environment containing PyYAML or the platform-provided `python3-pyyaml` package.

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

## Generated files

```text
eks-virtualservice-report/
├── virtualservice_fqdns.csv
├── virtualservice_fqdns.txt
├── virtualservice_fqdns_confluence.md
├── virtualservice_issues.csv
└── duplicate_fqdns.txt
```

### `virtualservice_fqdns.txt`

Human-readable text inventory suitable for attachments, email, terminal review, or archival.

Example:

```text
Environment    : DEV
Project        : elasticsearch-project
Namespace      : elasticsearch
VirtualService : elasticsearch-vservice
Gateway        : istio-system/public-gateway
FQDN           : elasticsearch.dev.mesh.abc.mod.com
Owner          : search-team
Status         : VALID
Git Branch     : main
Git Remote     : https://github.com/example/elasticsearch-project.git
Manifest       : elasticsearch-project/k8s/dev/virtualservice.yaml
------------------------------------------------------------
```

The text report ends with summary counts for files scanned, projects, unique external FQDNs, mappings, validation issues, duplicates, and excluded internal hosts.

### `virtualservice_fqdns_confluence.md`

Confluence-ready Markdown inventory containing the external FQDN table and summary metrics.

Example:

| Environment | Project | Namespace | VirtualService | Gateway | FQDN | Owner | Status | Manifest |
|---|---|---|---|---|---|---|---|---|
| DEV | elasticsearch-project | elasticsearch | elasticsearch-vservice | istio-system/public-gateway | `elasticsearch.dev.mesh.abc.mod.com` | search-team | VALID | `elasticsearch-project/k8s/dev/virtualservice.yaml` |

### `virtualservice_fqdns.csv`

Machine-readable canonical inventory for spreadsheets, automation, and downstream analysis.

### `virtualservice_issues.csv`

Contains validation findings such as malformed hostnames, wildcard hosts, missing Gateways, and Gateway hostname mismatches.

### `duplicate_fqdns.txt`

Contains FQDNs that occur more than once in the generated inventory.

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

Included:

```text
elasticsearch.dev.mesh.abc.mod.com
```

Excluded:

```text
elasticsearch.svc.cluster.local
```

## Status values

| Status | Meaning |
|---|---|
| `VALID` | External FQDN passed basic static checks |
| `WILDCARD` | Host is a wildcard FQDN |
| `NONSTANDARD` | Host does not match basic FQDN syntax |
| `MISSING_GATEWAY` | VirtualService has no explicit Gateway |
| `GATEWAY_HOST_MISMATCH` | Host was not found on the referenced Gateway in repository manifests |

## Gateway validation

When a VirtualService references a Gateway, the script searches YAML manifests in the same Git repository and checks `Gateway.spec.servers[].hosts`. Exact hosts, `*`, wildcard domains, and namespace-qualified Istio Gateway host patterns are supported.

This is static source-control validation. It does not prove that deployed EKS/Istio configuration, DNS, load balancers, certificates, or backend services are healthy.

## Environment detection

Environment is inferred from manifest path, namespace, and FQDN. Recognized values are:

```text
PROD
UAT
STAGE
QA
TEST
DEV
UNKNOWN
```

For stronger governance, standardize an environment label or repository metadata field and make that the authoritative source.

## Recommended workflow

1. Identify the parent directory containing the Git repositories used by VS Code.
2. Run the script against the workspace root.
3. Review `virtualservice_fqdns.txt` for a readable inventory.
4. Review `virtualservice_fqdns.csv` for the canonical machine-readable inventory.
5. Review `virtualservice_issues.csv` and `duplicate_fqdns.txt` for findings.
6. Copy/import `virtualservice_fqdns_confluence.md` into Confluence.
7. Investigate validation findings before treating the inventory as authoritative.

## CI recommendation

Run the script in CI and retain all generated files as build artifacts. A future stricter mode can fail CI selectively for malformed production FQDNs, duplicate production FQDNs, or Gateway hostname mismatches.

## Security and operational notes

- No EKS/Kubernetes cluster access is required.
- Kubernetes Secrets are not queried or output.
- Do not store TLS private keys or credentials in generated reports.
- DNS resolution and TLS certificate validation are outside the current static-analysis scope.
- Generated reports are ignored by Git by default.
