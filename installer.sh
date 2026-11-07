#!/usr/bin/env bash
# Installeur d'un serveur de production ecluse.
#
# Généré par `make installeur` depuis ecluse@ff2d4dd49bb60a98a14464e884c98fff08ba4fd4 — ne pas modifier ici :
# toute correction se fait dans le dépôt ecluse, puis se régénère.
#
# Usage (Ubuntu Server 24.04 neuve, en root) :
#   sudo bash installer.sh --nom <serveur> --version <x.y.z>
#
# `x.y.z` est le numéro commercial d'une version promue (0.3.0) : c'est la
# forme à employer (drubio, 26/10). Le numéro technique `AAAA.MM.JJ-commit7`
# reste accepté, pour un déploiement de test.
#
# Ce qu'il fait, et que relancer la même commande reprend là où il s'était
# arrêté :
#   1. prépare la machine (Docker du dépôt officiel, outils, pas de swap, UTC),
#      sans registre public : les outils viendront de notre registre ;
#      crée le compte `ecluse` et /opt/ecluse ;
#   2. crée l'identité du serveur au registre et affiche l'encadré à envoyer ;
#   3. attend l'acceptation ;
#   4. pose la configuration de la version, signée PROD et vérifiée ;
#   5. puis passe la main à l'installation de la version (réglages,
#      premier démarrage) ;
#   6. installe l'agent de mise à jour (unité systemd sous le compte
#      `ecluse`), si la version le porte.
#
# Aucun secret ici : la clé publique PROD et l'outillage, embarqués à
# l'identique depuis le dépôt (charge utile en fin de fichier).

set -euo pipefail

COMMIT="ff2d4dd49bb60a98a14464e884c98fff08ba4fd4"
NOM=""
ECLUSE_VERSION=""
REGISTRE="${ECLUSE_REGISTRE:-ecluse-registry.my-cosi.info}"
DOSSIER=/opt/ecluse
COMPTE=ecluse

usage() {
  echo "usage : sudo bash $0 --nom <serveur> --version <x.y.z>" >&2
  echo "        (x.y.z : numéro d'une version promue ; AAAA.MM.JJ-commit7 pour un essai)" >&2
  exit 2
}
while [ $# -gt 0 ]; do
  case "$1" in
    --nom) NOM="${2:-}"; shift 2 ;;
    --version) ECLUSE_VERSION="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$NOM" ] && [ -n "$ECLUSE_VERSION" ] || usage
[[ "$NOM" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || { echo "nom de serveur invalide : $NOM" >&2; exit 2; }
[[ "$ECLUSE_VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+|[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9a-f]{7})$ ]] \
  || { echo "version invalide : $ECLUSE_VERSION (attendu x.y.z ou AAAA.MM.JJ-commit7)" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "à lancer avec sudo : la préparation de la machine l'exige" >&2; exit 2; }
SHA_INSTALLEUR="$(sha256sum "$0" | cut -d' ' -f1)"

etape() { printf '\n\033[1m── %s\033[0m\n' "$*"; }

# ── 1. La machine (docs/12 § 1 bis) ─────────────────────────────────────────
etape "1. Préparation de la machine"
# **Lu dans un sous-shell, clé par clé** : `/etc/os-release` définit VERSION,
# NAME, ID… Sourcé ici, il remplaçait la version demandée par
# « 24.04.3 LTS (Noble Numbat) » (premier essai sur essai1, 26/10).
OS_RELEASE=/etc/os-release
os_release() {
  ( . "$OS_RELEASE"
    case "$1" in
      ID) printf '%s' "${ID:-}" ;;
      VERSION_CODENAME) printf '%s' "${VERSION_CODENAME:-}" ;;
    esac )
}
OS_ID="$(os_release ID)"
OS_CODENAME="$(os_release VERSION_CODENAME)"
[ "$OS_ID" = ubuntu ] || { echo "Ubuntu Server attendu (trouvé : ${OS_ID:-?})" >&2; exit 1; }

# `mkpasswd` (paquet whois) calcule l'empreinte de l'identité : aucune image
# n'est tirée avant l'acceptation par le registre.
for outil in dig make python3 mkpasswd curl; do
  if ! command -v "$outil" >/dev/null; then
    apt-get update -q
    apt-get install -y -q make python3 bind9-dnsutils whois curl ca-certificates
    break
  fi
done

# Docker installé par snap (proposé à l'installation d'Ubuntu Server) : il
# est confiné et ne voit pas /opt/ecluse, et `docker compose version` y
# répond — il passerait donc pour le bon. On le retire, en le disant, au
# profit du paquet officiel (consigne de drubio, 25/10 : « l'outil n'a qu'à
# gérer cela »). Seul refus : des conteneurs qui tournent sous ce snap, que
# le retrait arrêterait — ce n'est plus une machine neuve.
retirer_le_docker_du_snap() {
  command -v snap >/dev/null 2>&1 || return 0
  snap list docker >/dev/null 2>&1 || return 0
  local actifs
  actifs="$(docker ps -q 2>/dev/null | wc -l)"
  if [ "$actifs" -gt 0 ]; then
    echo "Docker est installé par snap et $actifs conteneur(s) y tournent : le retirer les arrêterait." >&2
    echo "Ce n'est pas une machine neuve. Arrêtez-les ou retirez le snap vous-même (sudo snap remove --purge docker), puis relancez." >&2
    exit 1
  fi
  echo "Docker installé par snap détecté : il est retiré (confiné, il ne voit pas $DOSSIER)."
  echo "Le paquet officiel de Docker le remplace."
  snap remove --purge docker
  hash -r
}
retirer_le_docker_du_snap

if ! docker compose version >/dev/null 2>&1; then
  for p in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    apt-get remove -y -q "$p" >/dev/null 2>&1 || true
  done
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${OS_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi
echo "Docker $(docker version --format '{{.Server.Version}}'), $(docker compose version --short)"

# Sur tout serveur, avec ou sans swap (drubio, 28/10 : une seule règle) : un
# swap ajouté plus tard par l'hébergeur ne doit pas trouver `clamd` et les
# autres prêts à partir sur disque (CLAUDE.md § 8.4).
SYSCTL_ECLUSE=/etc/sysctl.d/99-ecluse.conf
echo 'vm.swappiness=1' > "$SYSCTL_ECLUSE"
sysctl -q -p "$SYSCTL_ECLUSE"
echo "vm.swappiness=1 (CLAUDE.md § 8.4)"
timedatectl set-timezone UTC

if ! id "$COMPTE" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$COMPTE"
fi
usermod -aG docker "$COMPTE"
install -d -o "$COMPTE" -g "$COMPTE" -m 0750 "$DOSSIER"
# Le dossier où root seul pose ce que l'agent lit sans pouvoir l'écrire —
# le fichier d'échec volontaire (retour arrière éprouvé en production).
install -d -o root -g root -m 0755 /etc/ecluse
# Ce que `compose.yaml` monte sans que la configuration publiée le porte :
# absent au premier `up`, Docker le crée en root, et l'agent ne peut plus y
# écrire — essai1, 27/10 : la mise à jour vers 0.3.2 refusée deux fois sur
# « Permission denied ». `install -d` rend aussi le bon propriétaire à un
# dossier déjà là. 0755 : les conteneurs lisent sous un autre compte.
# `infra/rspamd/plugins` est vide, donc absent de l'archive (git ne garde
# pas un dossier vide) : même sort sur essai1.
install -d -o "$COMPTE" -g "$COMPTE" -m 0755 "$DOSSIER/.maintenance"
install -d -o "$COMPTE" -g "$COMPTE" -m 0755 "$DOSSIER/infra" "$DOSSIER/infra/rspamd"
install -d -o "$COMPTE" -g "$COMPTE" -m 0755 "$DOSSIER/infra/rspamd/plugins"

# ── 2 à 5. Sous le compte `ecluse`, avec l'outillage embarqué ───────────────
AMORCE="$(mktemp -d)"
trap 'rm -rf "$AMORCE"' EXIT
sed -n '/^__CHARGE_UTILE__$/,$p' "$0" | tail -n +2 | base64 -d | tar -xz -C "$AMORCE"
chown -R "$COMPTE:$COMPTE" "$AMORCE"

cd "$AMORCE"
sudo -u "$COMPTE" -H \
  ECLUSE_REGISTRE="$REGISTRE" \
  ECLUSE_DOSSIER="$DOSSIER" \
  ECLUSE_INSTALLEUR="ecluse-installeur, ecluse@${COMMIT:0:7}, sha256 ${SHA_INSTALLEUR}" \
  python3 -m tools.maj.amorce --nom "$NOM" --version "$ECLUSE_VERSION"

# ── 6. L'agent de mise à jour, en root : son unité systemd ─────────────────
# Depuis la configuration installée et signée, pas depuis l'amorce. Une
# version d'avant l'agent (0.1.0, 0.2.0) ne le porte pas : on le dit, sans
# échouer — il se posera après la mise à jour qui l'apporte.
cd "$DOSSIER"
# `-B` : python lancé en root n'écrit aucun `__pycache__` sous le dossier
# (essai1, 27/10 : un `.pyc` en root sous tools/maj — la famille du retour
# arrière du 23/10, CLAUDE.md § 8.4).
if [ -f tools/maj/agent_installer.py ]; then
  python3 -B -m tools.maj.agent_installer --compte "$COMPTE" --dossier "$DOSSIER"
else
  echo "cette version ne porte pas l'agent de mise à jour : il s'installera après"
fi
# Rien ne reste en root sous le dossier : l'agent, au compte `ecluse`, y
# réécrit la configuration à chaque mise à jour.
chown -R "$COMPTE:$COMPTE" "$DOSSIER"
exit 0
__CHARGE_UTILE__
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
G07mAEABAA==
