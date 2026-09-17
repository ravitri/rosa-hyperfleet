# Optimize CodePipeline: Direct Provisioning, Parallel RC/MC, MC Autoscaling Compatibility

**Last Updated Date**: 2026-09-17

## Summary

This ADR optimizes the ROSA HyperFleet provisioning flow by eliminating the `pipeline-provisioner` meta-pipeline and enabling parallel Regional Cluster (RC) and Management Cluster (MC) provisioning. The current three-hop flow (bootstrap → pipeline-provisioner → sequential RC then MC pipeline creation → infrastructure apply) is replaced with direct RC pipeline creation in bootstrap and a parameterized **MC factory** (a reusable CodeBuild project that provisions one MC instance per invocation) that provisions MCs in parallel. RC and MC infrastructure apply runs concurrently, eliminating the 45-minute polling delay where MC waits for RC Terraform outputs. The factory accepts `management_id` and account as inputs, making it compatible with future MC autoscaling without requiring the scaler in this phase — the same `StartBuild` call works for bootstrap and for a future scaler. Configuration stays GitOps-driven (`initial_count` and `account_pool` in git), while MC instance creation via factory `StartBuild` is the approved exception to "GitOps First" for provisioning.

## Consequences

**Positive:**

- **Faster provisioning**: Parallel RC/MC reduces critical path from ~90-140 min to ~50-70 min by eliminating the 45-min MC polling delay and overlapping RC apply with MC apply 1
- **Fewer AWS resources**: Reduces CodePipeline count (3 → 2 for ephemeral) and CodeBuild projects (8 → 6 for ephemeral)
- **Scaler-compatible**: Factory interface (`StartBuild` with `management_id`, account) is the same job a future scaler can invoke
- **Simpler mental model**: Two layers (bootstrap → cluster pipelines) instead of three (bootstrap → provisioner → cluster pipelines)
- **No git churn for scale-out**: `initial_count` and `account_pool` in git; MC instance creation doesn't require a commit

**Negative:**

- **More complex bootstrap**: Bootstrap orchestrates parallel MC factory invocation, SSM parameter polling, and Register coordination
- **Deferred RC decoupling**: Phase 3 removes `var.management_clusters` from RC Terraform but requires a new MC discovery mechanism for Grafana/alerting (not yet designed)
- **SSM dependency**: MC apply 2 polls SSM parameters (`oidc-cloudfront-domain`, `rhobs-api-url`) written by RC, introducing retry logic
- **Provisioner code orphaned**: Existing integration/stage environments keep using provisioner infrastructure (orphaned but functional) after provisioner code deleted from repo

## Context

**Today**

- Three hops: bootstrap → `pipeline-provisioner` → sequential RC then MC **pipeline definitions** → cluster pipelines Source from GitHub and apply.
- MC Deploy polls RC terraform outputs (90×30s, 45 min) before it can plan.
- Identity is git keys (`provision_mcs: mc01: {}`) baked into RC as `management_clusters=mc01:account`. Cannot grow/shrink without git + another provisioner run.

**Goals:** drop `pipeline-provisioner`; parallel RC/MC; minimize `provision-infra*.sh`; pre-evaluate deterministic RC→MC values; fewer CodeBuild/CodePipeline resources; scaler-compatible without shipping a scaler.

**Must**

- Per-cluster state and destroy; factory keyed by `management_id`; N MCs per account.
- Kube-applier DynamoDB on the MC lifecycle; RC authorizes an account pool / OU, not a cluster roster.

**Must not**

- Density scaler, `max_count` enforcement, or `DELETE /api/v0/management_clusters/{id}`.
- Unique `management_id` generator (ULID) — [Future optimizations](#future-optimizations).
- Account minting — [regional-account-minting.md](regional-account-minting.md).

**Constraints:** CodeStar GitOps for **existing** cluster pipelines; pipelines in the central account, assume child-admin; ECS Fargate private bootstrap; OU-based OIDC/DNS trust; `enable_*` flags (lowest barrier for a new region); no pipelines that only wrap other pipelines.

**Assumptions:** ephemeral `initial_count: 1`; same factory in other envs (different counts/pools); Register is the live MC directory; kube-applier tables in the RC account, created/destroyed with that MC.

## Alternatives Considered

1. **Keep pipeline-provisioner, parallelize only MC Deploy.** Rejected: provisioner and git `mc01` keys remain.
2. **`for_each` over `provision_mcs` in `central-account-bootstrap`.** Rejected as the scale mechanism: git still names every MC.
3. **One shared MC CodePipeline, many concurrent executions.** Rejected: destroy and state must be per MC.
4. **Parameterized MC factory (chosen).** Bootstrap applies RC and `StartBuild`s the factory once per initial MC. Git stores `initial_count` and `account_pool`. A later scaler can call the same job.

## Design Rationale

- `pipeline-provisioner` only creates cluster pipeline definitions from git JSON. A factory that applies **one** MC (infra + day-2 pipeline) removes that hop, allows parallel initial MCs, and is the same job a later scaler can `StartBuild`.
- RC is 1:1 with a region — stays in bootstrap Terraform.
- Day-2 changes to an **existing** cluster stay GitOps. Creating an MC **instance** is not a git key: factory `StartBuild` is the approved exception to "GitOps First" (for provisioning, not an automatic scaler). `initial_count` and `account_pool` stay in git.

**Evidence**

- Sequential RC-then-MC: [provision-pipelines.sh](../../scripts/provision-pipelines.sh).
- 45-minute poll: [provision-infra-mc.sh](../../scripts/buildspec/provision-infra-mc.sh). OIDC bucket/roles and ZOA names are convention-stable; `rhobs_api_url` is not an MC terraform input.
- `mc01` hardcoded in CI and `scripts/dev/`; shared MC CodeBuild IAM wildcards assume `mc01`.
- Default VPC `10.0.0.0/16` collides for two MCs in one account.

## Architecture

### Current provisioning flow

```mermaid
flowchart TB
  CBoot[bootstrap-central-account.sh]
  CProv[pipeline-provisioner]
  CImg[Build-Platform-Image]
  CScan[Create RC then MC pipeline definitions]
  CBoot --> CProv --> CImg --> CScan
  subgraph currentRc [RC pipeline]
    direction TB
    CRcSrc[Source from GitHub]
    CRcDep[Deploy terraform]
    CRcBoot[Bootstrap ArgoCD]
    CRcSrc --> CRcDep --> CRcBoot
  end
  subgraph currentMc [MC pipeline]
    direction TB
    CMcSrc[Source from GitHub]
    CMcDep[Deploy terraform]
    CMcDdb[Kube-applier DynamoDB]
    CMcBoot[Bootstrap ArgoCD]
    CMcReg[Register]
    CMcSrc --> CMcDep --> CMcDdb --> CMcBoot --> CMcReg
  end
  CScan --> CRcSrc
  CScan --> CMcSrc
  CRcDep -.->|"CloudFront, OIDC bucket, RHOBS"| CMcDep
  CRcBoot -.->|"API URL then GET /live"| CMcReg
```

MC Deploy cannot start terraform until CloudFront, OIDC bucket (name/ARN/region), **and** `rhobs_api_url` exist (timeout 45 min). Writer/reader ARNs are already convention-based; ZOA is a single post-poll `terraform output` with no retry. Register is a later stage after MC ArgoCD and polls the API URL again (90×30s) then `/live` (10×30s). Wall clock is often **~90–140 minutes**: provisioner 10–20 min + GitHub Source + RC apply 30–45 min (MC Deploy sleeps through most of this) + MC apply 20–40 min + DynamoDB + ArgoCD 10–20 min + Register.

Critical path: `provisioner + Source + RC apply + MC apply + DynamoDB + MC ArgoCD + Register`.

### After this ADR

```mermaid
flowchart TB
  FBoot[bootstrap-central-account.sh]
  FImg[Build image only if tag missing]
  FBoot --> FImg
  subgraph finalRc [RC first provision]
    direction TB
    FRcA["Apply: VPC, EKS, RDS, OIDC, API, ZOA; write SSM"]
    FRcB[Bootstrap ArgoCD]
    FRcA --> FRcB
  end
  subgraph finalMc [MC factory]
    direction TB
    FMc1[Apply 1: VPC and EKS]
    FMc2["Apply 2: HyperShift OIDC, ZOA, DynamoDB"]
    FMcB[Bootstrap ArgoCD]
    FMc1 --> FMc2 --> FMcB
  end
  FReg[Register in bootstrap]
  FImg --> FRcA
  FImg --> FMc1
  FRcA -->|"oidc-cloudfront-domain"| FMc2
  FRcA -->|"rhobs-api-url"| FMcB
  FRcB -->|"API /live"| FReg
  FMc2 --> FReg
```

MC apply 1 has **no RC dependency**. Deterministic names are tfvars. SSM is CloudFront (apply 2) and RHOBS (MC ArgoCD). Image build is skipped when the Dockerfile-hash tag exists.

**Register** is the only first-provision step that needs both sides (API `/live` and `management_id` after apply 2). Bootstrap POSTs it so the factory does not hold Register retries and RC does not learn MC ids. That **overlaps** MC ArgoCD. Do not wait until both jobs fully finish. Day-2 git still Registers on the MC CodePipeline (parallel with Bootstrap) because there is no orchestrator on a git push. CI E2E can follow provision; it is not a third provision pipeline.

The Register payload includes:

- `cluster_id` — from management-cluster configuration
- `management_id` — from management-cluster configuration (factory input)
- `region` — from `TARGET_REGION` environment variable
- `alias` — from management-cluster configuration
- `cloudfront_url` — from MC Apply 2's CloudFront domain output

Critical path (image already in ECR): `max(max(RC apply, MC apply 1) + MC apply 2 + MC ArgoCD, max(RC apply + RC ArgoCD, max(RC apply, MC apply 1) + MC apply 2) + Register)`. RC apply still dominates (~30–45 min, then ArgoCD ~10–20 min). MC EKS runs **during** RC apply. Register waits for both RC ArgoCD (API `/live` endpoint) and MC apply 2 (`management_id` and CloudFront domain), running in parallel with MC ArgoCD.

Off the clock: provisioner, first-run GitHub Source, the 45-minute poll, Register-after-MC-ArgoCD, extra DynamoDB stage. Still on the clock: EKS/RDS/NAT, ECS bootstrap, first `/live`. Reject putting ArgoCD into Terraform, skipping day-2 pipelines, merging RC+MC state, and `terraform apply -target`.

CodePipeline and CodeBuild stay in the **control (central) account** and assume-role into RC/MC. RC and MC accounts host none.

| Account | Resource     | Current (1 RC + _N_ MC)                                                                                | After this ADR                                                                             |
| ------- | ------------ | ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------ |
| Control | CodePipeline | 1 provisioner + 1 RC + _N_ MC                                                                          | 1 RC + _N_ MC                                                                              |
| Control | CodeBuild    | 2 provisioner (image, scan) + 2 RC (apply, bootstrap) + 4*N* MC (apply, DynamoDB, bootstrap, register) | 1 factory + 2 RC + 3*N* MC (DynamoDB folded into apply; image in bootstrap, not a project) |
| RC      | either       | 0                                                                                                      | 0                                                                                          |
| MC      | either       | 0                                                                                                      | 0                                                                                          |

Ephemeral (_N_=1): **3 pipelines / 8 builds → 2 / 6**. First-provision Register is bootstrap (not a new project); day-2 still uses the MC register CodeBuild.

### Identity, topology, and factory

The **MC factory** is a parameterized CodeBuild project in the central account that provisions one MC instance per invocation. Bootstrap (or a future scaler) invokes it via `StartBuild` with parameters `MANAGEMENT_ID`, `TARGET_ACCOUNT_ID`, and `IS_DESTROY`. The factory applies MC Terraform, bootstraps ArgoCD, and creates the MC's day-2 CodePipeline. Unlike the old provisioner (which created pipeline definitions for all clusters), the factory provisions **one** MC's infrastructure and pipeline definition per run.

Factory **receives** `management_id`; it does not generate one in this ADR. Values stay as today: integration/stage `mc01`; ephemeral `{eph_prefix}-mc01` from `make_eph_prefix` (`eph-{sha256(BUILD_ID)[:6]}` in CI, `eph-{id}` locally). A unique generator is a [future optimization](#future-optimizations). Account from a **pool**; one MC per account (this ADR). State: RC `regional-cluster/${regional_id}.tfstate`; MC `management-cluster/${management_id}.tfstate` in that cluster's account. One CodePipeline per cluster (`${id}-pipe`). One VPC per MC with hardcoded CIDR `10.0.0.0/16`.

```yaml
# config/<env>/<region>.yaml (illustrative)
management_clusters:
  initial_count: 1 # this ADR focuses on single MC
  account_pool:
    - "ssm:///infra/<env>/<region>/mc/account_id"
```

`MANAGEMENT_ID` is always set for create, destroy, and day-2. Parameters: `TARGET_ACCOUNT_ID`, `IS_DESTROY`. First apply runs **in the factory job**. A future scaler would `StartBuild` the same factory (and would need a unique id generator first).

kube-applier DynamoDB stays on the MC lifecycle (tables in the RC account, created/destroyed with that MC in Apply 2). Two separate IAM identities access these tables:

- **MC kube-applier** (`${management_id}-kube-applier` Pod Identity role): scoped specs-table reads and status-table writes (MC controller reads desired state, writes actual state)
- **RC hyperfleet-operator** (`${rc_id}-hyperfleet-operator` Pod Identity role): per-MC specs writes and status reads (RC controller writes desired state, reads actual state)

### RC→MC dependencies

- Two MC Terraform roots, **one CodeBuild job**, no `-target`.
  - Apply 1: `terraform/config/management-cluster` (VPC/EKS), parallel with RC.
  - Apply 2: `terraform/config/management-cluster-rc-bind` + kube-applier DynamoDB; retry SSM in-process.
- **Convention names → tfvars** (no poll): OIDC bucket `hypershift-${regional_id}-oidc-${rc_account_id}`; writer/key-reader and DNS zone operator ARNs; ZOA tables/bucket/uploader roles; KMS **alias** ARN (not key UUID); ZOA Lambda ECR URI.
- **SSM** (RC Terraform writes, same stack): `oidc-cloudfront-domain`, `api-gateway-invoke-url` (Register), `rhobs-api-url` (MC ArgoCD only). Apply 2 reads `data.aws_ssm_parameter`. `rhobs_api_url` is not an apply-1 input.
- **Drop `var.management_clusters` (Phase 3)** — git roster `mc01:account` is not needed for RC resources. RHOBS/OIDC/DNS already trust the MC OU.
  - Today it only feeds authz `bootstrap_accounts` (not API Gateway) and a Helm annotation used by Grafana/alerting.
  - Replace with the **account pool** (SSM) for authz bootstrap. Register is the live MC directory. Grafana/alerting read Register (compatibility annotation may list registered IDs until then).
- Replace `provision-infra-*.sh` with `terraform.tfvars.json` + `data` sources + `assume_role`. Keep thin ECS bootstrap and Register/Deregister scripts.

#### Two-Phase MC Apply Sequencing

The MC factory runs two Terraform applies sequentially in a single CodeBuild job:

**Apply 1** (`terraform/config/management-cluster`):

- Creates VPC, EKS cluster, and core networking
- Runs in parallel with RC apply (no RC dependencies)
- State key: `management-cluster/${management_id}.tfstate`

**Apply 2** (`terraform/config/management-cluster-rc-bind`):

- Creates HyperShift OIDC infrastructure, ZOA resources, kube-applier DynamoDB tables
- Reads RC outputs via SSM parameters (polls with retry)
- Uses the same state file as Apply 1 (single backend configuration)

The factory buildspec shell script runs:

```bash
terraform -chdir=terraform/config/management-cluster apply -var-file=...
# SSM polling happens via data sources in Apply 2 terraform, not shell retry
terraform -chdir=terraform/config/management-cluster-rc-bind apply -var-file=...
```

This avoids `-target` (which is brittle for dependency tracking) and keeps the two phases in separate directories for clear separation of concerns.

#### SSM Parameter Polling Strategy

RC Terraform writes three SSM parameters in the RC account:

- `/hyperfleet/${env}/${region}/rc/oidc-cloudfront-domain` — used by MC Apply 2
- `/hyperfleet/${env}/${region}/rc/api-gateway-invoke-url` — used by Register script
- `/hyperfleet/${env}/${region}/rc/rhobs-api-url` — used by MC ArgoCD bootstrap

MC Apply 2 and MC ArgoCD bootstrap read these via `data "aws_ssm_parameter"` blocks with cross-account IAM role assumption. Terraform's data source retry handles polling (default AWS SDK retry with exponential backoff). No explicit shell-level retry loop. Timeout: Terraform apply timeout (default 60 minutes) covers SSM parameter availability; RC apply completes in ~30-45 minutes, so parameters are available before MC Apply 2 starts in the typical case.

ZOA outputs (`zoa_outputs_bucket_arn`, `zoa_kms_key_arn`, `zoa_lambda_image_uri`) are **convention-based** (constructed from `regional_id` and `rc_account_id`), not read from SSM, to avoid additional polling.

#### Register Script Interface

The Register script runs in the bootstrap orchestrator (not in the factory CodeBuild job) to avoid holding factory execution during Register retries.

**Script**: `scripts/register-mc.sh` (new, extracted from current `scripts/buildspec/register.sh`)

**Interface** (environment variables):

- `RC_API_URL` — from SSM parameter `/hyperfleet/${env}/${region}/rc/api-gateway-invoke-url`
- `MANAGEMENT_ID` — passed to factory, returned from factory execution
- `CLUSTER_ID` — same as `MANAGEMENT_ID` (current convention)
- `TARGET_REGION` — AWS region
- `ALIAS` — from management-cluster configuration
- `CLOUDFRONT_URL` — from MC Apply 2 Terraform output (`hypershift_oidc_cloudfront_domain`)
- `TARGET_ACCOUNT_ID` — MC account ID

**Wait strategy**: Bootstrap polls two conditions before invoking Register:

1. RC ArgoCD completes and Platform API `/live` returns 200
2. MC Apply 2 completes (factory job success)

Both conditions are checked via CodeBuild job status APIs (RC bootstrap job, MC factory job). Bootstrap waits with exponential backoff (max 30 minutes). Register script itself retries POST to Platform API with 10 retries, 30-second intervals.

**Error handling**: If Register fails after retries, bootstrap fails (stops provisioning). Day-2 Register (on MC pipeline git push) retries independently.

### IAM and deletion

- **CIDR:** Hardcoded `10.0.0.0/16` for single MC per account (this ADR scope). Multi-MC CIDR allocation (DynamoDB allocator, slot assignment) is future work tied to MC autoscaling.
- **Factory IAM:** dedicated central role (not `mc-codebuild-role`) — pipeline/CodeBuild CRUD, `iam:PassRole` to those services, `sts:AssumeRole` to child-admin. Shared MC CodeBuild role stays opt-in for **day-2** only (`enable_shared_mc_role`).
- **Destroy environment (ephemeral):** Destroy all MCs (factory with `IS_DESTROY=true`), then RC, then bootstrap resources. Same create-together/destroy-together pattern as today. Selective MC destroy (keeping RC alive) is deferred to future MC autoscaling work.
- **Out of scope:** runtime scaler; minting accounts; ArgoCD in Terraform; shared VPC; unique `management_id` generator (keep `mc01` / `{eph_prefix}-mc01`); selective MC destroy; multi-MC CIDR allocation.

## Implementation plan

Ephemeral first (`initial_count=1`); validate factory works with integration/stage config patterns. `enable_pipeline_provisioner` **defaults to false** (ephemeral uses factory immediately). Existing integration/stage keep `enable_pipeline_provisioner: true` and continue using provisioner (unchanged, no migration). Provisioner code deleted after Phase 4; running provisioner infrastructure remains deployed in existing environments.

1. **Factory + direct RC.** Module-ize RC/MC pipeline configs; `central-account-bootstrap` creates CodeStar, ECR, one RC pipeline per region, factory CodeBuild + role. Pass today’s `management_id` (`mc01` or `{eph_prefix}-mc01`). Generalize IAM off literal `mc01` — shared-role log/S3 wildcards must match ephemeral prefixes (`eph-*-mc01-*`), not only `mc*-apply`. Pipeline-definition state `pipelines/management-${env}-${region}-${management_id}.tfstate`. Image build in bootstrap only if the tag is absent. State buckets once per pool account. Factory invoked once for single MC (pass id, account, apply). Bootstrap Registers when API is live and apply 2 succeeded. Orchestrator waits on apply success, not `{prefix}-mc01-pipe`. Pointer on [pipeline-based-lifecycle.md](pipeline-based-lifecycle.md).
   - **Day-2 must not require a git file named after the MC.** Today CodeStar watches `deploy/.../pipeline-management-cluster-${management_id}-inputs/terraform.json`. That is enough while ids stay `mc01`, but a later unique generator (or scale-out) would otherwise need a commit. Bake `MANAGEMENT_ID` and account on the CodeBuild project; trigger on shared paths (`terraform/config/management-cluster/**`, `terraform/config/management-cluster-rc-bind/**`, shared `config/`). For ephemeral (`initial_count=1`), shared triggers are acceptable (only one MC). Factory-triggered scale-out Registers in the factory job; bootstrap handles Register only at first provision.
2. **Parallel apply.** Direct first `terraform apply`; MC apply 1 ∥ RC apply; apply 2 in the same job; precomputed tfvars; skip image if tagged.
3. **Decouple RC (remove `management_clusters` from RC Terraform).** Breaks coupling between RC and MC git config, enabling future MC autoscaling without RC Terraform changes.
   - Delete `var.management_clusters` / `local.mc_entries` / `local.api_allowed_accounts` from [terraform/config/regional-cluster](../../terraform/config/regional-cluster/main.tf). Stop building `TF_VAR_management_clusters` in [provision-infra-rc.sh](../../scripts/buildspec/provision-infra-rc.sh) and `management_clusters_info` in the RC pipeline JSON template.
   - Seed authz `bootstrap_accounts` from the **account pool** (SSM), plus the RC account — not `id:account` git keys.
   - Drop `management_clusters` from [ecs-bootstrap](../../terraform/modules/ecs-bootstrap/main.tf), the cluster-secret annotation, and [argocd-bootstrap ApplicationSet](../../config/templates/argocd-bootstrap/applicationset.yaml.j2).
   - Grafana CloudWatch datasources and `PrometheusRemoteWriteDown_*` alerts need MC discovery mechanism (Register API query, controller-written ConfigMap, or temporary compatibility annotation with registered IDs). Discovery design TBD when Phase 3 is implemented; not required for Phases 1-2 (ephemeral).
   - `terraform apply -var-file`; SSM/Secrets as data sources.
4. **Delete provisioner code and document migration paths.**
   - Delete `terraform/modules/pipeline-provisioner/`, `scripts/provision-pipelines.sh`, and `enable_pipeline_provisioner` flag from codebase.
   - Running provisioner infrastructure stays deployed in existing integration/stage accounts (orphaned but functional).
   - Update [environment-provisioning.md](../environment-provisioning.md) with factory-based flow.
   - Document two future paths for integration/stage: (A) in-place migration (Terraform state import, switch flag, no infrastructure recreation), (B) fresh creation (preferred, same flow as ephemeral with integration/stage config).
   - Validate factory works with integration/stage config patterns (different account pools, etc.) in ephemeral CI.
   - Run `make pre-push`.

## Future optimizations

**Multi-MC CIDR allocation** — deferred to MC autoscaling work. When multiple MCs run in one AWS account, each needs a non-overlapping VPC CIDR. DynamoDB allocator (`hyperfleet-${env}-${region}-mc-cidr-allocator` table with `account_id` PK, `cidr_slot` SK) provides atomic slot assignment via conditional `PutItem`. Factory allocates `10.{slot}.0.0/16` (slots 0-255 support up to 256 MCs per account). Packs one account before using the next from the pool. `IS_DESTROY` frees the slot for reuse. Ephemeral allocations set TTL to auto-expire after 7 days (orphan cleanup).

**Unique `management_id` generator** — considered, **not implemented** in this ADR. Sequential `mc01` / `mc02` … is enough while `MANAGEMENT_ID` is always supplied by the caller (bootstrap or an operator). Before a scaler creates MCs with runtime-generated IDs — where the factory must pick an id without knowing what already exists in the account — the factory should generate the id when `MANAGEMENT_ID` is unset (destroy and day-2 still receive it).

- Alphabet `^[a-z0-9-]+$`. **Max ~36 characters** so IAM names like `${management_id}-assume-dns-zone-operator` stay under 64 and S3 `${management_id}-artifacts-{8}` under 63.
- Unique part: lowercase [ULID](https://github.com/ulid/spec) (Crockford base32, 26 chars). Not `mc01`/`mc02` — sequential keys collide when two factory invocations independently generate ids for the same account (scaler-driven, not `initial_count`-driven).
- Integration / stage / production: `mc-<ulid>` (e.g. `mc-01k2n8x4q7v9m3b6c0d2e4f5g8`). No env name in the id; accounts already isolate them.
- Ephemeral CI: `{eph_prefix}-mc-<16-char ULID entropy>` (e.g. `eph-3f9a2c-mc-q7v9m3b6c0d2e4f5`). Keep today’s `make_eph_prefix` (`eph-{sha256(BUILD_ID)[:6]}`) so the orchestrator can list `{eph_prefix}-*` pipelines. Drop the ULID time component so length stays ≤36 (CI 30 chars).
- Ephemeral local: same pattern with `eph-{id}` (`--id` as-is, or 8 hex from `uuid4`), e.g. `eph-a1b2c3d4-mc-q7v9m3b6c0d2e4f5` (32 chars). Reject `--id` values that would exceed 36.
- Used as: EKS `cluster_id`, state key `management-cluster/${management_id}.tfstate`, pipeline `${management_id}-pipe`, Register `id`, kube-applier DynamoDB prefix, Grafana role `${management_id}-grafana-cw-logs-reader`. Tag `ephemeral-prefix` when `eph_prefix` is set.

Related: [pipeline-based-lifecycle.md](pipeline-based-lifecycle.md), [regional-account-minting.md](regional-account-minting.md), [environment-provisioning.md](../environment-provisioning.md), [testing-strategy.md](testing-strategy.md), [kube-applier-architecture.md](kube-applier-architecture.md), [regional-oidc-ownership.md](regional-oidc-ownership.md).
