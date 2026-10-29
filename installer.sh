#!/usr/bin/env bash
# Installeur d'un serveur de production ecluse.
#
# Généré par `make installeur` depuis ecluse@222cfb06469ab1f33360a0e46ab1a62a2ff5cfad — ne pas modifier ici :
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

COMMIT="222cfb06469ab1f33360a0e46ab1a62a2ff5cfad"
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
r4EuABgBAA==
