# Troubleshooting

Common failure modes when standing up the spanmetrics pipeline, with the underlying cause and the fix. Each entry follows **symptom → cause → fix**. For injection-side problems (operator not Ready, no init container, disconnected traces, `unknown_service` in Jaeger) see also the [troubleshooting doc in otel-zero-code-instrumentation-k8s](https://github.com/ashok-m-sudo/otel-zero-code-instrumentation-k8s/blob/main/docs/troubleshooting.md) — this doc focuses on the metrics pipeline.

## 1. Collector pod CrashLoopBackOff after applying the config

**Symptom:** `kubectl get pods -n observability` shows the `central-otel-collector` pod restarting; it was fine before this repo's config.

**Cause:** Either the `connectors:` block is malformed (a connector referenced in `service.pipelines` but not declared, or vice versa), **or** the image in use is the *core* collector distribution, which does not ship the spanmetrics connector — only `opentelemetry-collector-contrib` does.

**Fix:** Read the actual error first:

```bash
kubectl logs -n observability deploy/central-otel-collector --previous --tail=50
```

A YAML/config error names the offending key. Confirm the image is contrib:

```bash
kubectl get opentelemetrycollector central-otel -n observability \
  -o jsonpath='{.spec.image}' ; echo
# must contain: opentelemetry-collector-contrib
```

Also confirm `spanmetrics` appears in three places in [manifests/03-otel-collector.yaml](../manifests/03-otel-collector.yaml): under `connectors:`, as an *exporter* of `traces/to_metrics`, and as a *receiver* of `metrics`.

## 2. `:8889/metrics` returns 404 or connection refused

**Symptom:** `kubectl port-forward svc/central-otel-collector 8889:8889` fails ("port not found") or curl can't connect.

**Cause:** The Prometheus exporter port isn't exposed on the operator-generated Service. The operator auto-exposes **receiver** ports (4317/4318) by parsing the config, but **not exporter ports** — they must be listed explicitly in `spec.ports`.

**Fix:** Confirm the CR carries the port and that it propagated to the Service:

```bash
kubectl get opentelemetrycollector central-otel -n observability -o jsonpath='{.spec.ports}' ; echo
kubectl get svc central-otel-collector -n observability -o jsonpath='{.spec.ports[*].port}' ; echo
# expect 8889 in both
```

If missing, re-apply `manifests/03-otel-collector.yaml` (it includes the `ports:` block) and let the operator reconcile.

## 3. Prometheus target shows DOWN

**Symptom:** Prometheus **Status → Targets** lists `otel-collector` as `DOWN` with a connection error.

**Cause:** The scrape config targets a pod IP (stale after a collector restart) or a wrong/short DNS name instead of the stable Service DNS.

**Fix:** The scrape target must be the full Service DNS:

```bash
kubectl get configmap prometheus-config -n observability -o yaml | grep targets -A1
# - targets: ['central-otel-collector.observability.svc.cluster.local:8889']
```

After editing the ConfigMap, restart Prometheus so it reloads (`kubectl rollout restart deployment/prometheus -n observability`). Also sanity-check connectivity from inside the cluster:

```bash
kubectl run -n observability curl-test --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s central-otel-collector.observability.svc.cluster.local:8889/metrics | head -5
```

## 4. Metrics flowing but every service is `unknown_service`

**Symptom:** `curl :8889/metrics` shows series, but `service_name="unknown_service:node"` instead of `api-gateway` etc. The dashboard's service variable lists one useless value.

**Cause:** `OTEL_SERVICE_NAME` wasn't derived. The operator normally infers it from the pod's `app.kubernetes.io/name` label; this workload labels pods with `app: <name>`, so inference can fail depending on operator version.

**Fix:** Either add the conventional label to each Deployment's pod template, or set the name deterministically in the `Instrumentation` CR via the downward API:

```yaml
spec:
  env:
    - name: OTEL_SERVICE_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.labels['app']
```

Re-apply the CR and restart the workload deployments. Stale `unknown_service` series age out of the dashboard as their data leaves the query window.

## 5. Latency histograms render flat / percentiles look pinned

**Symptom:** The latency panel draws p50/p95/p99 as flat lines, often all at the same value or pinned to a bucket boundary like 5s or 2ms.

**Cause:** The histogram bucket boundaries don't bracket your actual latencies. `histogram_quantile` interpolates within buckets — if all observations land in the first (or last) bucket, every percentile collapses to that boundary.

**Fix:** Compare the configured buckets against reality:

```bash
curl -s localhost:8889/metrics | grep duration_milliseconds | grep -E '_(sum|count)'
# average latency = _sum / _count -- check where it falls in [2ms..5s]
```

Then widen or re-center the `buckets:` list in [manifests/03-otel-collector.yaml](../manifests/03-otel-collector.yaml) and re-apply. New boundaries only affect new data points.

## 6. Error-rate panel blank despite 4xx traffic

**Symptom:** Request-rate panel works; error-rate panel shows "No data" even after the 4xx burst from [verification.md](verification.md).

**Cause:** Label-name mismatch. Newer OTel SDKs follow current semantic conventions and emit `http_response_status_code`; older ones emit `http_status_code`. The dashboard queries one; your spans carry the other.

**Fix:** Inspect the real label set:

```bash
curl -s localhost:8889/metrics | grep calls_total | head -3
```

Then edit the error-rate panel's PromQL in Grafana (or in [dashboards/red-metrics.json](../dashboards/red-metrics.json) and re-import), replacing `http_status_code` with whatever the output shows. If the dimension is missing entirely, also check the `dimensions:` list in the connector config matches the span attribute name your SDK emits.

## 7. Grafana can't reach Prometheus ("HTTP Error Bad Gateway" on Save & test)

**Symptom:** Adding the Prometheus datasource fails, or panels show connection errors.

**Cause:** The datasource URL is `http://localhost:9090` — which resolves to the *Grafana pod itself* (or your laptop, in browser-access modes), not Prometheus.

**Fix:** Use the in-cluster Service DNS in the datasource settings:

```
http://prometheus.observability.svc.cluster.local:9090
```

## 8. Exemplars not visible / not clickable

**Symptom:** No diamond markers on the latency panel, or diamonds appear but offer no "View trace" link.

**Cause:** Exemplars require three switches, and any one missing breaks the chain: (a) `exemplars.enabled` in the spanmetrics connector, (b) `--enable-feature=exemplar-storage` on Prometheus, (c) the **Exemplars** toggle in Grafana's Prometheus datasource settings, configured with an internal link to a Jaeger datasource.

**Fix:** Verify each in order:

```bash
kubectl get opentelemetrycollector central-otel -n observability -o yaml | grep -B1 -A2 exemplars
kubectl get deploy prometheus -n observability -o jsonpath='{.spec.template.spec.containers[0].args}' ; echo
```

Then in Grafana: *Data sources → Prometheus → Exemplars → enable*, set the label to `trace_id`, and point the internal link at a Jaeger datasource (`http://jaeger-query.observability.svc.cluster.local:16686`). Re-run the traffic loop — exemplars are sampled, so a handful of requests may not produce one.
