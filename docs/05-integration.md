# 05 - Intégration : K8sClusterManagers × Dagger

## 5.1 Le contrat entre les deux paquets

Chaque paquet suppose des garanties offertes par l'autre. Le tableau fixe le contrat :

| Paquet | Attend | Offre en retour |
|---|---|---|
| `K8sClusterManagers` | que les workers parlent le protocole `--worker` de Distributed (cookie), que l'image contienne un Julia fonctionnel | des processus Julia dans des pods, connus de `workers()`, avec flux de logs et diagnostics K8s |
| `Dagger` | des processus Distributed stables, avec le **même environnement logiciel** partout | placement dynamique des tâches sur ces processus (`OSProc`/`ThreadProc`), reprise après perte d'un worker |
| L'utilisateur | cohérence de versions et d'environnements | un pipeline declaratif : `addprocs` → `@everywhere` → `@spawn` |

## 5.2 Flux de bout en bout

```mermaid
sequenceDiagram
    autonumber
    participant U as Utilisateur
    participant Drv as Pod driver<br/>(julia --project=/app)
    participant API as API Server K8s
    participant W as Pods workers<br/>(julia --worker=cookie)
    participant Sch as Ordonnanceur Dagger

    U->>Drv: julia driver.jl
    Drv->>API: kubectl create ×N (pods workers)
    API-->>Drv: pods Running (flux logs -f en parallèle)
    W-->>Drv: annonce host:port (--worker)
    Drv->>W: TCP (podIP) + poignée de main (cookie)
    Drv->>Drv: @everywhere : code + packages chargés partout
    U->>Sch: Dagger.@spawn génération / map / reduce
    Sch->>W: placement des tâches (localité, scopes, charge)
    W-->>Sch: résultats (Chunk)
    Sch-->>U: fetch(total)
    U->>Drv: rmprocs(workers())
    Drv->>W: fermeture propre des workers
    Note over W: pods → phase Completed<br/>(suppression manuelle par label)
```

Le squelette Julia correspondant (version commentée complète : [`examples/driver.jl`](../examples/driver.jl)) :

```julia
using Distributed, K8sClusterManagers, Dagger

addprocs(K8sClusterManager(4; cpu="2", memory="8Gi");
         exeflags=`--project=/app -t 2`)   # Cmd (backticks) : plusieurs flags

@everywhere using MonPackage           # environnement pré-construit dans l'image

tâches = [Dagger.@spawn persist=true MonPackage.générer(s) for s in 1:32]
résultats = [Dagger.@spawn MonPackage.traiter(t) for t in tâches]
total = fetch(Dagger.@spawn +(résultats...))

rmprocs(workers())
```

## 5.3 Environnement logiciel des workers

C'est le point le plus critique de l'intégration : **les pods sont des processus Julia
neufs** - rien n'y est installé à l'exécution si l'image ne le contient pas.

```mermaid
flowchart TD
    Q["Que doit contenir l'image des workers ?"] --> A["Julia - MÊME version que le driver<br/>(sinon erreurs deserialize)"]
    A --> B{"Environnement projet (packages) ?"}
    B -- "recommandé" --> C["Pré-construit dans l'image :<br/>Project.toml (+ Manifest) → instantiate + precompile<br/>exeflags = `--project=/app -t N` (Cmd)"]
    B -- "déconseillé" --> D["Installation à chaud dans les pods<br/>(réseau, latence, non reproductible)"]
    C --> E["Packages identiques partout<br/>precompile → pas de tempête de compilation"]
```

Règles d'or :

1. **Même version de Julia** driver ↔ workers (les erreurs `deserialize` en sont le symptôme
   n°1, cf. README officiel).
2. **Même environnement de packages** : `--project=/app` dans `exeflags`, `/app` étant
   instancié **au build** de l'image.
3. **`-t N`** dans `exeflags` donne N `ThreadProc` par pod - c'est la granularité de
   parallélisme intra-pod de Dagger. `exeflags` avec plusieurs flags **doit** être
   un `Cmd` (backticks : `` `--project=/app -t N` ``) ; un `String` n'est valide
   que pour un flag unique.
4. **Précompilation au build** (`Pkg.precompile()`) évite que chaque pod compile les paquets
   à son démarrage.

## 5.4 Placement et localité

```mermaid
flowchart LR
    T["tâche + données"] --> S{"Contraintes ?"}
    S -- "aucune" --> A["libre : tout OSProc / ThreadProc<br/>localité = priorité au worker qui a la donnée"]
    S -- "scope=ProcessScope(worker=1)" --> B["processus imposé au driver<br/>(remplace single=, déprécié 0.22)"]
    S -- "scope=ProcessScope(worker=w)" --> C["processus imposé<br/>données non déplaçables (pointeurs, modèles)"]
    S -- "NodeScope / ExactScope" --> D["serveur / GPU exact imposé"]
```

En pratique sur K8s :

- `persist=true` sur les jeux de données intermédiaires : les blocs restent sur le pod qui
  les a produits et les tâches en aval y affluent (localité).
- `scope=Dagger.scope(worker=1)` pour les opérations à effet de bord côté driver
  (écriture disque du driver, agrégats finaux légers) - `single=1`, l'ancienne forme,
  est déprécié en Dagger 0.22.
- `scope=Dagger.scope(worker=<pid>)` pour une ressource non sérialisable créée dans un pod.

## 5.5 Scénario de panne : worker `OOMKilled`

```mermaid
sequenceDiagram
    autonumber
    participant Sch as Ordonnanceur Dagger
    participant Drv as Driver (Distributed)
    participant WA as Pod worker A
    participant WB as Pod worker B

    Sch->>WA: tâches t2, t3 en cours
    Note over WA: limite memory dépassée → OOMKilled
    WA--xDrv: socket fermé (sortie de processus)
    Drv->>Drv: manage(:deregister) → attend ≤ 30 s → @warn « terminated due to: OOMKilled »
    Drv--xSch: worker A retiré du pool
    Sch->>WB: re-planification de t2, t3 (données recopiées)
    WB-->>Sch: résultats
    Note over Sch,Drv: aucun nouveau pod n'est créé :<br/>le pool diminue jusqu'à la fin du DAG
```

Comportement à retenir : **Dagger recompute** le travail perdu, mais **K8sClusterManagers ne
relance pas** de pod pour un worker mort après le démarrage. La fiabilité se dimensionne
donc à deux niveaux : mémoire des pods (limite > pic mémoire des tâches) et nombre de
workers restants suffisant pour finir le DAG.

## 5.6 Scalabilité : dégradé au départ, élastique ensuite

```mermaid
flowchart LR
    subgraph S1["Au démarrage - K8sClusterManagers"]
        N["np workers demandés"] --> M["np' ≤ np obtenus<br/>(pending_timeout dépassé → pod supprimé, warning)"]
    end
    subgraph S2["À chaud - Dagger.Context"]
        E1["addprocs!(ctx, nouveaux)"] --> E2["les nouveaux pods prennent des tâches"]
        E2 --> E3["rmprocs(ctx, quelques-uns)<br/>finissent le travail en cours,<br/>ne reçoivent plus rien"]
    end
    S1 --> S2
```

Deux leviers complémentaires :

- **démarrage tolérant** : un cluster sous-dimensionné démarre quand même, avec moins de
  workers que demandé (`pending_timeout`) ;
- **élasticité applicative** : `addprocs!(ctx, …)` / `rmprocs(ctx, …)` sur le `Context`
  de l'ordonnanceur, pendant que le DAG tourne (l'ajout de workers reste un
  `addprocs(K8sClusterManager(k))` classique côté K8s).

## 5.7 Pièges classiques

| Symptôme | Cause probable | Remède |
|---|---|---|
| `deserialize` errors à la connexion | versions de Julia différentes driver/workers | image unique (`julia:1.10`), driver lancé depuis la même image |
| `MethodError`/`UndefVarError` dans une tâche | code/packages absents des workers | `@everywhere` ou `using MonPackage` **après** `addprocs`, environnement pré-construit dans l'image |
| Chaque pod compile les packages au démarrage | pas de précompilation dans l'image | `Pkg.precompile()` au build ; `JULIA_DEPOT_PATH` stable |
| Tâches lentes, pods quasi oisifs | scopes trop restrictifs (ex. tout forcé sur le driver) | réserver les scopes aux cas nécessaires (§5.4) |
| Workers tués en plein calcul (`OOMKilled`) | limite memory < pic mémoire des tâches + buffers de sérialisation | augmenter `memory`, découper les données, `procutil` |
| `addprocs` pend ~3 min puis démarre avec moins de workers | pods `Pending` (ressources insuffisantes) | `kubectl describe pod`, ajuster `cpu`/`memory`/`pending_timeout` |
| Pods workers accumulés en `Completed` | pas de suppression automatique (par conception) | nettoyage par label (chapitre 07, `04-cleanup.sh`) |

→ Suite : [06 - Déploiement](06-deploiement.md)
