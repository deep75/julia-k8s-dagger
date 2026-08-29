# =============================================================================
# driver.jl - Driver Julia distribué sur Kubernetes (exemple complet).
#
# CADRE THÉORIQUE - contexte d'exécution attendu :
#   * un pod driver (examples/manager-pod.yaml) dans le namespace `julia`,
#     portant le ServiceAccount `julia-driver` (examples/rbac.yaml) ;
#   * une image dont l'environnement projet est pré-construit dans /app
#     (examples/Dockerfile) : Project.toml instancié + précompilé.
#
# Usage :
#     julia --project=/app driver.jl        # NP_WORKERS sinon 4 par défaut
# =============================================================================

using Distributed
using K8sClusterManagers

const NP_WORKERS = parse(Int, get(ENV, "NP_WORKERS", "4"))

# -----------------------------------------------------------------------------
# 1) Provisionnement : NP_WORKERS pods, chacun 2 CPU / 8 GiB
#    Défauts du constructeur sinon : cpu="1", memory="4Gi",
#    pending_timeout=180 s, image = celle du pod driver (in-cluster).
# -----------------------------------------------------------------------------

function avec_service_account!(pod)
    # `serviceAccountName` n'est pas exposé par le constructeur :
    # on le pose via le hook configure (docs chapitre 03).
    # Les workers n'ont BESOIN d'aucune permission - SA volontairement sans rôle.
    pod["spec"]["serviceAccountName"] = "julia-worker"
    pod["metadata"]["labels"]["app.kubernetes.io/name"] = "julia-worker"
    return pod
end

manager = K8sClusterManager(
    NP_WORKERS;
    cpu             = "2",
    memory          = "8Gi",
    pending_timeout = 300,              # images lourdes → premier pull lent
    configure       = avec_service_account!,
)

# -----------------------------------------------------------------------------
# 2) Démarrage des workers
#    - --project=/app : environnement pré-construit dans l'image
#    - -t 2           : 2 threads Julia par pod → 2 ThreadProc pour Dagger
#    La même version de Julia partout est impérative (erreurs deserialize).
# -----------------------------------------------------------------------------
addprocs(manager; exeflags = "--project=/app -t 2")
@info "Workers connectés" nworkers = nworkers() workers = workers()

# -----------------------------------------------------------------------------
# 3) Code applicatif disponible PARTOUT (driver + workers)
#    Projet réel : @everywhere using MonPackage (image pré-construite).
#    Ici : fonctions auto-contenues pour l'exemple.
# -----------------------------------------------------------------------------
@everywhere begin
    using Random
    using Dagger

    "Génère un bloc reproductible (stand-in d'un chargement de données)."
    générer_bloc(seed::Int, n::Int) = rand(MersenneTwister(seed), n)

    "Traitement « lourd » (stand-in du calcul métier)."
    traiter_bloc(bloc::Vector{Float64}) = (sleep(0.1); sum(bloc))
end

# -----------------------------------------------------------------------------
# 4) Pipeline Dagger : génération → map → reduce
#    - persist=true : les blocs restent en vie là où ils ont été produits,
#      les tâches aval y affluent (localité des données).
#    - le reduce splatté (+) attend tous les partiels.
# -----------------------------------------------------------------------------
const NBLOCS = 32

blocs = [Dagger.@spawn persist=true générer_bloc(s, 1_000_000) for s in 1:NBLOCS]
partiels = [Dagger.@spawn traiter_bloc(b) for b in blocs]
total = fetch(Dagger.@spawn +(partiels...))

@info "Résultat du pipeline" total

# -----------------------------------------------------------------------------
# 5) Placement explicite - deux options à connaître
# -----------------------------------------------------------------------------
# a) scope=Dagger.scope(worker=1) : forcer sur le driver (pid 1) - effets de
#    bord locaux, agrégat final léger. (⚠ `single=1`, ancienne forme, est
#    déprécié en Dagger 0.22.x - préférer les scopes.)
résumé = fetch(Dagger.@spawn scope=Dagger.scope(worker=1) traiter_bloc(générer_bloc(0, 100)))
@info "Tâche forcée sur le driver" résumé

# b) scope=Dagger.scope(worker=w) : verrouiller AU processus w (données non
#    déplaçables). Démonstration complète : scopes-et-elasticite.jl.

# -----------------------------------------------------------------------------
# 6) Tolérance aux pannes - rien à écrire, tout à comprendre :
#    si un pod dépasse sa limite memory (OOMKilled), Distributed retire le
#    worker et Dagger REPLANIFIE les tâches perdues sur les autres pods.
#    Le pool ne grossit pas seul : prévoir de la marge (cf. chapitre 05 §5.5).
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# 7) Arrêt propre
#    Les workers quittent → pods en phase Completed (restartPolicy: Never).
#    Les pods NE SONT PAS supprimés automatiquement :
#        kubectl delete pod -l worker-prefix=julia-driver-worker
#    (préfixe par défaut = "<nom du pod driver>-worker"), soit 04-cleanup.sh.
# -----------------------------------------------------------------------------
rmprocs(workers())
@info "Terminé - nettoyer les pods workers par label (04-cleanup.sh)"
