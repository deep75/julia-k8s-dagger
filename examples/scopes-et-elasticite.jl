# =============================================================================
# scopes-et-elasticite.jl - Patterns avancés Dagger × K8sClusterManagers.
#
# CADRE THÉORIQUE : ce script s'exécute dans un pod driver DANS le cluster
# (voir driver.jl pour le démarrage complet). Découpage :
#   - Section 1 : ProcessScope - verrouiller une donnée à son processus
#   - Section 2 : UnionScope  - contraindre des données à rester dans le cluster
#   - Section 3 : pool élastique - addprocs!/rmprocs! pendant qu'un DAG tourne
#
# Référence : docs/src/scopes.md et docs/src/processors.md de Dagger.jl.
# =============================================================================

using Distributed
using Dagger
using K8sClusterManagers

# On suppose un premier pool déjà lancé (cf. driver.jl) :
#   addprocs(K8sClusterManager(4; cpu="2", memory="8Gi"); exeflags="--project=/app -t 2")
#   @everywhere using Dagger
@assert nworkers() > 0 "Lancez d'abord addprocs(K8sClusterManager(...)) - voir driver.jl"

# -----------------------------------------------------------------------------
# 1. ProcessScope : une ressource non déplaçable reste sur SON processus
# -----------------------------------------------------------------------------
# Typique : handle C, connexion, modèle verrouillé… créés DANS une tâche.
# Le chunk porte le scope ; toute tâche aval s'exécutera au même endroit.

# ⚠ Les fonctions doivent exister PARTOUT (driver ET workers) - piège n°1 de
# Distributed, cf. docs/05-integration.md §5.7 :
@everywhere begin
    function ouvrir_ressource()
        ressource = Ref("handle-local-non-sérialisable")  # stand-in pédagogique
        proc = Dagger.task_processor()                    # processeur courant
        portée = Dagger.scope(worker = myid())            # → ProcessScope
        return Dagger.tochunk(ressource, proc, portée)    # chunk scopé
    end

    consommer(r) = string("consommé sur le worker ", myid(), " : ", r[])
end

handle = Dagger.@spawn ouvrir_ressource()   # DTask dont le RÉSULTAT est scopé
lecture = Dagger.@spawn consommer(handle)   # → forcée sur le même processus
@info "ProcessScope" résultat = fetch(lecture)

# ⚠ Ne pas fetch(handle) depuis le driver si la donnée ne doit PAS quitter
# son processus : garder le DTask et ne consommer que via des tâches aval.

# -----------------------------------------------------------------------------
# 2. UnionScope : des données qui ne quittent JAMAIS le cluster
# -----------------------------------------------------------------------------
# Utilisé tel quel dans la doc officielle : l'union des ProcessScope des
# workers du cluster. Un chunk ainsi scopé ne peut alimenter que des tâches
# planifiées sur ces workers - le driver (pid 1) en est exclu.

@everywhere begin
    "Chunk d'une donnée sensible, scopé à l'ensemble du cluster de workers."
    function générer_confidentiel()
        secret = "donnée-sensible"                  # vit sur un worker
        portée = Dagger.UnionScope(Dagger.ProcessScope.(workers()))
        return Dagger.tochunk(secret, Dagger.task_processor(), portée)
    end

    anonymiser(s) = "résumé anonymisé de " * s
end

# La génération tourne sur un worker précis (forme par scope - `single=`
# est déprécié en 0.22) ; le résumé aussi (le secret ne remonte pas au
# driver) :
secret_chunk = Dagger.@spawn scope=Dagger.scope(worker=first(workers())) générer_confidentiel()
@info "UnionScope" résumé = fetch(Dagger.@spawn anonymiser(secret_chunk))

# -----------------------------------------------------------------------------
# 3. Pool élastique : ajouter/retirer des pods PENDANT le calcul
# -----------------------------------------------------------------------------
# Le Context de l'ordonnanceur accepte des processeurs à chaud. Les nouveaux
# workers reçoivent des tâches dès leur intégration ; les retirés terminent
# leurs tâches en cours puis n'en reçoivent plus.

ctx = Dagger.Context()

# Une vague de 20 tâches (API lazy ici, car collect(ctx, …) accepte un
# Context - la doc officielle illustre l'élasticité avec cette forme) :
tas = Dagger.delayed(vcat)((Dagger.delayed(i -> (sleep(0.5); myid()))(i)
                            for i in 1:20)...)
job = @async Dagger.collect(ctx, tas)

# À chaud : deux pods workers supplémentaires…
ps = addprocs(K8sClusterManager(2; cpu="2", memory="8Gi");
              exeflags="--project=/app")
@everywhere ps using Dagger          # requis AVANT l'intégration au pool
addprocs!(ctx, ps)                   # …voilà le pool qui grossit

ids_exécution = fetch(job)           # les nouveaux workers apparaissent dedans
@info "Tâches exécutées par les workers" ids = unique(ids_exécution)

# Retrait du pool de l'ordonnanceur (terminent le travail en cours) :
rmprocs(ctx, ps)
# Puis, si vous voulez aussi ÉTEINDRE ces workers (pods → Completed) :
rmprocs(ps)

println("scopes-et-elasticite.jl : patterns démontrés ✔")
