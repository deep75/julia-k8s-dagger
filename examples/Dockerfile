# =============================================================================
# Dockerfile - image commune driver + workers (exemple théorique).
#
# Règle d'or : UNE image pour tout le monde. Elle garantit :
#   1. la même version de Julia partout (sinon erreurs `deserialize`) ;
#   2. un environnement projet instancié AU BUILD (pas de Pkg au boot) ;
#   3. la précompilation (pas de tempête de JIT au démarrage de chaque pod).
#
# Build (contexte = ce dossier, avec votre code applicatif dans src/) :
#   docker build -t registry.example.com/mon-equipe/julia-app:1.10 .
# =============================================================================

FROM julia:1.10

# Dépôt de paquets local à l'image (reproductible, indépendant du $HOME)
ENV JULIA_DEPOT_PATH=/opt/julia-depot

WORKDIR /app

# 1) Dépendances d'abord → cache Docker efficace.
#    Reproductibilité forte : déposez aussi Manifest.toml (épinglage exact)
#    et décommentez la ligne COPY correspondante.
COPY Project.toml ./
# COPY Manifest.toml ./
RUN julia --project=/app -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

# 2) Code applicatif (à fournir dans votre contexte de build) :
# COPY src/ ./src/

# 3) Scripts d'exemple
COPY dagger-basiques.jl scopes-et-elasticite.jl driver.jl ./

# Driver et workers sont TOUS lancés avec :
#     julia --project=/app [-t N] [driver.jl | --worker=<cookie>]
# Le binaire doit être joignable sous le nom `julia` (vrai pour les images
# officielles - c'est ce que K8sClusterManagers suppose).

# Durcir en production :
# USER nobody
