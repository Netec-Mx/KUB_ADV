#!/usr/bin/env bash
set -euo pipefail

PIPELINES_VERSION="${PIPELINES_VERSION:-v1.15.0}"
TRIGGERS_VERSION="${TRIGGERS_VERSION:-v0.37.0}"

PIPELINES_MANIFEST="https://infra.tekton.dev/tekton-releases/pipeline/previous/${PIPELINES_VERSION}/release.yaml"
TRIGGERS_MANIFEST="https://github.com/tektoncd/triggers/releases/download/${TRIGGERS_VERSION}/release.yaml"
INTERCEPTORS_MANIFEST="https://github.com/tektoncd/triggers/releases/download/${TRIGGERS_VERSION}/interceptors.yaml"

kubectl apply -f "$PIPELINES_MANIFEST"

# Todos los nodos del laboratorio tienen taints. Los controladores y los
# PipelineRuns requieren esta toleration para poder programarse.
patch_deployments() {
  local namespace="$1"
  local deployment
  for deployment in $(kubectl get deployment -n "$namespace" -o name 2>/dev/null); do
    kubectl patch "$deployment" -n "$namespace" --type=merge \
      -p '{"spec":{"template":{"spec":{"tolerations":[{"operator":"Exists"}]}}}}'
  done
}

patch_deployments tekton-pipelines
patch_deployments tekton-pipelines-resolvers
kubectl wait --for=condition=Available deployment --all -n tekton-pipelines --timeout=300s
kubectl wait --for=condition=Available deployment --all -n tekton-pipelines-resolvers --timeout=300s

kubectl apply -f "$TRIGGERS_MANIFEST"
kubectl apply -f "$INTERCEPTORS_MANIFEST"

# Triggers instala sus Deployments en tekton-pipelines.
patch_deployments tekton-pipelines
kubectl wait --for=condition=Available deployment --all -n tekton-pipelines --timeout=300s

kubectl get pods -n tekton-pipelines
kubectl get pods -n tekton-pipelines-resolvers
