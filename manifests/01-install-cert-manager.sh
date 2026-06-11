#!/usr/bin/env bash
set -euo pipefail

# cert-manager provisions the TLS certificates that the OpenTelemetry Operator's
# admission/mutating webhook requires. Without it, the operator pod will not
# become Ready and pod injection will never happen.

CERT_MANAGER_VERSION="v1.16.1"

echo "Installing cert-manager ${CERT_MANAGER_VERSION}..."
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

echo "Waiting for cert-manager pods to be ready..."
kubectl wait --for=condition=Ready pods --all -n cert-manager --timeout=180s

echo "cert-manager is ready."
