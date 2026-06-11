#!/usr/bin/env bash
set -euo pipefail

# Installs the OpenTelemetry Operator. The operator watches Deployments for the
# `instrumentation.opentelemetry.io/inject-nodejs` annotation and mutates pod
# specs to add the auto-instrumentation init container + SDK env vars.
#
# It also reconciles OpenTelemetryCollector and Instrumentation custom resources.
#
# NOTE: cert-manager MUST be installed and Ready first (see 01-install-cert-manager.sh).

echo "Installing the OpenTelemetry Operator (latest release)..."
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml

echo "Waiting for the OTel Operator deployment to become Available..."
# The operator lands in the opentelemetry-operator-system namespace and the
# controller deployment is named opentelemetry-operator-controller-manager.
kubectl wait --for=condition=Available \
  deployment/opentelemetry-operator-controller-manager \
  -n opentelemetry-operator-system \
  --timeout=180s

echo "OpenTelemetry Operator is ready."
