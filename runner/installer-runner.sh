#!/usr/bin/env bash
# Installation du runner de la CI Blue team sur une VM DÉDIÉE Ubuntu 24.04 (root). Idempotent.
#   sudo ./installer-runner.sh --gitea https://gitea-ci.interne.exemple:3000 --jeton <jeton d'inscription> \
#        [--ca cert.pem] [--nom ci-1] [--proxy http://proxy:3128]
# Installe : Docker (+ buildx, compose), Podman sans privilèges, Python 3, outils de construction, 7-Zip, Rust (rustup
# épinglé et vérifié), Gitea Runner 5.2.2 (empreinte vérifiée), service systemd, nettoyage après chaque job.
# L'utilisateur ci est dans le groupe docker, donc équivalent root SUR CETTE VM : elle ne doit servir qu'à la CI.
set -euo pipefail
cd "$(dirname "$0")"

RUNNER_VERSION=5.2.2
RUNNER_SHA256=5a2639fd2a57feeba29a9b1fb0e941489f092a4fa681c7c333c0372731248b63   # gitea-runner-5.2.2-linux-amd64
RUSTUP_VERSION=1.29.2
RUSTUP_SHA256=5be191e8c70a5007074254cb74d78dbfdd25cd5a61c27de7b8e5410122ec24f4   # rustup-init x86_64-unknown-linux-gnu

GITEA="" JETON="" CA="" NOM="$(hostname -s)" PROXY="" FORCER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --gitea) GITEA=${2%/}; shift 2 ;;
    --jeton) JETON=$2; shift 2 ;;
    --jeton-fichier) JETON=$(tr -d '\r\n' < "$2"); shift 2 ;;
    --ca) CA=$2; shift 2 ;;
    --nom) NOM=$2; shift 2 ;;
    --proxy) PROXY=$2; shift 2 ;;
    --forcer) FORCER=1; shift ;;        # machine qui a déjà des conteneurs (déconseillé)
    *) echo "Option inconnue : $1" >&2; exit 2 ;;
  esac
done
[ "$(id -u)" = 0 ] || { echo "À lancer en root (sudo)" >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "VM x86_64 attendue" >&2; exit 1; }
[[ "$GITEA" == https://* ]] || { echo "--gitea https://… requis" >&2; exit 2; }
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = ubuntu ] || echo "ATTENTION : script écrit pour Ubuntu 24.04 (détecté : ${PRETTY_NAME:-inconnu})" >&2

# Le nettoyage après chaque job retire TOUS les conteneurs et volumes non étiquetés ci.conserver=true : une machine qui
# en héberge déjà (serveur Gitea, plateformes) les perdrait. Refus, sauf --forcer.
if [ ! -s /var/lib/gitea-runner/.runner ] && command -v docker >/dev/null && [ -n "$(docker ps -aq 2>/dev/null)" ] && [ "$FORCER" = 0 ]; then
  echo "Cette machine a déjà des conteneurs Docker : le runner retire tous les conteneurs et volumes après chaque job." >&2
  echo "Installez-le sur une VM dédiée à la CI (ou relancez avec --forcer en connaissance de cause)." >&2
  exit 1
fi

if [ -n "$PROXY" ]; then
  export http_proxy=$PROXY https_proxy=$PROXY HTTP_PROXY=$PROXY HTTPS_PROXY=$PROXY no_proxy="localhost,127.0.0.1,${GITEA#https://}"
fi

echo "1. Paquets"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
PKGS=(ca-certificates curl git jq xz-utils unzip zip 7zip build-essential pkg-config libssl-dev
      python3 python3-venv python3-pip podman uidmap slirp4netns fuse-overlayfs)
if command -v docker >/dev/null; then
  echo "   Docker déjà installé ($(docker --version)) : conservé"   # Docker CE (containerd.io) exclut le paquet docker.io
else
  PKGS+=(docker.io docker-buildx docker-compose-v2)
fi
apt-get install -y -q "${PKGS[@]}"
docker buildx version >/dev/null 2>&1 || { echo "Greffon docker buildx manquant" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "Greffon docker compose manquant" >&2; exit 1; }
systemctl enable --now docker

if [ -n "$CA" ]; then
  echo "2. Autorité du certificat de Gitea"
  install -m 644 "$CA" /usr/local/share/ca-certificates/gitea-ci.crt
  update-ca-certificates >/dev/null
fi

echo "3. Utilisateur ci"
id ci >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/gitea-runner --shell /bin/bash ci
usermod -aG docker ci
# Podman sans privilèges : plages d'UID et GID subordonnées (un compte système n'en reçoit pas d'office)
grep -q '^ci:' /etc/subuid || usermod --add-subuids 200000-265535 ci
grep -q '^ci:' /etc/subgid || usermod --add-subgids 200000-265535 ci
loginctl enable-linger ci                         # session utilisateur de ci (Podman) sans connexion
install -d -o ci -g ci -m 750 /var/lib/gitea-runner/travail /var/lib/gitea-runner/cache /var/log/gitea-runner /var/log/gitea-runner/jobs

if [ -n "$PROXY" ]; then
  # Proxy aussi pour les constructions d'images et les conteneurs des jobs (pip, npm, apk dans les Dockerfile)
  install -d -o ci -g ci -m 700 /var/lib/gitea-runner/.docker
  jq -n --arg p "$PROXY" --arg n "localhost,127.0.0.1" '{proxies:{default:{httpProxy:$p, httpsProxy:$p, noProxy:$n}}}' \
    > /var/lib/gitea-runner/.docker/config.json
  chown ci:ci /var/lib/gitea-runner/.docker/config.json
  install -d /etc/systemd/system/docker.service.d
  printf '[Service]\nEnvironment="HTTP_PROXY=%s" "HTTPS_PROXY=%s" "NO_PROXY=localhost,127.0.0.1"\n' "$PROXY" "$PROXY" \
    > /etc/systemd/system/docker.service.d/proxy.conf
  systemctl daemon-reload; systemctl restart docker
fi

echo "4. Rust (rustup $RUSTUP_VERSION, empreinte vérifiée)"
if [ ! -x /var/lib/gitea-runner/.cargo/bin/rustup ]; then
  t=$(mktemp -d); trap 'rm -rf "$t"' EXIT; chmod 755 "$t"      # lisible par ci, qui lance l'installateur
  curl -fsSL --proto '=https' -o "$t/rustup-init" \
    "https://static.rust-lang.org/rustup/archive/$RUSTUP_VERSION/x86_64-unknown-linux-gnu/rustup-init"
  echo "$RUSTUP_SHA256  $t/rustup-init" | sha256sum -c --quiet
  chmod 755 "$t/rustup-init"
  sudo -u ci -H "$t/rustup-init" -y --no-modify-path --profile minimal --default-toolchain none
fi
# Chaîne choisie par chaque workflow (rustup toolchain install …) ; PATH du service ci-dessous

echo "5. Gitea Runner $RUNNER_VERSION (empreinte vérifiée)"
if ! /usr/local/bin/gitea-runner --version 2>/dev/null | grep -q "v$RUNNER_VERSION"; then
  curl -fsSL --proto '=https' -o /tmp/gitea-runner \
    "https://dl.gitea.com/gitea-runner/$RUNNER_VERSION/gitea-runner-$RUNNER_VERSION-linux-amd64"
  echo "$RUNNER_SHA256  /tmp/gitea-runner" | sha256sum -c --quiet
  install -m 755 /tmp/gitea-runner /usr/local/bin/gitea-runner; rm -f /tmp/gitea-runner
fi
install -d -m 755 /etc/gitea-runner
install -m 644 config.yaml /etc/gitea-runner/config.yaml
install -D -m 755 nettoyage.sh /usr/local/libexec/gitea-ci-nettoyage

echo "6. Inscription auprès de $GITEA"
if [ -s /var/lib/gitea-runner/.runner ]; then
  echo "   déjà inscrit (supprimez /var/lib/gitea-runner/.runner pour réinscrire)"
else
  [ -n "$JETON" ] || { echo "--jeton requis pour la première inscription" >&2; exit 2; }
  sudo -u ci -H env ${PROXY:+https_proxy=$PROXY no_proxy=${GITEA#https://}} \
    /usr/local/bin/gitea-runner -c /etc/gitea-runner/config.yaml register --no-interactive \
    --instance "$GITEA" --token "$JETON" --name "$NOM" --labels "ci-hote:host"
fi

echo "7. Service systemd et purge hebdomadaire des images"
install -m 644 gitea-runner.service /etc/systemd/system/gitea-runner.service
install -d /etc/systemd/system/gitea-runner.service.d
{
  echo "[Service]"
  echo "Environment=PATH=/var/lib/gitea-runner/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  echo "Environment=XDG_RUNTIME_DIR=/run/user/$(id -u ci)"
  # Node.js (actions checkout, upload-artifact…) ignore le magasin du système : sans cela, le certificat de Gitea est refusé
  echo "Environment=NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt"
  [ -z "$PROXY" ] || echo "Environment=\"HTTP_PROXY=$PROXY\" \"HTTPS_PROXY=$PROXY\" \"http_proxy=$PROXY\" \"https_proxy=$PROXY\" \"NO_PROXY=localhost,127.0.0.1,${GITEA#https://}\" \"no_proxy=localhost,127.0.0.1,${GITEA#https://}\""
} > /etc/systemd/system/gitea-runner.service.d/environnement.conf
cat > /etc/systemd/system/gitea-ci-purge.service <<'EOF'
[Unit]
Description=Purge des images Docker et Podman de plus de 7 jours (CI Blue team)
[Service]
Type=oneshot
User=ci
Environment=XDG_RUNTIME_DIR=/run/user/%U
ExecStart=/bin/sh -c 'docker image prune -af --filter until=168h; podman image prune -af --filter until=168h || true'
EOF
cat > /etc/systemd/system/gitea-ci-purge.timer <<'EOF'
[Unit]
Description=Purge hebdomadaire des images de la CI
[Timer]
OnCalendar=Sun 03:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now gitea-runner.service gitea-ci-purge.timer
systemctl restart gitea-runner.service
sleep 3
systemctl --no-pager --lines=5 status gitea-runner.service || true
echo "Terminé : le runner « $NOM » (label ci-hote) doit apparaître en ligne dans Gitea (organisation › Paramètres › Actions › Runners)."
