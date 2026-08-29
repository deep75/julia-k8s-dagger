# docs/make.jl — build de la documentation (Documenter.jl → GitHub Pages)
#
#   Local :  julia --project=docs -e 'using Pkg; Pkg.instantiate()'
#            julia --project=docs docs/make.jl
#            → site statique dans docs/build/ (ouvrir docs/build/index.html)
#
#   CI/CD :  .github/workflows/Documentation.yml
#            makedocs → docs/build/ → actions/upload-pages-artifact
#                                   → actions/deploy-pages
#            GitHub Pages « Source : GitHub Actions » — aucune branche gh-pages,
#            aucun token long ; déploiement OIDC via l'environnement github-pages.

using Documenter

makedocs(;
    sitename = "Julia sur Kubernetes — K8sClusterManagers × Dagger",
    authors  = "deep75",
    repo     = Remotes.GitHub("deep75", "julia-k8s-dagger"),
    format   = Documenter.HTML(;
        lang              = "fr",
        prettyurls        = get(ENV, "CI", "false") == "true",
        canonical         = "https://deep75.github.io/julia-k8s-dagger",
        edit_link         = "main",
        inventory_version = "",
        # Rendu Mermaid maison (contourne le conflit RequireJS/AMD).
        assets            = ["assets/mermaid.js"],
    ),
    pages = [
        "Accueil"                      => "index.md",
        "01 — Introduction"            => "01-introduction.md",
        "02 — Architecture"            => "02-architecture.md",
        "03 — K8sClusterManagers.jl"   => "03-k8sclustermanagers.md",
        "04 — Dagger.jl"               => "04-dagger.md",
        "05 — Intégration"             => "05-integration.md",
        "06 — Déploiement"             => "06-deploiement.md",
        "07 — Production"              => "07-production.md",
        "08 — Limites et alternatives" => "08-limites-et-alternatives.md",
    ],
)
