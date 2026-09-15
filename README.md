# Extract FQDNs from Istio VirtualService Manifests

Recursively scans a local Git/VS Code workspace for Istio `VirtualService` manifests and creates a simplified inventory of externally exposed application URLs.

## What it does

- Searches `*.yaml` and `*.yml` files below a workspace root.
- Extracts `spec.hosts[]` from Istio `VirtualService` resources.
- Excludes Kubernetes internal hosts ending in `.svc.cluster.local`.
- Adds `https://` before every external hostname in the report.
- Extracts the project namespace from `config.json` as the primary namespace source.
- Falls back to VirtualService `metadata.namespace` only when a namespace cannot be obtained from `config.json`.
- Detects environment from namespace suffix first, then FQDN, then manifest path.
- Reports project, namespace, VirtualService, HTTPS URL, destination port, Git remote, and manifest path.
- Detects malformed/wildcard hostnames and duplicate external URLs.
- Uses Gateway information internally for static validation without displaying Gateway details in the primary inventory.
- Supports `--dry-run` / `-n`.
- Does not require `yq`.

## Requirements

- Bash 4+
- Git
- Python 3
- Python `PyYAML`

Python's standard `json` module is used to parse `config.json`; no additional JSON command-line utility such as `jq` is required.

Verify:

```bash
git --version
python3 --version
python3 -c 'import yaml; print(yaml.__version__)'
```

If permitted, install PyYAML with:

```bash
python3 -m pip install --user pyyaml
```

## Usage

```bash
chmod +x extract-vservice-fqdns.sh
```

Run a dry-run first:

```bash
./extract-vservice-fqdns.sh --dry-run /path/to/git/workspace
```

Short form:

```bash
./extract-vservice-fqdns.sh -n /path/to/git/workspace
```

Normal run:

```bash
./extract-vservice-fqdns.sh /path/to/git/workspace
```

Example:

```bash
./extract-vservice-fqdns.sh --dry-run /opt/apps/git
./extract-vservice-fqdns.sh /opt/apps/git
```

Custom output directory for a normal run:

```bash
OUTPUT_DIR=/tmp/fqdn-report ./extract-vservice-fqdns.sh /opt/apps/git
```

## Namespace extraction from config.json

The namespace source priority is:

```text
1. config.json
2. VirtualService metadata.namespace
3. UNKNOWN
```

For every VirtualService manifest, the script first looks for the nearest `config.json` by walking upward from the manifest directory to the Git repository root. This is useful when a repository contains environment-specific directories, each with its own configuration.

If no `config.json` is found on that path, the script searches the same Git repository for a `config.json` and uses the first one it finds. It does not intentionally cross into another Git repository to obtain a namespace.

A simple configuration such as:

```json
{
  "namespace": "aadt-exec-shadow"
}
```

produces:

```text
Namespace   : aadt-exec-shadow
Environment : SHADOW
```

The parser first checks common JSON locations including:

```text
namespace
kubernetes.namespace
eks.namespace
deployment.namespace
metadata.namespace
config.namespace
```

If none of those paths exists, it recursively searches the JSON document for the first scalar key named `namespace`. Key matching is case-insensitive.

If no usable namespace can be extracted from `config.json`, the script uses the VirtualService's `metadata.namespace`. If neither source provides a namespace, the report uses `UNKNOWN`.

## Dry-run behavior

Dry-run performs the same manifest discovery, `config.json` namespace extraction, and validation as a normal run, but report files are created only in a temporary directory. The text inventory and summary are displayed in the terminal, and the temporary files are automatically removed when the script exits.

The configured `OUTPUT_DIR` is not populated during dry-run.

## Generated files

A normal run generates:

```text
eks-virtualservice-report/
├── virtualservice_fqdns.csv
├── virtualservice_fqdns.txt
├── virtualservice_fqdns_confluence.md
├── virtualservice_issues.csv
└── duplicate_fqdns.txt
```

| File | Purpose |
|---|---|
| `virtualservice_fqdns.csv` | Canonical external HTTPS URL inventory |
| `virtualservice_fqdns.txt` | Human-readable inventory and summary |
| `virtualservice_fqdns_confluence.md` | Confluence-ready Markdown report |
| `virtualservice_issues.csv` | Static validation findings |
| `duplicate_fqdns.txt` | External HTTPS URLs discovered more than once |

## Primary inventory fields

The primary CSV, text, and Confluence inventory contains only:

| Field | Description |
|---|---|
| Environment | Environment detected from namespace/FQDN/path |
| Project | Git repository/project name |
| Namespace | Namespace from `config.json`, with manifest namespace fallback |
| VirtualService | Istio VirtualService name |
| HTTPS URL | External VirtualService host with `https://` prefix |
| Destination Port | HTTP route destination port |
| Git Remote | Git origin URL |
| Manifest | Manifest path relative to the workspace root |

The following fields are intentionally excluded from the primary report:

```text
Gateway
Mesh Routing
Git Branch
URI Prefix
Destination Service
Owner
Status
```

Gateway information may still be used internally by the scanner to identify validation issues, but it is not included in the primary inventory.

## HTTPS URL formatting

Given this VirtualService host:

```yaml
spec:
  hosts:
    - elasticsearch-cronjob-build-deploy.shadow.mesh.abc.mod.com
```

the report displays:

```text
https://elasticsearch-cronjob-build-deploy.shadow.mesh.abc.mod.com
```

The `https://` prefix is added for reporting convenience. The script does not perform a live TLS or HTTP connectivity test, so the prefix should not be interpreted as proof that the endpoint currently serves HTTPS.

Internal Kubernetes hosts such as the following remain excluded:

```text
elasticsearch-cronjob-build-deploy-pipeline.svc.cluster.local
```

## Environment detection

After resolving the namespace, environment detection uses this priority:

```text
1. Namespace suffix
2. External FQDN
3. Manifest path
4. UNKNOWN
```

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

Supported values:

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

## Example report record

Given a project `config.json` containing `aadt-exec-shadow`, a record can look like:

```text
Environment      : SHADOW
Project          : elasticsearch-cronjob-build-deploy
Namespace        : aadt-exec-shadow
VirtualService   : elasticsearch-cronjob-build-deploy-pipeline-vservice
HTTPS URL        : https://elasticsearch-cronjob-build-deploy.shadow.mesh.abc.mod.com
Destination Port : 443
Git Remote       : git@github.com:example/elasticsearch-cronjob-build-deploy.git
Manifest         : elasticsearch-cronjob-build-deploy/k8s/virtualservice.yaml
```

## Validation issues

Validation findings remain separate from the primary inventory in:

```text
virtualservice_issues.csv
```

This keeps the main report focused on the external URL inventory while preserving useful static-analysis findings.

## Confluence page

The generated Confluence-ready page contains:

1. Overview
2. Summary
3. External FQDN Inventory
4. Validation Issues
5. Duplicate URLs
6. Validation Rules
7. Important Notes

The main Confluence table contains:

```text
Environment
Project
Namespace
VirtualService
HTTPS URL
Destination Port
Git Remote
Manifest
```

## Recommended workflow

1. Identify the parent directory containing the Git repositories used by VS Code.
2. Confirm each application/project has the expected namespace in `config.json`.
3. Run the script with `--dry-run` first.
4. Review the namespace, environment, HTTPS URL, and summary in the terminal inventory.
5. Run normally to create persistent reports.
6. Review `virtualservice_fqdns.csv` as the canonical inventory.
7. Review `virtualservice_issues.csv` and `duplicate_fqdns.txt` separately.
8. Copy/import `virtualservice_fqdns_confluence.md` into Confluence.

## Security and operational notes

- No EKS/Kubernetes cluster access is required.
- Kubernetes Secrets are not queried or output.
- Source manifests and `config.json` files are read only.
- Namespace lookup is scoped to the Git repository containing the VirtualService.
- Dry-run does not populate the configured output directory.
- Generated reports are ignored by Git by default.
- The script does not verify live DNS, TLS certificates, load balancers, Services, workloads, or application availability.
