#!/usr/bin/env bash
# =============================================================================
# 04-cleanup.sh - tout nettoyer après le calcul.
#
# Pourquoi ce script existe : les pods workers passent en phase Completed
# mais NE SONT PAS supprimés automatiquement (conception de K8sClusterManagers
# v0.1.5). Le label `worker-prefix` (posé sur chaque worker) permet une
# suppression groupée - recommandation du README officiel.
#
#     NAMESPACE=julia DRIVER_POD=julia-driver ./04-cleanup.sh
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")"

NAMESPACE="${NAMESPACE:-julia}"
DRIVER_POD="${DRIVER_POD:-julia-driver}"

# Le préfixe des workers dérive du nom du pod driver : "<driver>-worker"
WORKER_PREFIX="${DRIVER_POD}-worker"

echo ">> Suppression du pod driver '${DRIVER_POD}'"
kubectl -n "${NAMESPACE}" delete "pod/${DRIVER_POD}" --ignore-not-found

echo ">> Suppression des pods workers (label worker-prefix=${WORKER_PREFIX})"
kubectl -n "${NAMESPACE}" delete pod -l "worker-prefix=${WORKER_PREFIX}" --ignore-not-found

echo ">> Suppression des pods workers résiduels (label applicatif de driver.jl)"
kubectl -n "${NAMESPACE}" delete pod -l "app.kubernetes.io/name=julia-worker" --ignore-not-found

echo ">> Restant dans '${NAMESPACE}' :"
kubectl get -n "${NAMESPACE}" pods
