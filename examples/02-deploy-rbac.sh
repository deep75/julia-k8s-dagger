#!/usr/bin/env bash
# =============================================================================
# 02-deploy-rbac.sh - préparer le namespace et la RBAC du driver Julia.
#
# Aucun cluster n'est installé ici : exige un `kubectl` configuré.
#     NAMESPACE=julia ./02-deploy-rbac.sh
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")"

NAMESPACE="${NAMESPACE:-julia}"

# Namespace idempotent
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# ServiceAccount (driver + workers), Role, RoleBinding
kubectl apply -n "${NAMESPACE}" -f rbac.yaml

echo ">> RBAC en place dans le namespace '${NAMESPACE}' :"
kubectl get -n "${NAMESPACE}" serviceaccount,role,rolebinding
