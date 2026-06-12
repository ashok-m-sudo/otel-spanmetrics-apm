# Architecture

This document is a deep dive into how RED metrics are derived from traces inside the OTel Collector. For step-by-step install instructions see [deployment-guide.md](deployment-guide.md); for proving it works see [verification.md](verification.md).

## Component inventory

| Component                       | Role                                                                                                          | Namespace                        |
|---------------------------------|----------------------------------------------------------------------------------------------------------------|----------------------------------|
| cert-manager                    | Issues and rotates the TLS certificates used by the OTel Operator's admission webhook.                          | `cert-manager`                   |
| OpenTelemetry Operator          | Control-plane controller. Watches Deployments for the inject annotation and mutates pod specs; reconciles the Collector and Instrumentation CRs. | `opentelemetry-operator-system`  |
| Instrumentation CRD             | Declarative spec for *how* to instrument a language runtime — exporter endpoint, propagators, sampler.          | `observability`                  |
| OTel Collector (w/ spanmetrics) | Receives OTLP spans once; forwards full traces to Jaeger AND derives RED metrics in-flight via the spanmetrics connector, exposed on `:8889`. | `observability`                  |
| Jaeger all-in-one               | Receives spans (OTLP), stores them in memory, and serves the trace-search UI.                                   | `observability`                  |
| Prometheus                      | Scrapes the collector's `:8889` Prometheus exporter every 5s; stores exemplars (`--enable-feature=exemplar-storage`). | `observability`                  |
| Grafana                         | Renders the RED dashboard from Prometheus; exemplar diamonds deep-link to the source trace in Jaeger.            | `observability`                  |

## The dual-pipeline pattern

Spans flow into the collector **once**, over OTLP, from the auto-instrumented workload. From that single input, the collector config ([manifests/03-otel-collector.yaml](../manifests/03-otel-collector.yaml)) declares **three logical pipelines** that share the same OTLP receiver:

1. **`traces`** — applies `filter/noise` (drops health-check and probe spans) and `batch`, then exports to Jaeger over OTLP/HTTP. This is the visualization pipeline: it keeps *every* span kind — server, client, internal — because a trace waterfall is only useful at full fidelity.
2. **`traces/to_metrics`** — applies `filter/noise` plus an additional `filter/entry_only` processor that keeps **only `SPAN_KIND_SERVER` spans**, then feeds the `spanmetrics` connector. A connector is a collector component that is an *exporter* from one pipeline's perspective and a *receiver* from another's.
3. **`metrics`** — receives the counters and histograms the connector emits, batches them, and exposes them on the Prometheus exporter at `:8889`.

Why two trace-side pipelines instead of one with a fan-out at the exporter? **Different processor chains.** The Jaeger side must keep client and internal spans — they are the trace. The metrics side must strip them: when `api-gateway` proxies a request to `backend-service`, the SDKs emit a client span (gateway's outbound call) *and* a server span (backend's inbound handling) for the same request. Counting both would double the rate metric. Filtering to server spans gives exactly **one RED observation per inbound request per service** — correct semantics and bounded cardinality.

```
                          ┌──────────────────────────────────────────────┐
                          │            OTel Collector                    │
  workload ── OTLP ──────▶│ receiver:otlp ──┬─▶ [noise][batch] ─▶ Jaeger │
                          │                 └─▶ [noise][server-only]     │
                          │                        │                     │
                          │                  spanmetrics connector       │
                          │                        │                     │
                          │                  [batch] ─▶ prometheus :8889 │──▶ scraped by Prometheus
                          └──────────────────────────────────────────────┘
```

## The SpanMetrics Connector explained

The connector block in [manifests/03-otel-collector.yaml](../manifests/03-otel-collector.yaml) makes three decisions worth understanding:

**Histogram buckets** — `[2ms, 10ms, 50ms, 100ms, 200ms, 500ms, 1s, 5s]`. Prometheus computes percentiles with `histogram_quantile()`, which interpolates *within* bucket boundaries — it can never be more precise than the buckets you declare. These boundaries bracket the latencies a small Express stack actually produces (single-digit ms locally, hundreds of ms under load, seconds when something is wrong). If your workload has a longer tail, widen the top buckets; a p99 beyond your last boundary collapses to that boundary and lies to you.

**Dimensions** — `http.method`, `http.status_code`, `otel.library.name`. Each dimension becomes a Prometheus **label**, and labels multiply: time-series count = services × methods × status codes × library names. These three are low-cardinality and analytically useful (errors-by-status, traffic-by-method). The anti-pattern to avoid: never dimension on user IDs, trace IDs, session tokens, or full URL paths containing IDs — each unique value mints a new time series, and Prometheus memory grows linearly with series count until it doesn't.

**Exemplars** — `enabled: true`. Each histogram data point carries a sampled **trace ID** alongside the aggregate value. Prometheus stores these (it needs `--enable-feature=exemplar-storage`, which [manifests/07-prometheus.yaml](../manifests/07-prometheus.yaml) sets), and Grafana renders them as diamonds on the latency panel. Click one and you jump from "p99 spiked at 14:32" straight to *an actual trace from that spike* in Jaeger. This is the closing-the-loop superpower: the metric tells you something is wrong, the exemplar hands you the evidence.

## Generated metrics

After deployment, verify the exact names with `curl localhost:8889/metrics` (port-forward first) — connector versions have shifted naming over time. With the current contrib image expect:

- **`traces_span_metrics_calls_total`** — a counter labelled by `service_name` plus the configured dimensions. `rate()` over it is your **R**equest rate; filtered by `http_status_code=~"[45].."` it is your **E**rror rate.
- **`traces_span_metrics_duration_milliseconds_bucket` / `_sum` / `_count`** — the latency histogram. `histogram_quantile()` over the `_bucket` series gives your **D**uration percentiles.

The dashboard in [dashboards/red-metrics.json](../dashboards/red-metrics.json) queries exactly these names — if your collector emits different ones, adjust the dashboard's PromQL before importing.

## Why we keep Jaeger

It would be tempting to call the metrics pipeline "the upgrade" and drop the tracing backend. Don't. Metrics and traces answer different questions: a RED metric is the **symptom** — aggregate, cheap to store, perfect for alerting ("p99 latency doubled at 14:32"). A trace is the **cause** — a single request's full story across services, expensive per-unit but irreplaceable for diagnosis ("because auth-service's `/auth/verify` call stalled for 1.8s"). Together they form the alert-to-root-cause loop, and exemplars are the one-click handoff between them: alert fires on the metric, exemplar links to the trace, trace names the guilty span.

## Limitations

Honesty section — what trace-derived metrics do *not* give you:

- **Sampling bias.** The connector only counts spans that reach it. With head-based sampling below 100% (the Instrumentation CR here uses `parentbased_traceidratio` at `1.0`, so all of it arrives), your "rate" counter is systematically undercounted by the sampling ratio. Either keep 100% sampling (fine for small-traffic demo services), scale the numbers mentally, or derive authoritative rate from a source that sees every request (load balancer logs, a counter at the edge).
- **Cardinality drift.** Series count isn't static: every new HTTP route, status code, or service that appears in production mints new time series. What is bounded today grows over quarters. Set a Prometheus alert on series count (`prometheus_tsdb_symbol_table_size_bytes` or `count({__name__=~"traces_span_metrics.*"})`) so growth is a ticket, not an outage.
- **Span-deep only.** The connector's metrics are exactly as detailed as the spans feeding it. Zero-code auto-instrumentation emits HTTP server/client spans — so you get request-level RED, not internal-function latencies, queue depths, or business counters. Those still need deliberate instrumentation; this pipeline removes the *duplicate* HTTP bookkeeping, not all metrics work forever.
