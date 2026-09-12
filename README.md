# Extract FQDNs from Istio VirtualService Manifests

Recursively scans a local Git/VS Code workspace for Istio `VirtualService` YAML manifests and builds an external FQDN and routing inventory in CSV, plain-text, and Confluence-ready Markdown formats.

## No `yq` requirement

This version does **not** use `yq`. YAML parsing is performed with Python 3 and `PyYAML`, including support for multi-document Kubernetes YAML.

## What it does

- Searches all `*.yaml` and `*.yml` files below a workspace root.
- Extracts `spec.hosts[]` from Istio `VirtualService` resources.
- Excludes Kubernetes internal hosts ending in `.svc.cluster.local`.
- Detects `DEV`, `TEST`, `QA`, `UAT`, `STAGE`, and `PROD` from path, namespace, and hostname.
- Captures project, namespace, VirtualService, Gateway, owner/team, Git branch, Git remote, and manifest path.
- Captures HTTP route destination service, destination port, and URI prefix.
- Treats Istio's special `mesh` gateway correctly: it is shown in reports but skipped during Gateway resource lookup.
- Reports a missing manifest namespace as `UNKNOWN` rather than assuming `default`.
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

## Main inventory fields

| Field | Description |
|---|---|
| Environment | Inferred DEV/TEST/QA/UAT/STAGE/PROD environment |
| Project | Git repository/project name |
| Namespace | Manifest namespace, or `UNKNOWN` when not explicitly declared |
| VirtualService | Istio VirtualService name |
| Gateway | All values from `spec.gateways`, including `mesh` |
| FQDN | External/application hostname |
| Destination Service | HTTP route destination host/service |
| Destination Port | HTTP route destination port |
| URI Prefix | URI prefix from HTTP match rules |
| Owner | Owner/team label when available |
| Status | Static validation result |
| Git Branch | Current local repository branch |
| Git Remote | Git origin URL |
| Manifest | Manifest path relative to workspace root |

## Real-world VirtualService pattern

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: elasticsearch-cronjob-build-deploy-pipeline-vservice
spec:
  hosts:
    - elasticsearch-cronjob-build-deploy.dev.mesh.abc.mod.com
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

The report includes the external host:

```text
elasticsearch-cronjob-build-deploy.dev.mesh.abc.mod.com
```

and excludes:

```text
elasticsearch-cronjob-build-deploy-pipeline.svc.cluster.local
```

The route information is captured as:

```text
Destination Service : elasticsearch-cronjob-build-deploy-pipeline-service
Destination Port    : 443
URI Prefix          : /
```

Because the sample does not explicitly declare `metadata.namespace`, the report uses:

```text
Namespace : UNKNOWN
```

## Istio `mesh` gateway handling

A VirtualService can contain:

```yaml
gateways:
  - mesh
  - istio-ingress/default-gateway
```

`mesh` is an Istio reserved value representing sidecar/mesh routing. It is not the name of a Kubernetes `Gateway` resource. The script therefore:

1. Keeps `mesh` in the inventory so the source manifest is represented accurately.
2. Does **not** search Git for a Gateway resource named `mesh`.
3. Validates the external FQDN against `istio-ingress/default-gateway` when that Gateway manifest is available in the same repository.

## Missing namespace handling

The script deliberately does not assume that a VirtualService without `metadata.namespace` belongs to `default`.

It reports:

```text
UNKNOWN
```

This avoids a false namespace assignment when Helm, Kustomize, Argo CD, or a deployment pipeline supplies the namespace at deployment time.

## Status values

| Status | Meaning |
|---|---|
| `VALID` | External FQDN passed basic static checks |
| `WILDCARD` | Host is a wildcard FQDN |
| `NONSTANDARD` | Host does not match basic FQDN syntax |
| `MISSING_GATEWAY` | VirtualService has no explicit Gateway |
| `GATEWAY_HOST_MISMATCH` | Host was not found on a referenced non-`mesh` Gateway in repository manifests |

## Gateway validation

For non-`mesh` Gateway references, the script searches YAML manifests in the same Git repository and checks `Gateway.spec.servers[].hosts`. Exact hosts, `*`, wildcard domains, and namespace-qualified Istio Gateway host patterns are supported.

A Gateway manifest with no explicit namespace is not automatically treated as `default`; namespace matching is enforced only when the Gateway manifest explicitly declares one.

This is static source-control validation. It does not prove that deployed EKS/Istio configuration, DNS, load balancers, certificates, destination Services, or workloads are healthy.

## Output examples

### Plain text

```text
Environment         : DEV
Project             : example-project
Namespace           : UNKNOWN
VirtualService      : elasticsearch-cronjob-build-deploy-pipeline-vservice
Gateway             : mesh,istio-ingress/default-gateway
FQDN                : elasticsearch-cronjob-build-deploy.dev.mesh.abc.mod.com
Destination Service : elasticsearch-cronjob-build-deploy-pipeline-service
Destination Port    : 443
URI Prefix          : /
Owner               : -
Status              : VALID
Git Branch          : main
Manifest            : example-project/k8s/dev/virtualservice.yaml
```

### Confluence

| Environment | Project | Namespace | VirtualService | Gateway | FQDN | Destination Service | Port | URI Prefix | Owner | Status | Manifest |
|---|---|---|---|---|---|---|---:|---|---|---|---|
| DEV | example-project | UNKNOWN | elasticsearch-cronjob-build-deploy-pipeline-vservice | mesh,istio-ingress/default-gateway | `elasticsearch-cronjob-build-deploy.dev.mesh.abc.mod.com` | elasticsearch-cronjob-build-deploy-pipeline-service | 443 | `/` | - | VALID | `example-project/k8s/dev/virtualservice.yaml` |

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
