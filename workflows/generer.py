#!/usr/bin/env python3
"""Génère .gitea/workflows/ci.yml d'une plateforme à partir de son .github/workflows/ci.yml (source de vérité des
contrôles) : mêmes jobs et mêmes étapes, adaptés au runner auto-hébergé.

    python3 generer.py <dépôt>            # écrit <dépôt>/.gitea/workflows/ci.yml et <dépôt>/.gitea/statut-github.sh
    python3 generer.py <dépôt> --verifier # échoue si le fichier présent n'est pas à jour (à lancer avant une PR)

Adaptations (et rien d'autre) :
- déclencheurs : chaque branche reçue par le miroir (push) et lancement manuel ; pas de pull_request (les PR sont sur GitHub) ;
- runs-on : ubuntu-latest → ci-hote (runner en mode hôte sur la VM dédiée) ;
- job « ouverture » (statut « en cours » sur le commit GitHub) dont dépendent les jobs sans dépendance, et job « bilan »
  (résultat de tous les jobs renvoyé sur GitHub) ;
- sans sudo : dossier de sauvegarde rendu inscriptible (chmod 777) au lieu d'un chown, 7-Zip attendu sur la VM ;
- service PostgreSQL d'un job (inexistant en mode hôte) remplacé par un conteneur lancé en première étape.
Toute autre différence fait échouer la génération : l'écart doit être traité ici, pas à la main dans le fichier généré.
"""
from __future__ import annotations

import pathlib
import re
import shutil
import sys

ICI = pathlib.Path(__file__).resolve().parent
CHECKOUT = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1   # v7.0.1"


def remplacer(s: str, ancien: str, nouveau: str, fois: int | None = 1, regex: bool = False) -> str:
    n = len(re.findall(ancien, s, re.M)) if regex else s.count(ancien)
    if (fois is None and n == 0) or (fois is not None and n != fois):
        raise SystemExit(f"Motif attendu {fois or '≥1'} fois, trouvé {n} : {ancien[:80]!r}")
    return re.sub(ancien, nouveau, s, flags=re.M) if regex else s.replace(ancien, nouveau)


def jobs_de(s: str) -> list[str]:
    bloc = s.split("\njobs:\n", 1)[1]
    return re.findall(r"^  ([a-z][a-z0-9_-]*):\s*$", bloc, re.M)


def service_postgres(s: str) -> str:
    """Bloc services: postgres (format des workflows de Bleuet) → première étape qui lance le même conteneur."""
    m = re.search(r"\n    services:\n      postgres:\n        image: (\S+)\n        env:\n((?:          \w+: .+\n)+)"
                  r"        ports: \[\"([0-9.]+):(\d+):5432\"\]\n        options: >-\n          .+\n", s)
    if not m:
        return s
    image, env, hote, port = m.group(1), m.group(2), m.group(3), m.group(4)
    vars_env = dict(re.findall(r"(\w+): (.+)", env))
    user, db = vars_env["POSTGRES_USER"], vars_env["POSTGRES_DB"]
    e = " ".join(f"-e {k}={v}" for k, v in vars_env.items())
    s = s[:m.start()] + "\n" + s[m.end():]
    etape = (f"      - name: PostgreSQL jetable (service du job, lancé à la main en mode hôte)\n"
             f"        run: |\n"
             f"          docker run -d --name ci-postgres {e} -p {hote}:{port}:5432 {image}\n"
             f"          for i in $(seq 1 30); do docker exec ci-postgres pg_isready -U {user} -d {db} && break; sleep 2; done\n")
    # insérée après la récupération du code (le job peut fixer working-directory sur un dossier du dépôt)
    debut = s.rfind("\n  ", 0, m.start())
    co = "      - uses: " + CHECKOUT + "\n        with:\n          persist-credentials: false\n"
    pos = s.index(co, debut) + len(co)
    return s[:pos] + etape + s[pos:]


def convertir(src: str, nom: str) -> str:
    s = src
    s = remplacer(s, r"^# Intégration continue de [^\n]*\n(?:#[^\n]*\n)*", "", regex=True)
    entete = (f"# Intégration continue de {nom} sur la CI Gitea auto-hébergée : FICHIER GÉNÉRÉ par gitea-ci/workflows/generer.py\n"
              "# à partir de .github/workflows/ci.yml (mêmes contrôles), à ne pas modifier à la main. Chaque branche reçue par le\n"
              "# miroir est contrôlée ; le résultat est renvoyé sur le commit GitHub (statut « gitea-ci »).\n")
    s = remplacer(s, "on:\n  push:\n    branches: [main]\n  pull_request:\n",
                  'on:\n  push:\n    branches: ["**"]\n  workflow_dispatch:\n')
    s = remplacer(s, "runs-on: ubuntu-latest", "runs-on: ci-hote", fois=None)
    s = service_postgres(s)
    if "sudo chown 10001:10001 backups" in s:
        s = remplacer(s, "mkdir -p backups && sudo chown 10001:10001 backups",
                      "mkdir -p backups && chmod 777 backups      # écrit par l'UID 10001 du conteneur, supprimable ensuite (sans sudo)")
    if "sudo apt-get install -y -q 7zip" in s:
        s = remplacer(s, "          sudo apt-get install -y -q 7zip || sudo apt-get install -y -q p7zip-full\n",
                      "          command -v 7z >/dev/null || { echo \"::error::7-Zip absent de la VM du runner\"; exit 1; }\n")
    if "sudo " in s:
        raise SystemExit("sudo restant : à traiter dans generer.py (le runner n'a pas sudo)")
    if "services:" in s:
        raise SystemExit("services: restant : à traiter dans generer.py (pas de service en mode hôte)")

    jobs = jobs_de(s)
    # Jobs sans dépendance : après l'ouverture (statut « en cours » publié d'abord)
    for j in jobs:
        bloc = re.search(rf"^  {j}:\n    name: [^\n]+\n    runs-on: ci-hote\n(    needs: [^\n]+\n)?", s, re.M)
        if not bloc:
            raise SystemExit(f"Job {j} : en-tête attendu (name puis runs-on)")
        if not bloc.group(1):
            s = s[:bloc.end()] + "    needs: [ouverture]\n" + s[bloc.end():]
    s = remplacer(s, "\njobs:\n", f"""
env:
  DEPOT_GITHUB: ${{{{ vars.DEPOT_GITHUB }}}}
  API_STATUTS: ${{{{ vars.API_STATUTS }}}}

jobs:
  ouverture:
    name: Statut GitHub (en cours)
    runs-on: ci-hote
    steps:
      - uses: {CHECKOUT}
        with:
          persist-credentials: false
          sparse-checkout: .gitea
      - name: Statut « en cours » sur le commit GitHub
        env:
          GH_STATUS_TOKEN: ${{{{ secrets.GH_STATUS_TOKEN }}}}
        run: bash .gitea/statut-github.sh pending "CI Gitea en cours"

""")
    env = "".join(f"          R_{j.upper()}: ${{{{ needs.{j}.result }}}}\n" for j in jobs)
    s = s.rstrip("\n") + f"""

  bilan:
    name: Statut GitHub (résultat)
    runs-on: ci-hote
    needs: [{', '.join(jobs)}]
    if: always()
    steps:
      - uses: {CHECKOUT}
        with:
          persist-credentials: false
          sparse-checkout: .gitea
      - name: Résultat sur le commit GitHub
        env:
          GH_STATUS_TOKEN: ${{{{ secrets.GH_STATUS_TOKEN }}}}
{env}        run: |
          ko=""
          for j in {' '.join(j.upper() for j in jobs)}; do v="R_$j"; [ "${{!v}}" = success ] || ko="$ko ${{j,,}}=${{!v}}"; done
          if [ -z "$ko" ]; then bash .gitea/statut-github.sh success "CI Gitea réussie"
          else bash .gitea/statut-github.sh failure "Échec :$ko"; exit 1; fi
"""
    return entete + s


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    depot = pathlib.Path(sys.argv[1]).resolve()
    src = (depot / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    nom = re.search(r"^# Intégration continue de (\S+)", src, re.M)
    nom = {"NORN": "Bleuet (NORN)"}.get(nom.group(1), nom.group(1)) if nom else depot.name
    sortie = convertir(src, nom)
    cible, script = depot / ".gitea/workflows/ci.yml", depot / ".gitea/statut-github.sh"
    if "--verifier" in sys.argv:
        a_jour = (cible.exists() and cible.read_text(encoding="utf-8") == sortie and script.exists()
                  and script.read_bytes() == (ICI / "statut-github.sh").read_bytes())
        print(".gitea à jour" if a_jour else ".gitea PAS à jour : relancez generer.py")
        raise SystemExit(0 if a_jour else 1)
    cible.parent.mkdir(parents=True, exist_ok=True)
    cible.write_text(sortie, encoding="utf-8")
    shutil.copyfile(ICI / "statut-github.sh", script)
    script.chmod(0o755)
    print(f"{cible} et {script} écrits ({len(jobs_de(sortie))} jobs)")


if __name__ == "__main__":
    main()
