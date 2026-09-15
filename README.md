# Extract FQDNs from Istio VirtualService Manifests

Recursively scans a local Git/VS Code workspace for Istio `VirtualService` manifests and creates a simplified inventory of externally exposed application URLs.

## What it does

- Searches `*.yaml` and `*.yml` files below a workspace root.
- Extracts `spec.hosts[]` from Istio `VirtualService` resources.
- Excludes Kubernetes internal hosts ending in `.svc.cluster.local`.
- Adds `https://` before every external hostname.
- Extracts namespace from the project's `config.json`, with `metadata.namespace` fallback.
- Detects environment from namespace suffix, then FQDN, then manifest path.
- Reports Environment, Project, Namespace, VirtualService, HTTPS URL, Destination Port, Git Remote, and Manifest.
- Supports `--dry-run` / `-n`.
- Does not require `yq` or `jq`.

## Requirements

- Bash 4+
- Git
- `python`
- Python `PyYAML`

The script intentionally uses the `python` command rather than `python3`.

Verify:

```bash
git --version
python --version
python -c 'import yaml; print(yaml.__version__)'
```

If permitted, install PyYAML with:

```bash
python -m pip install --user pyyaml
```

## Usage

```bash
chmod +x extract-vservice-fqdns.sh
./extract-vservice-fqdns.sh --dry-run /path/to/git/workspace
./extract-vservice-fqdns.sh /path/to/git/workspace
```

Example:

```bash
./extract-vservice-fqdns.sh --dry-run /opt/apps/git
./extract-vservice-fqdns.sh /opt/apps/git
```

## Namespace extraction

Namespace source priority:

```text
1. config.json
2. VirtualService metadata.namespace
3. UNKNOWN
```

The script searches from the VirtualService directory upward to the Git repository root for `config.json`. If needed, it then searches the same repository for a `config.json`.

Example:

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

## Environment detection

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

## Generated files

```text
eks-virtualservice-report/
├── virtualservice_fqdns.csv
├── virtualservice_fqdns.txt
├── virtualservice_fqdns_confluence.md
├── virtualservice_issues.csv
└── duplicate_fqdns.txt
```

## Primary inventory fields

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

The primary report intentionally excludes Gateway, Mesh Routing, Git Branch, URI Prefix, Destination Service, Owner, and Status.

## HTTPS URL formatting

A VirtualService host such as:

```text
elasticsearch-cronjob-build-deploy.shadow.mesh.abc.mod.com
```

is reported as:

```text
https://elasticsearch-cronjob-build-deploy.shadow.mesh.abc.mod.com
```

Hosts ending in `.svc.cluster.local` are excluded.

## Dry-run

```bash
./extract-vservice-fqdns.sh --dry-run /opt/apps/git
```

Dry-run performs the scan using temporary report files, prints the text report, and removes the temporary directory when the script exits.

## Security and operational notes

- No EKS/Kubernetes cluster access is required.
- Kubernetes Secrets are not queried.
- Source manifests and `config.json` files are read only.
- Namespace lookup remains within the Git repository containing the VirtualService.
- The script does not verify live DNS, TLS certificates, load balancers, Services, workloads, or application availability.
