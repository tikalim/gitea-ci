#!/usr/bin/env bash
# Prépare le déploiement du serveur Gitea : secrets aléatoires (jamais versionnés) et certificat HTTPS.
#   ./preparer.sh                 secrets manquants + certificat auto-signé si deploy/certs/ est vide
#   ./preparer.sh --cert-existant secrets seulement (cert.pem et key.pem déposés par vous, issus de votre PKI)
# Relancer le script ne remplace aucun secret existant (la base et les jetons en dépendent).
set -euo pipefail
cd "$(dirname "$0")"
umask 077

[ -f .env ] || { echo "Copiez d'abord .env.exemple en .env et renseignez GITEA_DOMAIN et GITEA_BIND." >&2; exit 1; }
set -a
# shellcheck disable=SC1091
. ./.env
set +a
: "${GITEA_DOMAIN:?GITEA_DOMAIN manquant dans .env}"

IMAGE=$(sed -n 's/^ *image: \(docker.gitea.com\/gitea:[^ ]*\).*/\1/p' docker-compose.yml | head -1)
RT=$(command -v docker || command -v podman) || { echo "Docker ou Podman requis" >&2; exit 1; }

mkdir -p deploy/secrets deploy/certs
secret() {   # secret <fichier> <commande produisant la valeur>
  local f="deploy/secrets/$1"; shift
  if [ -s "$f" ]; then echo "  $f : conservé"; return; fi
  "$@" | tr -d '\n' > "$f"; echo "  $f : créé"
}
echo "Secrets :"
secret gitea_db_password openssl rand -base64 32
secret gitea_secret_key "$RT" run --rm --entrypoint gitea "$IMAGE" generate secret SECRET_KEY
secret gitea_internal_token "$RT" run --rm --entrypoint gitea "$IMAGE" generate secret INTERNAL_TOKEN
chmod 600 deploy/secrets/*

# Gitea (image sans privilèges) lit les fichiers avec l'UID 1000 du conteneur
owner_1000() {
  if [ "$(id -u)" = 0 ]; then chown 1000:1000 "$@"
  elif [ "$(basename "$RT")" = podman ]; then podman unshare chown 1000:1000 "$@"
  else echo "  ATTENTION : rendez $* lisibles par l'UID 1000 (sudo chown 1000:1000 $*)" >&2; fi
}
owner_1000 deploy/secrets/gitea_secret_key deploy/secrets/gitea_internal_token deploy/secrets/gitea_db_password

if [ "${1:-}" != "--cert-existant" ] && [ ! -s deploy/certs/cert.pem ]; then
  echo "Certificat auto-signé pour $GITEA_DOMAIN (10 ans ; remplacez-le par un certificat de votre PKI si possible) :"
  SAN="DNS:$GITEA_DOMAIN"
  [[ "$GITEA_DOMAIN" =~ ^[0-9.]+$ ]] && SAN="IP:$GITEA_DOMAIN"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
    -subj "/CN=$GITEA_DOMAIN" -addext "subjectAltName=$SAN" \
    -keyout deploy/certs/key.pem -out deploy/certs/cert.pem 2>/dev/null
  echo "  deploy/certs/cert.pem : à installer comme autorité de confiance sur la VM du runner"
fi
[ -s deploy/certs/cert.pem ] && [ -s deploy/certs/key.pem ] || { echo "deploy/certs/cert.pem et key.pem attendus" >&2; exit 1; }
chmod 644 deploy/certs/cert.pem; chmod 600 deploy/certs/key.pem
owner_1000 deploy/certs/key.pem
echo "Prêt : $(basename "$RT") compose up -d, puis ./amorcer.sh"
