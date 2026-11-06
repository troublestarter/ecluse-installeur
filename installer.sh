#!/usr/bin/env bash
# Installeur d'un serveur de production ecluse.
#
# Généré par `make installeur` depuis ecluse@71aa05a5abb35c7bbc724c59725ea542ce538ded — ne pas modifier ici :
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

COMMIT="71aa05a5abb35c7bbc724c59725ea542ce538ded"
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
/7z/ef/z/8/P/wMbMcl2AEABAA==
