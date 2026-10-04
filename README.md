# DevSecOps pipeline for OWASP Juice Shop

[![DevSecOps](https://github.com/vaclaviklluk/juice-shop-devsecops/actions/workflows/devsecops.yml/badge.svg)](https://github.com/vaclaviklluk/juice-shop-devsecops/actions/workflows/devsecops.yml)

A GitHub Actions pipeline that scans [OWASP Juice Shop](https://github.com/juice-shop/juice-shop)
(Node.js/Express backend, Angular frontend, shipped as a Docker image) with five kinds of
security testing, and aggregates every finding in [DefectDojo](https://github.com/DefectDojo/django-DefectDojo).
All tools are free and open source; the only platform used is GitHub Actions.

| Stage | Tool | What it scans | Report | DefectDojo scan type |
|---|---|---|---|---|
| SAST | [Semgrep](https://github.com/semgrep/semgrep) 1.179.0 (OSS engine) | Juice Shop source code | `semgrep.json` | Semgrep JSON Report |
| Secrets | [Gitleaks](https://github.com/gitleaks/gitleaks) 8.30.1 | The full git history of Juice Shop (21,511 commits scanned) | `gitleaks.json` | Gitleaks Scan |
| SCA | [OSV-Scanner](https://github.com/google/osv-scanner) 2.6.0 | npm dependency trees of the backend and the Angular frontend | `osv-scanner.json` | OSV Scan |
| SBOM | [Syft](https://github.com/anchore/syft) 1.54.0 + [Grype](https://github.com/anchore/grype) 0.120.0 | The released container image (OS packages and bundled npm modules) | `sbom.syft.json`, `sbom.cdx.json`, `grype.json` | Syft SBOM, Anchore Grype |
| DAST | [OWASP ZAP](https://github.com/zaproxy/zaproxy) 2.17.0 | The running application: spider, AJAX spider, passive and active scan | `zap-report.xml`, `zap-report.html` | ZAP Scan |

The application under test is pinned: release `v20.2.0`, commit `5658473`, image
`bkimminich/juice-shop:v20.2.0` by digest.

## How it works

```mermaid
flowchart LR
  src[("Juice Shop source<br/>v20.2.0")] --> sast["SAST<br/>Semgrep"]
  src --> secrets["Secrets<br/>Gitleaks"]
  src --> sca["SCA<br/>OSV-Scanner"]
  img[("Juice Shop image<br/>v20.2.0")] --> sbom["SBOM<br/>Syft → Grype"]
  img --> dast["DAST<br/>OWASP ZAP"]
  sast & secrets & sca & sbom & dast -- "reports (artifacts)" --> dd["Report job<br/>DefectDojo: import,<br/>summary, screenshots"]
```

Workflow: [`.github/workflows/devsecops.yml`](.github/workflows/devsecops.yml). It runs on every push and
pull request to `main` and on demand (`workflow_dispatch`).

1. **Five scan jobs run in parallel.** Each runs its scanner from a container image pinned by digest
   (the commands are in [`scripts/`](scripts/)) and uploads its report as an artifact.
   - *SAST* runs Semgrep with the `p/javascript`, `p/typescript`, `p/nodejs`, `p/expressjs`,
     `p/nodejsscan`, `p/owasp-top-ten`, `p/jwt`, `p/sql-injection`, `p/xss` and `p/default` rule packs.
   - *Secrets* runs Gitleaks over every commit; secret values are redacted in the report.
   - *SCA*: Juice Shop does not commit lockfiles (`.npmrc: package-lock=false`), so the job first resolves
     `package-lock.json` for the backend and the frontend with `npm install --package-lock-only --ignore-scripts`
     (nothing is installed or executed), then OSV-Scanner checks both trees against osv.dev.
   - *SBOM*: Syft catalogues the released image (the build artifact, pulled by digest, not the source tree)
     and writes the SBOM in Syft JSON and CycloneDX JSON; Grype then matches that SBOM against vulnerability
     databases. The job checks that the image's `org.opencontainers.image.revision` label names the commit the
     source stages scan, so all five stages cover the same release. SCA looks at what the source declares,
     the SBOM stage at what is actually shipped, including the Debian packages of the base image.
   - *DAST* starts the Juice Shop container on a private Docker network and runs a ZAP
     [automation plan](zap/automation.yaml): spider, AJAX spider (headless Firefox, needed for the Angular
     single-page app), passive scan, then an active scan capped at 20 minutes.
2. **The report job aggregates everything in DefectDojo.** It starts a throwaway DefectDojo 3.3.300 on the
   runner ([`defectdojo/docker-compose.yml`](defectdojo/docker-compose.yml)) and imports every report through
   the `/api/v2/import-scan/` API into one engagement, *GitHub Actions run &lt;id&gt;*, of the product
   *OWASP Juice Shop*, one test per tool.
   It then exports all findings, writes a per-stage severity table to the run summary, and captures
   DefectDojo screenshots with headless Chromium (Playwright).
   Everything is uploaded as the `defectdojo-results` artifact.

Juice Shop is vulnerable on purpose, so findings never fail a scan job. A job turns red only when a
scanner breaks, or when a report is missing or rejected by DefectDojo. The report job still imports the
remaining reports in that case.

The report job also has a security gate, off by default: set `FAIL_ON_SEVERITY` in the workflow to
`Critical`, `High`, `Medium`, `Low` or `Info` and the job fails when any finding is at that severity or
above. The gate's decision is written under the summary table either way.

## Results

Latest run: [DevSecOps #2](https://github.com/vaclaviklluk/juice-shop-devsecops/actions/runs/37203119479)
(commit `0ad0d11`, all six jobs green, 11 min 36 s). Findings per stage as imported into DefectDojo, copied from
the run summary:

| Stage / tool | Critical | High | Medium | Low | Info | Total |
|---|---:|---:|---:|---:|---:|---:|
| SAST - Semgrep | 0 | 48 | 78 | 6 | 0 | 132 |
| DAST - OWASP ZAP | 0 | 1 | 2 | 2 | 2 | 7 |
| SBOM - Syft package inventory | 0 | 0 | 0 | 0 | 712 | 712 |
| SBOM - Grype vulnerabilities | 12 | 71 | 62 | 13 | 7 | 165 |
| SCA - OSV-Scanner | 9 | 46 | 32 | 5 | 0 | 92 |
| Secrets - Gitleaks | 0 | 186 | 0 | 0 | 0 | 186 |
| **All stages** | 21 | 352 | 174 | 26 | 721 | 1294 |

DefectDojo merges duplicates while parsing, so some counts are lower than the raw reports: Semgrep reported 133
results and Gitleaks 216 leaks in the 21,511 commits it scanned.

What the stages found, in short:

- **DAST:** a High SQL injection in the product search (`GET /rest/products/search?q=`), plus a missing
  Content-Security-Policy, a permissive CORS policy, a private IP and Unix timestamps disclosed in responses.
  ZAP's spiders found 101 URLs (classic) and 519 URLs (AJAX), and the active scan took 5 minutes.
- **SAST:** NoSQL injection (19 findings), SQL injection through string-built queries and Sequelize (12),
  hard-coded passwords and JWTs, and 5 shell-injection risks in Juice Shop's own GitHub workflows.
- **SCA and SBOM:** both find the Critical advisories in `crypto-js` 3.3.0, `jsonwebtoken` 0.1.0 and 0.4.0,
  `lodash` 2.4.2, `decompress` 4.2.1, `marsdb` 0.6.11 and `tar` 6.2.1. Grype also reports Debian packages of the
  base image, such as `libssl3t64` and `libc6`. The SBOM lists 712 packages.
- **Secrets:** 133 generic API keys, 47 JWTs and 6 private keys in the git history. Most are deliberate
  challenge fixtures, but they show what the stage would catch in a real codebase.

Each run's full results (all findings as JSON, the summary table and the screenshots) are in its
`defectdojo-results` artifact; the raw reports, including the CycloneDX SBOM and the ZAP HTML report, are in the
`report-*` artifacts.

## Screenshots

All screenshots come from run [#2](https://github.com/vaclaviklluk/juice-shop-devsecops/actions/runs/37203119479).
The DefectDojo pages were captured by the pipeline itself (`scripts/defectdojo-screenshots.sh`); the GitHub pages
and the ZAP report were captured with the same headless browser from the public run page and the `report-dast`
artifact.

**Successful scans**

| | |
|---|---|
| Pipeline run: all jobs green, artifacts | [![Run summary](docs/screenshots/github/actions-run-summary.png)](docs/screenshots/github/actions-run-summary.png) |
| Workflow history | [![Workflow runs](docs/screenshots/github/actions-workflow-runs.png)](docs/screenshots/github/actions-workflow-runs.png) |
| DefectDojo engagement for the run: one test per tool, build ID, commit, run link | [![Engagement](docs/screenshots/defectdojo/02-engagement.png)](docs/screenshots/defectdojo/02-engagement.png) |
| ZAP's own HTML report | [![ZAP report](docs/screenshots/zap-html-report.png)](docs/screenshots/zap-html-report.png) |

**Vulnerabilities in DefectDojo**

| | |
|---|---|
| All open findings, most severe first | [![Open findings](docs/screenshots/defectdojo/03-open-findings.png)](docs/screenshots/defectdojo/03-open-findings.png) |
| DAST: ZAP findings, and the SQL injection | [![ZAP test](docs/screenshots/defectdojo/11-test-dast-owasp-zap.png)](docs/screenshots/defectdojo/11-test-dast-owasp-zap.png) [![SQL injection](docs/screenshots/defectdojo/11-finding-dast-owasp-zap.png)](docs/screenshots/defectdojo/11-finding-dast-owasp-zap.png) |
| SAST: Semgrep findings, and one in detail | [![Semgrep test](docs/screenshots/defectdojo/10-test-sast-semgrep.png)](docs/screenshots/defectdojo/10-test-sast-semgrep.png) [![Semgrep finding](docs/screenshots/defectdojo/10-finding-sast-semgrep.png)](docs/screenshots/defectdojo/10-finding-sast-semgrep.png) |
| SCA: OSV-Scanner findings, and a Critical one | [![OSV test](docs/screenshots/defectdojo/14-test-sca-osv-scanner.png)](docs/screenshots/defectdojo/14-test-sca-osv-scanner.png) [![OSV finding](docs/screenshots/defectdojo/14-finding-sca-osv-scanner.png)](docs/screenshots/defectdojo/14-finding-sca-osv-scanner.png) |
| SBOM: Grype vulnerabilities in the image, and a Critical one | [![Grype test](docs/screenshots/defectdojo/13-test-sbom-grype-vulnerabilities.png)](docs/screenshots/defectdojo/13-test-sbom-grype-vulnerabilities.png) [![Grype finding](docs/screenshots/defectdojo/13-finding-sbom-grype-vulnerabilities.png)](docs/screenshots/defectdojo/13-finding-sbom-grype-vulnerabilities.png) |
| SBOM: Syft package inventory | [![Syft test](docs/screenshots/defectdojo/12-test-sbom-syft-package-inventory.png)](docs/screenshots/defectdojo/12-test-sbom-syft-package-inventory.png) [![Syft package](docs/screenshots/defectdojo/12-finding-sbom-syft-package-inventory.png)](docs/screenshots/defectdojo/12-finding-sbom-syft-package-inventory.png) |
| Secrets: Gitleaks findings, and one with the value redacted | [![Gitleaks test](docs/screenshots/defectdojo/15-test-secrets-gitleaks.png)](docs/screenshots/defectdojo/15-test-secrets-gitleaks.png) [![Gitleaks finding](docs/screenshots/defectdojo/15-finding-secrets-gitleaks.png)](docs/screenshots/defectdojo/15-finding-secrets-gitleaks.png) |
| DefectDojo dashboard | [![Dashboard](docs/screenshots/defectdojo/01-dashboard.png)](docs/screenshots/defectdojo/01-dashboard.png) |

## Security of the pipeline

- **Pinned supply chain.** Every action is pinned to a full commit SHA, and every tool and DefectDojo image to a
  digest. Juice Shop is checked out by commit, not by tag, and its image is pulled by digest. The Playwright
  package used for screenshots is installed with `npm ci` from a committed lockfile (integrity hashes, no
  install scripts). ZAP runs with `-silent`, so it uses only the add-ons in the pinned image instead of
  downloading updates at start.
- **Dependency updates.** Dependabot proposes updates for the action pins and for the DefectDojo images in the
  compose file, each after a 7-day cooldown, so a hijacked release has time to be noticed. DefectDojo image
  updates that are due together arrive in one pull request; check that the django and nginx images are on the
  same release before merging. Dependabot alerts and security updates are on for the repository,
  which covers the screenshot lockfile.
- **Least privilege.** The workflow token is read-only (`permissions: contents: read`), checkouts do not
  persist credentials, and the pipeline needs no repository secrets, so pull requests from forks run with
  nothing to steal. The scanner containers run as the runner's unprivileged user (ZAP as its image's own
  non-root user), and no container gets the Docker socket: Syft pulls the image straight from the registry.
- **Secrets handling.** DefectDojo's admin password, Django secret key, credential encryption key and database
  password are generated for each run and masked in the logs. Only the admin password, which the later steps
  need, is written to a file, with mode 600. The compose file has no default secrets and refuses to start
  without them. The password and the API token reach `curl` through
  stdin and a mode-600 header file, never through command-line arguments. DefectDojo listens on `127.0.0.1`
  only and disappears with the runner.
- **Redacted secrets report.** Gitleaks runs with `--redact`, so the secret values it finds are not copied
  into the artifacts or DefectDojo. Other reports can still quote source code or HTTP responses as evidence.
- **No script injection.** `run:` steps do not interpolate event data, and job timeouts and concurrency
  limits are set.
- **Checked with linters.** The workflow passes [actionlint](https://github.com/rhysd/actionlint),
  [zizmor](https://github.com/zizmorcore/zizmor) (`--persona=auditor`, online audits) and
  [ShellCheck](https://www.shellcheck.net/) with no findings.

### Repository settings

| Setting | Value |
|---|---|
| Allowed actions | GitHub-owned only, pinned to a full commit SHA (`sha_pinning_required`) |
| Default `GITHUB_TOKEN` permissions | read; Actions cannot approve pull requests |
| Workflows on pull requests from forks | need approval for all outside contributors |
| Secret scanning and push protection | on |
| Dependabot alerts and security updates | on |
| `main` branch ruleset | no deletion, no force-push |

### Residual risks

- Tool images pinned in the workflow `env:` are not tracked by Dependabot and are bumped by hand.
- Some inputs are fetched at run time and are not pinned by this workflow: the Semgrep registry rule packs,
  the Grype vulnerability database and the osv.dev API. Results can change between runs of the same commit.
- Image signatures and provenance attestations are not verified. The revision-label check ties the image to
  the scanned commit, but the label is set by whoever built the image.
- Runner egress is not restricted (no egress filter such as harden-runner), and the screenshot container uses
  the host network to reach DefectDojo on `127.0.0.1`.

## Running it

- **On GitHub:** fork the repository, enable Actions, then run *DevSecOps* from the Actions tab. When it finishes,
  download the `defectdojo-results` artifact (findings, summary, screenshots) or the per-stage `report-*` artifacts.
- **Locally** (Docker with Compose v2, `jq`, `curl`): export the variables in the `env:` block of the workflow
  (Juice Shop version, commit and image, tool images), check out Juice Shop at the pinned commit into `juice-shop/`, then run the scripts in the same order as
  the jobs:

  ```sh
  scripts/sast-semgrep.sh juice-shop reports
  scripts/secrets-gitleaks.sh juice-shop reports
  scripts/sca-osv.sh juice-shop reports
  scripts/sbom-syft-grype.sh reports
  scripts/dast-zap.sh reports
  scripts/defectdojo-up.sh            # DefectDojo on http://127.0.0.1:8080 (DD_PORT to change)
  scripts/defectdojo-import.sh reports defectdojo-results
  scripts/defectdojo-screenshots.sh defectdojo-results
  ```

  The admin password of the local DefectDojo is in `$DD_ENV_FILE` (default `/tmp/defectdojo.env`).

## Repository layout

```
.github/workflows/devsecops.yml   pipeline definition
.github/dependabot.yml            updates for the pinned actions and DefectDojo images
scripts/                          one script per stage, plus DefectDojo start, import and screenshots
zap/automation.yaml               ZAP automation framework plan
defectdojo/docker-compose.yml     throwaway DefectDojo used by the report job
docs/screenshots/                 screenshots from a pipeline run
```

## Limitations

- The DAST scan is unauthenticated: it covers the public pages and REST endpoints, not the features behind login.
  The active scan is capped at 20 minutes to keep the pipeline under an hour.
- DefectDojo exists only for the duration of a run, so it keeps no history across runs. Findings are kept in the
  run artifacts for 30 days. For a long-lived setup, point the import script at a hosted DefectDojo and use
  reimport to track findings over time.
- Lockfiles are resolved when the SCA job runs, so its results can change as new dependency versions are published.
- DefectDojo's Syft parser imports every SBOM package as an *Info* finding (inventory); vulnerabilities in those
  packages come from the Grype test.
