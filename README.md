# Extract FQDNs from Istio VirtualService Manifests

Recursively scans a local Git/VS Code workspace for Istio `VirtualService` YAML manifests and builds an external FQDN and routing inventory in CSV, plain-text, and Confluence-ready Markdown formats.

## No `yq` requirement

This version does **not** use `yq`. YAML parsing is performed with Python 3 and `PyYAML`, including support for multi-document Kubernetes YAML.

## What it does

- Searches all `*.yaml` and `*.yml` files below a workspace root.
- Extracts `spec.hosts[]` from Istio `VirtualService` resources.
- Excludes Kubernetes internal hosts ending in `.svc.cluster.local`.
- Detects `DEV`, `TEST`, `QA`, `UAT`, `STAGE`, `SHADOW`, and `PROD`.
- Prioritizes the final namespace suffix for environment detection.
- Falls back to the external FQDN and then manifest path when the namespace does not identify an environment.
- Captures project, namespace, VirtualService, external Gateway, mesh-routing indicator, owner/team, Git branch, Git remote, and manifest path.
- Captures HTTP route destination service, destination port, and URI prefix.
- Treats Istio's special `mesh` gateway correctly: it is reported separately as Mesh Routing and skipped during Gateway resource lookup.
- Reports a missing manifest namespace as `UNKNOWN` rather than assuming `default`.
- Flags wildcard and malformed hostnames.
- Flags VirtualServices without an explicit Gateway or mesh routing.
- Performs static VirtualService-to-Gateway hostname validation against Gateway manifests in the same Git repository.
- Detects duplicate FQDNs.
- Generates a human-readable `.txt` report and a structured Confluence-ready `.md` page.

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

## Environment detection

Environment detection uses this priority:

```text
1. Namespace suffix
2. External FQDN
3. Manifest path
4. UNKNOWN
```

The standard namespace convention is `<application-or-team>-<environment>`. The final hyphen-delimited token is treated as the environment when it matches a supported value.

Examples:

| Namespace | Environment |
|---|---|
| `aadt-ddx-ddd-prod` | `PROD` |
| `aadt-exec-dev` | `DEV` |
| `aadt-exec-shadow` | `SHADOW` |
| `aadt-service-qa` | `QA` |
| `aadt-api-uat` | `UAT` |
| `aadt-app-stage` | `STAGE` |
| `aadt-app-test` | `TEST` |

Supported values are:

```text
DEV
TEST
QA
UAT
STAGE
SHADOW
PROD
UNKNOWN
```

Using the namespace suffix first prevents an unrelated environment word elsewhere in the repository path or hostname from overriding the explicitly named namespace environment.

If the namespace is `UNKNOWN` or does not end in a recognized environment suffix, the script checks the external FQDN. The manifest path is used only as the final environment fallback.

## Main inventory fields

| Field | Description |
|---|---|
| Environment | Environment determined using namespace suffix first, then FQDN/path fallback |
| Project | Git repository/project name |
| Namespace | Manifest namespace, or `UNKNOWN` when not explicitly declared |
| VirtualService | Istio VirtualService name |
| Gateway | Non-`mesh` Gateway references from `spec.gateways` |
| Mesh Routing | `Yes` when `mesh` is present in `spec.gateways`; otherwise `No` |
| FQDN | External/application hostname |
| Destination Service | HTTP route destination host/service |
| Destination Port | HTTP route destination port |
| URI Prefix | URI prefix from HTTP match rules |
| Owner | Owner/team label when available |
| Status | Static validation result |
| Git Branch | Current local repository branch |
| Git Remote | Git origin URL |
| Manifest | Manifest path relative to workspace root |

## VirtualService example

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: elasticsearch-cronjob-build-deploy-pipeline-vservice
  namespace: aadt-exec-shadow
spec:
  hosts:
    - elasticsearch-cronjob-build-deploy.shadow.mesh.abc.mod.com
    - elasticsearch-cronjob-build-deploy-pipeline.svc.cluster.local
  gateways:
    - mesh
    - istio-ingress/default-gateway
  http:
    - match:
        - uri:
            prefix: "/"
      route:
        - destination:
            host: elasticsearch-cronjob-build-deploy-pipeline-service
            port:
              number: 443
```

The report includes the external host and reports:

```text
Environment : SHADOW
Namespace   : aadt-exec-shadow
```

The `.svc.cluster.local` hostname is excluded.

## Istio `mesh` gateway handling

For:

```yaml
gateways:
  - mesh
  - istio-ingress/default-gateway
```

the reports show:

```text
Gateway      : istio-ingress/default-gateway
Mesh Routing : Yes
```

`mesh` is an Istio reserved value representing sidecar/mesh routing, not a Kubernetes `Gateway` resource. It is therefore not searched as a Gateway manifest.

## Missing namespace handling

The script does not assume that a VirtualService without `metadata.namespace` belongs to `default`. It reports `UNKNOWN`, because Helm, Kustomize, Argo CD, or a deployment pipeline may supply the namespace at deployment time.

## Status values

| Status | Meaning |
|---|---|
| `VALID` | External FQDN passed basic static checks |
| `WILDCARD` | Host is a wildcard FQDN |
| `NONSTANDARD` | Host does not match basic FQDN syntax |
| `MISSING_GATEWAY` | VirtualService has neither an explicit external Gateway nor mesh routing |
| `GATEWAY_HOST_MISMATCH` | Host was not found on a referenced non-`mesh` Gateway in repository manifests |

## Confluence page

The generated page is titled:

**EKS Istio VirtualService – External FQDN & Routing Inventory**

and contains:

1. Overview
2. Summary
3. External FQDN & Routing Inventory
4. Validation Issues
5. Duplicate FQDNs
6. Validation Rules
7. Status Definitions
8. Important Notes

The main table includes Environment, Project, Namespace, VirtualService, External FQDN, Gateway, Mesh Routing, Destination Service, Port, URI, and Status.

## Recommended workflow

1. Identify the parent directory containing the Git repositories used by VS Code.
2. Run the script against the workspace root.
3. Review `virtualservice_fqdns.txt` for a readable inventory.
4. Review `virtualservice_fqdns.csv` for the canonical machine-readable inventory.
5. Review `virtualservice_issues.csv` and `duplicate_fqdns.txt` for findings.
6. Copy/import `virtualservice_fqdns_confluence.md` into Confluence.
7. Investigate validation findings before treating the inventory as authoritative.

## Security and operational notes

- No EKS/Kubernetes cluster access is required.
- Kubernetes Secrets are not queried or output.
- Do not store TLS private keys or credentials in generated reports.
- DNS resolution, TLS certificate validation, and live Service/workload validation are outside the current static-analysis scope.
- Generated reports are ignored by Git by default.
