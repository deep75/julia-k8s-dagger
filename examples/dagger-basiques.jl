# =============================================================================
# dagger-basiques.jl - Tour des fonctionnalités de Dagger.jl SANS cluster.
#
# S'exécute sur n'importe quelle machine, mono-processus :
#     julia --project=. examples/dagger-basiques.jl
#
# Dagger découvre seul les processeurs locaux (OSProc + ThreadProc par thread
# Julia). Tout ce qui suit se transpose tel quel aux workers K8s : seuls le
# `addprocs(K8sClusterManager(...))` et le `@everywhere` s'ajoutent (voir
# driver.jl et scopes-et-elasticite.jl).
#
# Référence : docs/src/task-spawning.md de JuliaParallel/Dagger.jl (0.22.x).
# =============================================================================

using Dagger

# -----------------------------------------------------------------------------
# 1. DAG minimal - les DTask passés en argument deviennent des dépendances
# -----------------------------------------------------------------------------
add1(x) = x + 1
add2(x) = x + 2
combine(a...) = sum(a)

p = Dagger.@spawn add1(4)        # DTask soumis immédiatement (API « eager »)
q = Dagger.@spawn add2(p)        # q dépend de p
r = Dagger.@spawn add1(3)
s = Dagger.@spawn combine(p, q, r)

@assert fetch(s) == 16           # (4+1) + (4+1+2) + (3+1)

# -----------------------------------------------------------------------------
# 2. Cycle de vie d'une DTask : fetch / wait / isready / @sync
# -----------------------------------------------------------------------------
t = Dagger.@spawn sleep(2)
@assert !isready(t)
wait(t)                          # wait ne vérifie PAS l'échec - fetch oui
@assert isready(t)

@sync begin                      # @sync fonctionne avec les DTask
    Dagger.@spawn sleep(1)
    Dagger.@spawn sleep(1)
end

# -----------------------------------------------------------------------------
# 3. Options de tâches utiles au quotidien
# -----------------------------------------------------------------------------
# Placement forcé - via scope (⚠ `single=<pid>`, ancienne forme, est
# déprécié en Dagger 0.22.x : préférer les scopes) :
u = Dagger.@spawn scope=Dagger.scope(worker=1) sum(rand(100))
fetch(u)

v = Dagger.@spawn persist=true rand(1000)   # résultat conservé pour le DAG
w = Dagger.@spawn cache=true sum(v)         # réutilisable si ré-évalué
fetch(w)

# Tâche peu consommatrice (réseau/IO) : ne « réserve » pas son thread entier :
io = Dagger.@spawn occupancy=Dict(Dagger.ThreadProc => 0) sleep(0.1)
fetch(io)

# -----------------------------------------------------------------------------
# 4. Erreurs : propagation aval + ré-levée au fetch
# -----------------------------------------------------------------------------
boom() = error("échec volontaire")
e = Dagger.@spawn boom()
aval = Dagger.@spawn sum(e)      # sera marquée échouée (dépend d'une tâche échouée)
try
    fetch(e)                     # re-lève l'erreur d'origine
    error("inatteignable")
catch err
    @info "erreur capturée comme prévu" typeof(err)
end

# -----------------------------------------------------------------------------
# 5. Annulation
# -----------------------------------------------------------------------------
longue = Dagger.@spawn sleep(60)
Dagger.cancel!(longue)           # abandon sûr : finit en arrière-plan, non bloquant
# force=true est possible mais déconseillé (fuites/segfaults potentiels)

# -----------------------------------------------------------------------------
# 6. Syntaxes pratiques (toutes équivalentes à des appels de fonction)
# -----------------------------------------------------------------------------
A = rand(4)
bc = Dagger.@spawn A .+ A                        # broadcast
anon = Dagger.@spawn sum(A) do a                 # do-block
    a + 1
end
nt = Dagger.@spawn (; a = 1, b = 2)              # NamedTuple
@assert fetch(bc) ≈ 2A
@assert fetch(anon) == sum(a -> a + 1, A)
@assert fetch(nt).b == 2

println("dagger-basiques.jl : tous les exemples passent ✔")
