#!/usr/bin/env bash
# Installeur d'un serveur de production ecluse.
#
# Généré par `make installeur` depuis ecluse@b2b2593fdf4e5a48b791bed4111cc39ecb3247ad — ne pas modifier ici :
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

COMMIT="b2b2593fdf4e5a48b791bed4111cc39ecb3247ad"
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
L0XkAoAAQAEA
