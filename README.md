# gitea-ci — CI auto-hébergée des plateformes Blue team

Remplace GitHub Actions (désactivé) pour Bleuet, Coquelicot et Marguerite. Les dépôts restent sur GitHub : un serveur
**Gitea 28.2.0** en tient un miroir, relevé toutes les 2 minutes, et lance sur chaque branche reçue les mêmes contrôles
que `.github/workflows/ci.yml`. Les jobs tournent sur un **Gitea Runner 5.2.2** installé sur une VM dédiée. Le résultat
revient sur le commit GitHub sous forme de statut `gitea-ci` (coche verte ou croix rouge sur la PR).

```
GitHub (dépôts, PR) ──miroir HTTPS toutes les 2 min──▶ Gitea 28.2.0 + PostgreSQL 18 (serveur, compose)
       ▲                                                   │ jobs (.gitea/workflows/ci.yml)
       │ statut de commit « gitea-ci »                     ▼
       └──────────────────────────────────────── Gitea Runner 5.2.2, mode hôte (VM dédiée Ubuntu 24.04)
```

| Composant | Version | Où |
|---|---|---|
| Gitea (image sans privilèges) | 28.2.0, épinglée par empreinte | `serveur/docker-compose.yml` |
| PostgreSQL (base dédiée à Gitea) | 18.6 (`18-alpine`), épinglée par empreinte | `serveur/docker-compose.yml` |
| Gitea Runner | 5.2.2, empreinte SHA-256 vérifiée | `runner/installer-runner.sh` |
| rustup | 1.29.2, empreinte SHA-256 vérifiée | `runner/installer-runner.sh` |

## 1. Prérequis

**Serveur Gitea** : Docker ou Podman avec compose, 2 vCPU, 4 Go de RAM, 20 Go de disque. Il peut partager une machine
avec d'autres services ; il n'exécute aucun job.

**VM du runner** : Ubuntu 24.04 x86_64, **dédiée à la CI**, avec 4 vCPU, 16 Go de RAM et 100 Go de disque au moins
(images, chaînes Rust, caches). Après chaque job, le runner retire tous les conteneurs et volumes de la machine : il ne
doit jamais tourner à côté d'autre chose. L'installation refuse une machine qui a déjà des conteneurs.

**Jeton GitHub** (*fine-grained personal access token*, propriétaire `tikalim`) :

- dépôts : `marguerite`, `coquelicot`, `norn`, et eux seuls ;
- permissions : *Contents* en lecture seule (miroir) et *Commit statuses* en lecture et écriture (résultat) ;
  *Metadata* en lecture est ajoutée d'office ;
- expiration : 1 an au plus, à renouveler (voir § 6).

**Flux réseau**

| Depuis | Vers | Pour |
|---|---|---|
| Serveur Gitea | `github.com:443` | miroirs (seule destination admise par Gitea, `EGRESS_MODE=strict`) |
| VM du runner | serveur Gitea, port 3000 | travaux, journaux, artefacts |
| VM du runner | `github.com`, `api.github.com`, `codeload.github.com`, `objects.githubusercontent.com`, `raw.githubusercontent.com` | actions épinglées, versions de Python, outils Grype et Syft, statuts de commit |
| VM du runner | `pypi.org`, `files.pythonhosted.org`, `registry.npmjs.org`, `nodejs.org` | dépendances Python et Node |
| VM du runner | `static.rust-lang.org`, `index.crates.io`, `static.crates.io` | chaîne Rust et crates (Coquelicot) |
| VM du runner | `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com`, `ghcr.io`, `pkg-containers.githubusercontent.com` | images de base, ZAP |
| VM du runner | `grype.anchore.io`, `toolbox-data.anchore.io` | base de vulnérabilités de Grype |
| VM du runner | miroirs Ubuntu, `dl.gitea.com` | installation |
| Postes des analystes | serveur Gitea, port 3000 | consultation des journaux |

Derrière un proxy sortant : `GITEA_PROXY_*` dans `serveur/.env`, et `--proxy` à l'installation du runner.

## 2. Serveur Gitea

```sh
cd serveur
cp .env.exemple .env           # GITEA_DOMAIN (nom présent dans le certificat), GITEA_BIND (adresse du réseau interne)
./preparer.sh                  # secrets aléatoires + certificat auto-signé (ou --cert-existant avec vos cert.pem/key.pem)
docker compose up -d           # ou : podman compose up -d
# Jeton GitHub dans un fichier lisible de vous seul (ou omettez l'option pour le saisir sans écho)
install -m 600 /dev/null deploy/secrets/github_token && nano deploy/secrets/github_token
./amorcer.sh --admin yo --email <adresse> --jeton-github-fichier deploy/secrets/github_token
```

`amorcer.sh` est idempotent. Il crée :

- le compte administrateur, avec un mot de passe aléatoire affiché une fois et à changer à la première connexion ;
  activez ensuite la double authentification ;
- l'organisation privée `tikalim` ;
- les trois miroirs, Actions activé ;
- le secret `GH_STATUS_TOKEN` et la variable `DEPOT_GITHUB`.

Il affiche enfin le **jeton d'inscription du runner**.

Durcissement du serveur :

- HTTPS natif, sans SSH ;
- inscription fermée, consultation réservée aux comptes ;
- conteneurs en lecture seule, sans capacités, sans élévation de privilèges ;
- base sans port publié et sans accès sortant ;
- destinations sortantes limitées à `github.com`.

## 3. Runner

Sur la VM dédiée, en root, après y avoir copié le dossier `runner/` et `serveur/deploy/certs/cert.pem` :

```sh
cd runner
sudo ./installer-runner.sh --gitea https://<GITEA_DOMAIN>:3000 --jeton <jeton affiché par amorcer.sh> --ca cert.pem
```

Le script installe :

- Docker (buildx, compose), Podman sans privilèges, Python 3, les outils de construction et 7-Zip ;
- rustup, épinglé et vérifié ;
- le runner, inscrit auprès de l'organisation avec le label `ci-hote` ;
- le service `gitea-runner` et une purge hebdomadaire des images de plus de 7 jours.

Choix d'exécution :

- **Mode hôte, un job à la fois.** Les workflows supposent, comme GitHub, une machine propre à chaque job : noms de
  conteneurs, volumes et ports fixes. Le runner nettoie conteneurs, volumes et réseaux après chaque job et au démarrage.
- **Garde-fou disque.** Pas de nouveau job sous 20 Go libres.
- **Journaux.** Une copie de chaque journal de job est gardée 14 jours dans `/var/log/gitea-runner/jobs`.

## 4. Dépôts

Chaque plateforme reçoit `.gitea/workflows/ci.yml` et `.gitea/statut-github.sh`. **Gitea lit `.gitea/workflows` et
ignore alors `.github/workflows`**, qui reste en place pour GitHub. Le fichier Gitea est **généré** depuis celui de
GitHub, qui reste la source de vérité des contrôles :

```sh
python3 workflows/generer.py ../marguerite              # écrit .gitea/workflows/ci.yml et .gitea/statut-github.sh
python3 workflows/generer.py ../marguerite --verifier   # échoue si le fichier n'est plus à jour
```

Adaptations faites par le générateur, et rien d'autre :

- déclencheurs : toute branche reçue et lancement manuel ;
- label `ci-hote` ;
- jobs « ouverture » (statut en cours) et « bilan » (résultat sur GitHub) ;
- pas de `sudo` ;
- service PostgreSQL de Bleuet lancé en conteneur.

Un motif inattendu fait échouer la génération plutôt que de produire un fichier faux.

Une fois ces fichiers fusionnés sur `main` et le runner en ligne, lancez un premier passage sur `main` :
`./amorcer.sh --admin yo --email <adresse> --lancer`. Les branches déjà présentes à la création du miroir ne sont
contrôlées qu'à leur prochain commit ; on peut aussi les lancer depuis l'interface (dépôt › Actions › CI › lancer).

## 5. Au quotidien

- Une branche poussée sur GitHub est contrôlée dans les 2 minutes qui suivent. Le statut `gitea-ci` apparaît sur le
  commit et la PR. Son lien mène au détail dans Gitea, joignable depuis le réseau interne seulement.
- Pour relancer, utilisez l'interface Gitea (dépôt › Actions › relancer) ou poussez un nouveau commit.
- Un nouveau commit sur la même branche annule le passage en cours (`concurrency`).

## 6. Exploitation

| Tâche | Comment |
|---|---|
| Mettre à jour Gitea ou PostgreSQL | Changer tag et empreinte dans `serveur/docker-compose.yml` (`docker pull`, puis `docker image inspect --format '{{index .RepoDigests 0}}'`), puis `compose up -d`. Lire les notes de version avant un changement de version majeure. |
| Mettre à jour le runner | Changer `RUNNER_VERSION` et `RUNNER_SHA256` (fichier `.sha256` publié sur dl.gitea.com), puis relancer `installer-runner.sh` : l'inscription est conservée. |
| Renouveler le jeton GitHub | Relancer `amorcer.sh` avec le nouveau jeton, ce qui met à jour le secret des statuts. Mettre aussi à jour les identifiants de chaque miroir : dépôt › Paramètres › Miroir. |
| Ajouter un dépôt | Ajouter le dépôt au jeton GitHub, puis `amorcer.sh --depots "<dépôt>"`, puis `generer.py` dans ce dépôt. |
| Sauvegarder | Peu critique : les miroirs se reconstituent depuis GitHub. Pour garder l'historique des passages : `docker compose exec gitea gitea dump`, ou `pg_dump` de la base `gitea`. |
| Docker Hub limite les téléchargements anonymes | Si la VM partage son adresse avec d'autres machines, configurez un miroir de registre (`registry-mirrors` dans `/etc/docker/daemon.json`) ou un compte Docker Hub pour `ci`. |

## 7. Sécurité

- **VM du runner = machine de confiance moyenne.** Les jobs exécutent le code des branches poussées sur GitHub. Seuls
  vous et vos sessions de travail y poussent ; un tiers qui obtiendrait ce droit exécuterait du code sur la VM.
  L'utilisateur `ci` est dans le groupe `docker`, donc équivalent root sur la VM. La VM ne doit avoir ni accès à la
  production, ni secret autre que ceux de la CI.
- **Secret `GH_STATUS_TOKEN`.** Il est visible des jobs : c'est pourquoi le jeton GitHub se limite à la lecture du code
  et à l'écriture des statuts, sur trois dépôts. Le script de statut le passe par un fichier temporaire, jamais sur une
  ligne de commande.
- **Runner propre à l'organisation.** Inscrit auprès de l'organisation `tikalim`, il ne sert aucun autre dépôt.
- **Flux.** HTTPS vérifié entre le runner et Gitea : l'autorité est installée sur la VM, y compris pour Node.js.
- **Sorties de Gitea.** Limitées à `github.com`, sans webhook ni connexion OAuth sortante.

## 8. Différences avec GitHub Actions

- **Pas d'événement `pull_request`.** Les PR vivent sur GitHub : c'est le commit de la branche qui est contrôlé.
- **Annotations ignorées.** Les annotations `::error file=…` et la mise en forme de ruff (`--output-format=github`)
  restent lisibles dans le journal, sans marque sur les lignes de code.
- **Résultat consultable sur le réseau interne seulement.** Sur GitHub, seul le statut et sa description sont visibles.
