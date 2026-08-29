# docs/make.jl — build de la documentation (Documenter.jl → GitHub Pages)
#
#   Local :  julia --project=docs -e 'using Pkg; Pkg.instantiate()'
#            julia --project=docs docs/make.jl
#            → site statique dans docs/build/ (ouvrir docs/build/index.html)
#
#   CI/CD :  .github/workflows/Documentation.yml
#            makedocs -> deploydocs : le site compilé est poussé sur la branche
#            `gh-pages` (jamais `main`). GitHub Pages « Deploy from a branch »
#            -> gh-pages / (root). Commits gh-pages signés « Documenter.jl »,
#            hors branche par défaut -> n'apparaissent pas dans les contributeurs.

using Documenter
using Literate

const REPO_URL   = "https://github.com/deep75/julia-k8s-dagger"
const EXAMPLES   = joinpath(@__DIR__, "..", "examples")
const GENERATED  = joinpath(@__DIR__, "src", "exemples")

# --- Exemples : examples/*.jl -> pages Documenter via Literate (sans exécution) ---
# Les scripts restent exécutables tels quels ; ici ils sont seulement mis en forme
# (prose issue des commentaires + code). Aucune exécution : ils supposent un cluster.
const EXAMPLE_PAGES = [
    "dagger-basiques"      => "Dagger.jl sans cluster",
    "driver"               => "Driver distribué complet",
    "scopes-et-elasticite" => "Scopes & pool élastique",
]

"Supprime les filets de bannière et impose un titre H1 propre."
literate_preprocess(title) = content -> begin
    kept = filter(split(content, '\n')) do line
        !occursin(r"^#[ \t]*[=\-–—_]{4,}[ \t]*$", line)
    end
    string("# # ", title, "\n#\n", join(kept, '\n'))
end

isdir(GENERATED) && rm(GENERATED; recursive = true)
mkpath(GENERATED)
for (base, title) in EXAMPLE_PAGES
    Literate.markdown(
        joinpath(EXAMPLES, base * ".jl"), GENERATED;
        name       = base,
        preprocess = literate_preprocess(title),
        codefence  = "```julia" => "```",   # blocs simples : pas d'exécution Documenter
        repo_root_url = REPO_URL * "/blob/main",
        documenter = true,
        credit     = true,
    )
end

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
        # Rendu Mermaid : bundle IIFE (mermaid.bundle.js) + init (mermaid.js).
        assets            = ["assets/mermaid.bundle.js", "assets/mermaid.js"],
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
        "Exemples de code"             => ["exemples/$b.md" for (b, _) in EXAMPLE_PAGES],
    ],
)

deploydocs(;
    repo      = "github.com/deep75/julia-k8s-dagger.git",
    devbranch = "main",
    versions  = ["dev" => "dev"],
)
