#!/usr/bin/env bash
# =============================================================================
# 03-run-driver.sh - lancer le pod driver et suivre l'exécution.
#
# Aucun cluster n'est installé ici : exige un `kubectl` configuré.
#     NAMESPACE=julia ./03-run-driver.sh
#
# Dans un autre terminal, observez les pods workers apparaître à la volée :
#     watch kubectl -n julia get pods
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")"

NAMESPACE="${NAMESPACE:-julia}"

echo ">> Application du pod driver (manager-pod.yaml)"
kubectl apply -n "${NAMESPACE}" -f manager-pod.yaml

echo ">> Logs du driver (Ctrl-C pour détacher - le calcul continue) :"
kubectl logs -n "${NAMESPACE}" -f pod/julia-driver
