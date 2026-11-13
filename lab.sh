#!/usr/bin/env bash
# Helper for the k8s troubleshooting lab. Usage: ./lab.sh <command> [scenario-number]
set -euo pipefail
cd "$(dirname "$0")"
NS=lab

scenario_file() {
  local f
  f=$(ls broken/"$(printf '%02d' "$1")"-*.yaml 2>/dev/null | head -n1 || true)
  [[ -n "$f" ]] || { echo "No scenario $1"; exit 1; }
  echo "$f"
}

case "${1:-help}" in
  up)        kind create cluster --config kind-config.yaml ;;
  baseline)  kubectl apply -f baseline/00-namespace.yaml
             kubectl apply -f baseline/
             kubectl -n $NS rollout status deploy/db deploy/web --timeout=120s ;;
  break)     kubectl apply -f "$(scenario_file "${2:?scenario number}")" ;;
  fix)       kubectl delete -f "$(scenario_file "${2:?scenario number}")" --ignore-not-found ;;
  reset)     for f in broken/*.yaml; do kubectl delete -f "$f" --ignore-not-found; done ;;
  status)    kubectl -n $NS get pods,svc,pvc,endpoints ;;
  down)      kind delete cluster --name k8s-lab ;;
  *) cat <<EOF
Commands:
  up                 create the kind cluster (needs Docker + kind + kubectl)
  baseline           deploy the known-good db + web into namespace '$NS'
  break N            apply broken scenario N (1-6)
  fix N              remove scenario N's resources (this is "cleanup", not the diagnosis!)
  reset              remove all scenario resources, keep baseline
  status             pods, services, PVCs, endpoints in '$NS'
  down               delete the cluster
Tip: diagnose first, write the runbook, THEN apply the fix by editing the manifest.
EOF
  ;;
esac
