# Verification

This document proves the pipeline end to end: spans leave the workload once, and both signals arrive — full traces in Jaeger, RED metrics in Prometheus/Grafana. The metrics you are about to see were never emitted by a metrics SDK; every data point started life as a span.

## 1. Confirm spanmetrics is exposed

Port-forward the collector's Prometheus exporter port and look for the connector's counters:

```bash
kubectl port-forward -n observability svc/central-otel-collector 8889:8889
curl -s localhost:8889/metrics | grep -i calls_total | head -20
```

You should see lines like:

```
traces_span_metrics_calls_total{service_name="api-gateway",http_method="GET",http_status_code="200",...} 42
```

> **Record the exact metric names you see.** Connector versions have shifted naming over time (`calls_total` vs `traces_span_metrics_calls_total`, label `http_status_code` vs `http_response_status_code`). The dashboard JSON in this repo queries `traces_span_metrics_calls_total` / `traces_span_metrics_duration_milliseconds_bucket` with label `http_status_code` — if your output differs, update the PromQL in [dashboards/red-metrics.json](../dashboards/red-metrics.json) to match **before** importing.

If the curl shows nothing yet, that's expected — no traffic has flowed. Continue to step 2 and re-check.

## 2. Generate sample traffic

Port-forward the gateway:

```bash
kubectl port-forward -n microservices svc/api-gateway 3000:3000 &
```

The workload's real routes are authenticated, so drive the full flow: register, log in, then call the backend with the token. The backend call is the interesting one — it traverses `api-gateway → backend-service → auth-service` (the backend verifies the token against auth), producing server spans (and therefore RED observations) for **all three services** from a single request.

```bash
# One-time: register a demo user (409 on re-run is fine)
curl -s -X POST http://localhost:3000/api/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"demo","password":"demo-pass","email":"demo@example.com"}'

# Log in and capture the JWT
TOKEN=$(curl -s -X POST http://localhost:3000/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"demo","password":"demo-pass"}' | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')

# Steady 2xx traffic: 50 authenticated backend reads
for i in {1..50}; do
  curl -s http://localhost:3000/api/backend/data \
    -H "Authorization: Bearer $TOKEN" -o /dev/null -w "%{http_code}\n"
done

# Deliberate 4xx burst for the error-rate panel: nonexistent route + missing token
for i in {1..10}; do
  curl -s http://localhost:3000/nope -o /dev/null -w "%{http_code}\n"
  curl -s http://localhost:3000/api/backend/data -o /dev/null -w "%{http_code}\n"
done
```

Expect `200`s from the authenticated loop, then `404`s and `401`s from the error burst.

> Note: bare `GET /api/auth` or `GET /api/backend` are **not** real endpoints in this workload (auth routes are POST-only; backend requires a Bearer token) — hitting them yields 404/401, which is useful for the error panel but not for healthy-traffic rates. The loops above use the actual API.

## 3. Confirm Prometheus is scraping

```bash
kubectl port-forward -n observability svc/prometheus 9090:9090
```

Open **http://localhost:9090**, navigate to **Status → Targets**: the `otel-collector` job must show **UP**. Then try a query in the expression browser:

```promql
sum by (service_name) (rate(traces_span_metrics_calls_total[1m]))
```

Three series — `api-gateway`, `auth-service`, `backend-service` — with non-zero rates.

## 4. Open the dashboard in Grafana

```bash
kubectl port-forward -n observability svc/grafana 3001:3000
```

Open **http://localhost:3001**, log in, and open the imported **RED Metrics — Trace-Derived (spanmetrics)** dashboard. Verify:

- **Request rate** — non-zero rates for all three services. `backend-service` and `auth-service` show traffic even though you only ever curled the gateway: the gateway's proxying and the backend's token-verification call produce server spans on the downstream services, each counted once.
- **Error rate** — a visible spike from the 4xx burst in step 2.
- **Latency percentiles** — p50/p95/p99 lines render for each selected service.

![RED dashboard](../images/grafana-red-dashboard.png)

> **Screenshot TODO:** drop a capture of the populated dashboard into `images/grafana-red-dashboard.png` so this renders.

## 5. Closing the loop via exemplars (stretch)

On the latency panel, look for small **diamond markers** near the percentile lines — these are exemplars, each carrying the trace ID of a real request from that bucket. For them to appear and be clickable you need all three of:

1. `exemplars.enabled: true` in the spanmetrics connector (this repo's collector config has it),
2. `--enable-feature=exemplar-storage` on Prometheus (this repo's manifest has it),
3. **Exemplars** toggled on in Grafana's Prometheus datasource settings, with an internal link pointing at a Jaeger datasource (add Jaeger as a datasource — `http://jaeger-query.observability.svc.cluster.local:16686` — to enable the "View trace" deep link).

Click a diamond → **View trace** → you land on the exact trace whose duration contributed to that histogram bucket. Metric symptom to trace cause, one click.

## 6. Acceptance checklist

- [ ] `curl :8889/metrics` shows spanmetrics counters with `service_name` labels for all three services (`api-gateway`, `auth-service`, `backend-service`).
- [ ] Prometheus **Status → Targets** shows the `otel-collector` job **UP**.
- [ ] The Grafana dashboard renders all three RED panels with data for `api-gateway` at minimum.
- [ ] Jaeger UI (`kubectl port-forward -n observability svc/jaeger-query 16686:16686`) still shows the source traces — proving both pipelines work from the same OTLP input.
