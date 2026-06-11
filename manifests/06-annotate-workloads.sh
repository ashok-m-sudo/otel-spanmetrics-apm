#!/usr/bin/env bash
set -euo pipefail

# Enables zero-code auto-instrumentation on the existing workload by patching the
# pod template of each Deployment with the inject-nodejs annotation. The OTel
# Operator's mutating webhook picks this up and injects the auto-instrumentation
# init container into every new pod.
#
# The annotation VALUE is "<namespace>/<instrumentation-name>", pointing at the
# Instrumentation CR created by 05-instrumentation.yaml, which lives in the
# observability namespace -- hence "observability/node-instrumentation".
#
# Patching the pod template triggers a rolling restart, so existing pods are
# replaced with instrumented ones automatically.
#
# Deployment names and namespace verified against the node-microservice-template
# workload (k8s/ manifests).

WORKLOAD_NS="microservices"
DEPLOYMENTS=("api-gateway" "auth-service" "backend-service")

for d in "${DEPLOYMENTS[@]}"; do
  echo "Annotating $d in $WORKLOAD_NS..."
  kubectl patch deployment "$d" -n "$WORKLOAD_NS" --type='merge' \
    -p '{"spec":{"template":{"metadata":{"annotations":{"instrumentation.opentelemetry.io/inject-nodejs":"observability/node-instrumentation"}}}}}'
done

echo "Annotation complete. Pods will restart automatically to receive the init container."
