#!/usr/bin/env bash
# =============================================================================
# 01-build-image.sh - construire (et pousser) l'image commune driver+workers.
#
# AUCUN cluster n'est installé ici : ce script suppose seulement Docker et,
# pour l'envoi, un accès à un registry. Adaptez les variables d'environnement :
#
#     REGISTRY=registry.example.com/mon-equipe IMAGE=julia-app:1.10 ./01-build-image.sh
#
# Variante minikube (single-node, image non poussée) : décommentez le bloc
# `minikube docker-env` - recommandé par le README de K8sClusterManagers.jl.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")"

REGISTRY="${REGISTRY:-registry.example.com/mon-equipe}"
IMAGE="${IMAGE:-julia-app:1.10}"

# --- Minikube : construire DANS le daemon du cluster (single-node) ----------
# eval "$(minikube docker-env)"
# IMAGE_LOCAL=1   # pas de push nécessaire dans ce cas

echo ">> docker build -t ${REGISTRY}/${IMAGE}"
docker build -t "${REGISTRY}/${IMAGE}" .

if [[ -z "${IMAGE_LOCAL:-}" ]]; then
    echo ">> docker push ${REGISTRY}/${IMAGE}"
    docker push "${REGISTRY}/${IMAGE}"
fi

echo ">> Image prête : ${REGISTRY}/${IMAGE}"
echo ">> Pensez à aligner 'image:' de manager-pod.yaml sur cette référence."
