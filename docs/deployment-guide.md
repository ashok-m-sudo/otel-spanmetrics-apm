# Deployment guide

Follow these steps in order. They assume the sample workload from
[node-microservice-template](https://github.com/ashok-m-sudo/node-microservice-template)
is already deployed to the `microservices` namespace
(Deployments: `api-gateway`, `auth-service`, `backend-service`).

All commands are run from the root of this repository. Once everything is up,
head to [verification.md](verification.md) to prove that RED metrics derived
from spans are flowing into Grafana.

## 1. Create the observability namespace

All observability infrastructure (collector, Jaeger, Prometheus, Grafana, the Instrumentation CR) lives in a dedicated `observability` namespace.

```bash
kubectl apply -f manifests/00-namespace.yaml
```

## 2. Install cert-manager

The OTel Operator's mutating admission webhook is served over TLS. cert-manager issues and rotates those certificates; without it the operator never becomes Ready and no injection happens.

```bash
bash manifests/01-install-cert-manager.sh
```

Verify all cert-manager pods are Running:

```bash
kubectl get pods -n cert-manager
```

## 3. Install the OpenTelemetry Operator

The operator watches Deployments, injects the auto-instrumentation init container, and reconciles the Collector and Instrumentation custom resources.

```bash
bash manifests/02-install-otel-operator.sh
```

Verify the operator is Running:

```bash
kubectl get pods -n opentelemetry-operator-system
```

## 4. Deploy Jaeger v2 all-in-one

Jaeger receives the full-fidelity trace stream and serves the trace-search UI. Note: Jaeger is for *viewing source traces* (and exemplar deep-links) — the metrics pipeline itself does not require it, so a Jaeger outage never blanks your dashboards.

```bash
kubectl apply -f manifests/04-jaeger-all-in-one.yaml
```

Verify:

```bash
kubectl get pods,svc -n observability -l app=jaeger
```

## 5. Deploy the OTel Collector

The hero step. This `OpenTelemetryCollector` CR declares three pipelines sharing one OTLP receiver: traces → Jaeger, traces → spanmetrics connector (server spans only), and metrics → Prometheus exporter on `:8889`. The `spec.ports` entry exposing 8889 matters — the operator auto-exposes receiver ports but not exporter ports.

```bash
kubectl apply -f manifests/03-otel-collector.yaml
```

Verify the operator generated the workload and that the service exposes both 4317/4318 (OTLP) and 8889 (Prometheus exporter):

```bash
kubectl get opentelemetrycollector,deploy -n observability
kubectl get svc central-otel-collector -n observability -o wide
```

## 6. Deploy Prometheus

A minimal Prometheus that scrapes the collector's `:8889` endpoint every 5 seconds. The `--enable-feature=exemplar-storage` flag lets it retain the trace-ID exemplars the spanmetrics connector attaches — required for metric → trace deep links.

```bash
kubectl apply -f manifests/07-prometheus.yaml
```

Verify:

```bash
kubectl get pods,svc -n observability -l app=prometheus
```

## 7. Deploy Grafana

```bash
kubectl apply -f manifests/08-grafana.yaml
```

Once the pod is Ready, port-forward and log in (default `admin` / `admin` — change it on first login; the password is set via a plain env var for demo purposes only):

```bash
kubectl port-forward -n observability svc/grafana 3001:3000
# open http://localhost:3001
```

Then, in the Grafana UI:

1. **Add the Prometheus datasource** — *Connections → Data sources → Add data source → Prometheus*, URL: `http://prometheus.observability.svc.cluster.local:9090`. Save & test.
2. **Import the RED dashboard** — *Dashboards → New → Import → Upload JSON file*, select [`dashboards/red-metrics.json`](../dashboards/red-metrics.json), and bind it to the Prometheus datasource you just created.

## 8. Create the Instrumentation CR

Declares how Node.js workloads are instrumented: exporter endpoint (the collector's OTLP service), propagators, and 100% sampling — which also means the derived rate metrics count *every* request, not a sample.

```bash
kubectl apply -f manifests/05-instrumentation.yaml
```

Verify:

```bash
kubectl get instrumentation -n observability
```

## 9. Annotate the workload deployments

The zero-code step: patch each Deployment's pod template with the inject annotation; the operator's webhook injects the auto-instrumentation init container as the pods roll.

```bash
bash manifests/06-annotate-workloads.sh
```

Watch the rollouts complete:

```bash
kubectl rollout status deployment/api-gateway -n microservices
kubectl rollout status deployment/auth-service -n microservices
kubectl rollout status deployment/backend-service -n microservices
```

## 10. Verify

Proceed to **[verification.md](verification.md)** to generate traffic and confirm span-derived RED metrics light up the Grafana dashboard — and that the same spans still appear as full traces in Jaeger.
