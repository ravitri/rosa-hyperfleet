# Alerting Architecture: Fan-Out Alert Routing

## Overview

This document describes the alerting architecture for the ROSA Regional Platform. The system routes Prometheus alerts from AlertManager to multiple receivers with selective, label-based filtering. The design is split into two phases:

- **Phase 1**: Native AlertManager routing with `continue`-based fan-out
- **Phase 2**: SNS fan-out for decoupled, durable alert distribution using AlertManager's native SNS receiver

## Phase 1: Native AlertManager Routing

### Design

AlertManager's built-in route tree supports fan-out via the `continue: true` directive. When a route matches and `continue` is set, AlertManager keeps evaluating subsequent sibling routes — allowing a single alert to reach multiple receivers.

Selective routing is handled by matching on alert labels (e.g., `severity`, `team`, `component`).

```mermaid
flowchart LR
    P[Prometheus] --> AM[AlertManager]
    AM -->|"severity=warning|critical"| PD[PagerDuty]
    AM -->|team=platform| WH[Custom Webhook]
```

### Example AlertManager Configuration

```yaml
global:
  resolve_timeout: 5m

route:
  receiver: default
  group_by: ["alertname", "namespace"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    # Warning and critical alerts → PagerDuty
    - match_re:
        severity: "warning|critical"
      receiver: pagerduty
      continue: true # continue evaluating sibling routes

    # Platform team alerts → custom webhook handler
    - match:
        team: platform
      receiver: platform-webhook
      continue: true

receivers:
  - name: default
    # fallback — no-op or a generic Slack channel

  - name: pagerduty
    pagerduty_configs:
      - routing_key_file: /etc/alertmanager/secrets/pagerduty-integration-key/integration_key
        severity: "{{ if .CommonLabels.severity }}{{ .CommonLabels.severity }}{{ else }}critical{{ end }}"
        send_resolved: true

  - name: platform-webhook
    webhook_configs:
      - url: "http://platform-alert-handler.alerting.svc.cluster.local:8080/alerts"
        send_resolved: true
```

> **Note:** The PagerDuty receiver uses `routing_key_file` (Events API v2) rather than `service_key_file` (v1). The `severity` field dynamically maps the alert's `severity` label to the PagerDuty event severity, defaulting to `critical` if no label is present. This requires `tplConfig: true` in the kube-prometheus-stack Alertmanager values to enable Go template rendering in the config.

### How Routing Works

1. An alert fires with labels like `severity=warning, team=platform, alertname=HighErrorRate`.
2. AlertManager evaluates routes top-to-bottom:
   - Matches `severity: warning` (via `match_re`) → sends to PagerDuty with severity=warning. `continue: true` → keeps evaluating.
   - Matches `team: platform` → sends to platform webhook.
3. Result: the single alert reaches two receivers.

An alert with `severity=info, team=storage` would skip PagerDuty and skip the platform webhook, falling through to the default receiver.

### Adding a New Receiver

1. Add a new `receiver` entry in the AlertManager config.
2. Add a new `route` entry with the appropriate label matchers and `continue: true` if further fan-out is needed.
3. Reload AlertManager (config reload or pod restart).

### Limitations

- **Coupling**: Every new receiver requires an AlertManager config change and reload.
- **Availability**: If a webhook receiver is down, AlertManager retries with exponential backoff, but has limited buffering. Extended outages can cause alert loss.
- **Blast radius**: A misconfigured route change can break routing for all alerts.
- **Scale**: Works well for a handful of receivers. Beyond ~10 receivers with complex routing logic, the config becomes difficult to maintain.

## Phase 2: SNS Fan-Out (Extension of Phase 1)

### Design

Phase 2 extends Phase 1 by adding an SNS fan-out path alongside the existing AlertManager routes. The Phase 1 PagerDuty route remains in place — it continues to receive critical alerts directly from AlertManager with no additional latency or dependencies. A new route using AlertManager's native `sns_configs` receiver publishes all alerts to an SNS topic that fans out to subscribers.

This approach uses AlertManager's built-in SNS receiver with SigV4 authentication via EKS Pod Identity — no intermediate webhook bridge service is needed.

```mermaid
flowchart LR
    P[Prometheus] --> AM[AlertManager]
    AM -->|"severity=warning|critical"| PD[PagerDuty]
    AM -->|continue| SNS[SNS Topic]
    SNS --> Sub1[Subscriber 1]
    SNS --> Sub2[Subscriber 2]
    SNS --> SubN[Subscriber N...]
```

### Components

#### AlertManager SNS Receiver

AlertManager natively supports publishing to SNS topics via the `sns_configs` receiver (available since v0.22). The receiver authenticates using SigV4, which picks up IAM credentials from EKS Pod Identity automatically.

```yaml
route:
  receiver: default
  group_by: ["alertname", "namespace"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    # Phase 1 — Warning and critical alerts → PagerDuty
    - match_re:
        severity: "warning|critical"
      receiver: pagerduty
      continue: true

    # Phase 2 — All alerts → SNS fan-out
    - receiver: sns-alerts
      continue: true

receivers:
  - name: default

  - name: pagerduty
    pagerduty_configs:
      - routing_key_file: /etc/alertmanager/secrets/pagerduty-integration-key/integration_key
        severity: "{{ if .CommonLabels.severity }}{{ .CommonLabels.severity }}{{ else }}critical{{ end }}"
        send_resolved: true

  - name: sns-alerts
    sns_configs:
      - topic_arn: "arn:aws:sns:<region>:<account-id>:<regional-id>-alerts"
        sigv4:
          region: "<region>"
        send_resolved: true
```

#### SNS Topic

A single SNS topic (`<regional-id>-alerts`) receives all alerts. No routing logic lives here — SNS just fans out to all subscriptions, with each subscription's filter policy controlling what it receives.

#### Subscribers

Any number of subscribers can be added to the SNS topic. SNS natively supports multiple subscription protocols — subscribers are not limited to SQS queues. Options include:

- **SQS** — durable queue with retry and DLQ support, ideal for asynchronous processing
- **Lambda** — direct invocation for lightweight, event-driven consumers
- **HTTPS** — push to an external endpoint (e.g., a third-party webhook)
- **Email/SMS** — for human notification paths

Each subscription can include a [filter policy](https://docs.aws.amazon.com/sns/latest/dg/sns-subscription-filter-policies.html) to selectively receive alerts based on message attributes. Subscribers without a filter policy receive all alerts.

> **Note:** PagerDuty is _not_ an SNS subscriber — it receives warning and critical alerts directly from AlertManager via the Phase 1 route. This avoids adding latency or an SNS dependency to the paging path.

Subscribers are fully independent — deployed, scaled, and owned by different teams if needed.

### Terraform Sketch

```hcl
resource "aws_sns_topic" "alerts" {
  name = "rrp-alerts"
}

# Example: SQS subscriber with filter policy
resource "aws_sqs_queue" "example_alerts" {
  name = "rrp-alerts-example"
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.example_alerts_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue" "example_alerts_dlq" {
  name = "rrp-alerts-example-dlq"
}

resource "aws_sns_topic_subscription" "example_sqs" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.example_alerts.arn
  filter_policy = jsonencode({
    team = ["platform"]
  })
}

# Example: Lambda subscriber (no filter — receives all alerts)
resource "aws_sns_topic_subscription" "example_lambda" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.alert_handler.arn
}
```

### Adding a New Subscriber (Phase 2)

1. Subscribe to the SNS topic using the appropriate protocol (SQS, Lambda, HTTPS, etc.) with an optional filter policy.
2. If using SQS, create the queue + DLQ (Terraform).
3. Deploy the subscriber.

No AlertManager changes required. New subscribers are fully decoupled via the SNS topic.

### What Phase 2 Adds Over Phase 1

| Concern                   | Phase 1 only                                         | Phase 2 (Phase 1 + SNS)                                                          |
| ------------------------- | ---------------------------------------------------- | -------------------------------------------------------------------------------- |
| PagerDuty path            | Direct AlertManager → PagerDuty (warning + critical) | Unchanged — same direct path                                                     |
| New subscriber onboarding | Config change + AlertManager reload                  | Subscribe to SNS topic + deploy (no AlertManager change)                         |
| Durability                | Limited retry/buffering                              | Depends on protocol — SQS provides retention + DLQ; Lambda retries automatically |
| Coupling                  | All receivers in one config                          | Only PagerDuty in AlertManager; all others decoupled via SNS                     |
| Filtering                 | AlertManager label matching                          | SNS subscription filter policies                                                 |
| Cross-account/region      | Difficult                                            | Native SNS/SQS cross-account support                                             |
| Observability             | AlertManager metrics                                 | AlertManager metrics + CloudWatch metrics per subscriber                         |
| Additional infrastructure | None                                                 | SNS topic, IAM role for Alertmanager                                             |

### Failure Modes

- **SNS publish fails**: AlertManager retries with exponential backoff. Alerts are delayed but not lost within AlertManager's retry window.
- **Subscriber is down**: Out of scope. Once an alert is published to the SNS topic, delivery to subscribers is the responsibility of SNS and the subscriber. The platform's obligation ends at successful SNS publish.

## Cross-Cluster Alert Evaluation via Thanos Ruler

### Problem

RC Prometheus only sees its own local TSDB. Metrics from Management Clusters are ingested by Thanos Receive via `remote_write` and are only queryable through Thanos Query. This means RC Prometheus cannot evaluate alerting rules that reference MC metrics — such as HCP availability SLAs derived from HostedCluster status conditions.

### Solution

Thanos Ruler evaluates all PrometheusRule CRs on the cluster against Thanos Query (which has both RC and MC metrics) and sends firing alerts to the RC AlertManager. This makes Thanos Ruler the single evaluation point for all rules, eliminating the risk of duplicate evaluation between RC Prometheus and Thanos Ruler.

To avoid duplicates, the kube-prometheus-stack `defaultRules.create` is set to `false` on the RC. The defaults are audited and re-added as explicit PrometheusRule CRs under ROSAENG-1159.

```mermaid
flowchart LR
    MC1[MC Prometheus] -->|remote_write| TR[Thanos Receive]
    MC2[MC Prometheus] -->|remote_write| TR
    TR --> TQ[Thanos Query]
    TS[Thanos Store / S3] --> TQ
    TRuler[Thanos Ruler] -->|queries| TQ
    TRuler -->|fires alerts| AM[AlertManager]
    AM -->|"severity=warning|critical"| PD[PagerDuty]
    AM -->|continue| SNS[SNS Topic]
```

### Rule Deployment

Platform alerting rules are deployed as PrometheusRule CRs via the `alerting-rules` Helm chart (`argocd/config/regional-cluster/alerting-rules/`). The thanos-operator's `prometheus-rule` feature gate enables PrometheusRule CR support, but discovery requires specific labels: `app.kubernetes.io/name: alerting-rules` (matched by the ThanosRuler `ruleConfigSelector`) and `operator.thanos.io/prometheus-rule: "true"` (the operator's default label, always merged into the selector). Both must be present on any PrometheusRule CR deployed via the `alerting-rules` chart.

See [Adding Alerting Rules](../adding-alerting-rules.md) for a developer guide on creating new rules.

### Alert Patterns and Current Rules

SLA alerts use multi-window, multi-burn-rate alerting from the [Google SRE Workbook](https://sre.google/workbook/alerting-on-slos/). See `argocd/config/regional-cluster/alerting-rules/templates/` for current alert definitions and [Adding Alerting Rules](../adding-alerting-rules.md) for the developer guide.

## Open Questions

- [ ] Do we need cross-region alert replication, or is per-region alerting sufficient given regional independence?
