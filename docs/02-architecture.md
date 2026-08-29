# 02 - Architecture

## 2.1 Vue en couches

```mermaid
flowchart TB
    subgraph L1["Couche 1 - Code utilisateur"]
        APP["Pipeline d'algorithmes<br/>Dagger.@spawn, fetch, scopes"]
    end
    subgraph L2["Couche 2 - Ordonnancement : Dagger.jl"]
        DAG["DAG de DTasks + options<br/>(single, scope, persist, procutil…)"]
        SCH["Ordonnanceur dynamique<br/>localité, scopes, tolérance aux pannes"]
    end
    subgraph L3["Couche 3 - Transport : Distributed.jl"]
        RPC["remote calls + sérialisation<br/>connaît des PIDs, pas des pods"]
        CM["interface ClusterManager"]
    end
    subgraph L4["Couche 4 - Provisionnement : K8sClusterManagers.jl"]
        GEN["génération de manifests de pods<br/>worker_pod_spec + configure"]
        CTL["pilote kubectl_jll<br/>create / get / label / delete / logs / exec"]
    end
    subgraph L5["Couche 5 - Kubernetes"]
        API["API Server + scheduler"]
        PODS["pods workers<br/>restartPolicy: Never"]
    end
    APP --> DAG --> SCH --> RPC
    RPC --> CM --> GEN --> CTL --> API --> PODS
```

Point clé : **chaque couche ignore les détails de la couche inférieure**. Dagger manipule des
« processus » (PIDs Distributed) ; Distributed manipule des « workers » abstraits via le
`ClusterManager` ; K8sClusterManagers traduit cela en appels `kubectl` ; Kubernetes place les
pods.

## 2.2 Le protocole `ClusterManager` de Distributed

Un `ClusterManager` doit surcharger trois méthodes. Le tableau croise chaque méthode avec son
implémentation dans `K8sClusterManager` :

| Méthode Distributed | Rôle | Implémentation K8sClusterManagers (v0.1.5) |
|---|---|---|
| `Distributed.launch(manager, params, launched, cond)` | créer les processus workers | génère le manifest pod (`worker_pod_spec` + `configure`), `kubectl create`, attend `Running`, ouvre `kubectl logs -f`, publie des `WorkerConfig` |
| `Distributed.connect(manager, pid, config)` | ouvrir la connexion TCP du driver vers le worker | lit l'annonce host/port du worker (`--worker`), résout la vraie adresse (`podIP` ou port-forward), connecte le socket |
| `Distributed.manage(manager, id, config, op)` | superviser le cycle de vie | `:register` → label `worker-id` ; `:interrupt` → `kubectl exec kill -2` ; `:deregister` → arrêt du port-forward + diagnostic de terminaison |

```mermaid
flowchart LR
    AP["addprocs(manager)"] --> LA["launch<br/>créer"]
    LA --> CO["connect<br/>relier"]
    CO --> RE["manage(:register)<br/>enregistrer"]
    RE --> RU["exécution"]
    RU --> IN["manage(:interrupt)<br/>Ctrl-C à distance"]
    RU --> DE["manage(:deregister)<br/>départ du worker"]
```

## 2.3 Séquence complète de `addprocs(K8sClusterManager(np))`

```mermaid
sequenceDiagram
    autonumber
    participant App as Code utilisateur
    participant Drv as Driver Julia
    participant KCM as K8sClusterManager
    participant Kct as kubectl_jll
    participant API as API Server K8s
    participant Pod as Pod worker

    App->>Drv: addprocs(K8sClusterManager(np))
    Drv->>KCM: Distributed.launch(manager, params, launched, cond)
    KCM->>KCM: worker_pod_spec(...) puis configure(pod)
    loop pour i = 1..np (tâches asynchrones parallèles)
        KCM->>Kct: kubectl create -f - (manifest JSON)
        Kct->>API: POST Pod (generateName)
        API-->>Kct: pod/&lt;nom&gt; créé
        KCM->>Kct: kubectl get pod/&lt;nom&gt; -o json (sondage 1 s)
        API-->>KCM: phase = Running
        KCM->>Kct: kubectl logs -f pod/&lt;nom&gt;
        Kct-->>Drv: flux stdout/stderr du worker
        KCM-->>Drv: WorkerConfig(io, userdata=(pod_name, port_forward))
        KCM-->>Drv: notify → worker « lancé »
    end
    Drv->>Pod: le worker annonce host:port (--worker=cookie)
    alt manager dans le cluster
        Drv->>Pod: TCP direct vers podIP:port
    else manager hors du cluster
        Drv->>Kct: kubectl port-forward --address localhost pod/&lt;nom&gt; :port
        Drv->>Pod: TCP via le tunnel localhost
    end
    Drv->>Pod: poignée de main Distributed (cookie)
    Drv->>KCM: manage(:register)
    KCM->>Kct: kubectl label pod/&lt;nom&gt; worker-id=&lt;pid&gt;
```

Trois détails d'implémentation notables (source `src/native_driver.jl`) :

1. **`--bind-to=0.0.0.0`** : le worker écoute sur toutes les interfaces - nécessaire au
   port-forward (l'adresse annoncée par Julia est sinon non routable hors du pod).
2. **`exename` forcé à `julia`** si l'image commence par `julia:` : les images officielles
   placent le binaire à cet endroit.
3. **Démarrage partiel toléré** : si un pod reste `Pending` au-delà de `pending_timeout`
   (180 s par défaut), il est supprimé, un avertissement est émis et `addprocs` **continue
   avec les workers déjà disponibles** (`<= np`).

## 2.4 Hiérarchie des processeurs vus par Dagger

Dagger modélise le matériel comme un arbre multi-racines : une racine `OSProc` **par processus
OS** (le driver *et* chaque pod worker), avec des enfants `ThreadProc` (un par thread Julia
`-t N`). C'est cette hiérarchie que l'ordonnanceur parcourt pour placer les tâches.

```mermaid
flowchart TB
    subgraph KC["Cluster Kubernetes"]
        subgraph PD["Pod driver"]
            D1["OSProc - pid 1"] --> DT["ThreadProc × T"]
        end
        subgraph PW1["Pod worker 1"]
            W1["OSProc - pid 2"] --> W1T["ThreadProc × T"]
        end
        subgraph PWN["Pod worker N"]
            WN["OSProc - pid N+1"] --> WNT["ThreadProc × T"]
        end
    end
    D1 <-->|"Distributed TCP"| W1
    D1 <--> WN
    W1 <-.->|"mesh worker-à-worker<br/>(podIP)"| WN
```

Conséquences pratiques :

- **-t 2 dans `exeflags`** donne 2 processeurs par pod → Dagger peut y placer 2 tâches
  simultanées par défaut (occupation complète supposée).
- Les processeurs GPU (via `DaggerGPU.jl` / extensions `CUDA`, `AMDGPU`, `Metal`, `oneAPI`,
  `OpenCL`) s'ajoutent comme enfants - désactivés par défaut, activables par scopes.

## 2.5 Cycle de vie d'un pod worker

```mermaid
stateDiagram-v2
    [*] --> Pending: kubectl create (restartPolicy: Never)
    Pending --> Pending: scheduling, ImagePullBackOff…
    Pending --> Running: conteneur démarré
    Pending --> Deleted: pending_timeout (180 s) dépassé<br/>delete_pod + warning, addprocs continue
    Running --> Completed: worker quitte proprement (rmprocs)
    Running --> Error: plantage du processus Julia
    Running --> OOMKilled: limite memory dépassée
    Completed --> [*]
    Error --> [*]
    OOMKilled --> [*]
    Deleted --> [*]
```

Au `:deregister`, le manager attend jusqu'à 30 s (grace period K8s par défaut) la terminaison
du pod et émet un `@warn` si la raison n'est pas `Completed` - c'est le principal signal
d'une mort anormale (OOM, plantage). **Aucune suppression automatique** des pods : le
nettoyage se fait par label (chapitre 07).

## 2.6 Flux de données d'une tâche

```mermaid
flowchart LR
    T["Dagger.@spawn f(arg)"] --> S["Ordonnanceur :<br/>analyse les dépendances du DAG"]
    S --> L{"Données déjà<br/>sur le worker cible ?"}
    L -- "oui (localité)" --> E["exécution locale<br/>sur ThreadProc / OSProc"]
    L -- "non" --> M["transfert du Chunk<br/>Serialization (+ MemPool)<br/>entre OSProc"]
    M --> E
    E --> R["résultat renvoyé<br/>sous forme de Chunk"]
    R --> S
```

Le mouvement de données par défaut se décompose en trois déplacements : processeur A →
`OSProc` parent de A, `OSProc` de A → `OSProc` de B (réseau Distributed), puis vers le
processeur B. Tout doit être **sérialisable** ; les gros objets transitent via `MemPool`.

→ Suite : [03 - K8sClusterManagers.jl](03-k8sclustermanagers.md)
