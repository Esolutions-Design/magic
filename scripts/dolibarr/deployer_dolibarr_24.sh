#!/usr/bin/env bash
# Dolibarr 19.0.2 -> 24.0.2 - phase 2 : deploiement du CODE uniquement.
# Ne migre pas la base de donnees, ne supprime pas les documents.
# Usage : bash deployer_dolibarr_24.sh --check /var/www/DOMAINE/web/dolibarr/htdocs
#         bash deployer_dolibarr_24.sh --apply /var/www/DOMAINE/web/dolibarr/htdocs
set -Eeuo pipefail
umask 077

fail() { printf '\nERREUR : %s\n' "$*" >&2; exit 1; }
note() { printf '\n==> %s\n' "$*"; }

[[ $# -eq 2 ]] || fail 'Usage : bash deployer_dolibarr_24.sh --check|--apply /chemin/dolibarr/htdocs'
MODE="$1"
[[ "$MODE" == '--check' || "$MODE" == '--apply' ]] || fail 'Utiliser --check ou --apply.'
[[ "${EUID}" -eq 0 ]] || fail 'Executer en root.'
for binary in readlink php sha256sum gzip tar stat df du rsync grep find sort date mv cp chown; do
    command -v "$binary" >/dev/null 2>&1 || fail "Commande manquante : $binary"
done

APP=$(readlink -f -- "$2")
[[ -d "$APP" && "$APP" != '/' ]] || fail "Chemin introuvable : $APP"
[[ -f "$APP/conf/conf.php" && -f "$APP/filefunc.inc.php" ]] || fail 'Installation source incomplete.'
PARENT=$(dirname -- "$APP")
BASE=$(basename -- "$APP")
[[ "$BASE" == 'htdocs' ]] || fail 'Le repertoire cible doit s appeler htdocs.'

OLD_VERSION=$(php -r '
    define("DOL_INC_FOR_VERSION_ERROR", 1);
    chdir(dirname($argv[1])); require $argv[1];
    if (!defined("DOL_VERSION")) exit(2); echo DOL_VERSION;
' "$APP/filefunc.inc.php") || fail 'Lecture de la version source impossible.'
[[ "$OLD_VERSION" == '19.0.2' ]] || fail "Version actuelle : $OLD_VERSION ; attendu : 19.0.2. Rien ne sera change."

CONFIG=$(php -r '
    require $argv[1];
    echo (string) ($dolibarr_main_data_root ?? ""), "\n";
    echo (string) ($dolibarr_main_db_name ?? ""), "\n";
    echo (string) ($dolibarr_main_url_root ?? ""), "\n";
' "$APP/conf/conf.php") || fail 'Configuration Dolibarr illisible.'
mapfile -t CFG <<< "$CONFIG"
DOCROOT=${CFG[0]:-}
DBNAME=${CFG[1]:-}
URL=${CFG[2]:-}
[[ "$DOCROOT" == /* && -d "$DOCROOT" && -n "$DBNAME" ]] || fail 'Documents ou base non identifies.'
DOCROOT=$(readlink -f -- "$DOCROOT")
[[ "$DOCROOT" != "$APP" && "$DOCROOT" != "$PARENT" ]] || fail 'Documents situes dans un repertoire de code : intervention manuelle requise.'

BACKUP_BASE='/root/sauvegardes-dolibarr'
[[ -d "$BACKUP_BASE" ]] || fail 'Sauvegardes introuvables. Executer la preparation officielle au prealable.'
mapfile -t MANIFESTS < <(find "$BACKUP_BASE" -mindepth 2 -maxdepth 2 -type f -name 'JOURNAL_PREPARATION.txt' -print | sort -r)
(( ${#MANIFESTS[@]} > 0 )) || fail 'Aucune preparation terminee ne possede de journal.'
BACKUP=''
for manifest in "${MANIFESTS[@]}"; do
    if grep -Fxq "Installation : $APP" "$manifest" \
      && grep -Fxq 'Version source : 19.0.2' "$manifest" \
      && grep -Fxq 'Version destination : 24.0.2' "$manifest" \
      && grep -Fxq "Documents : $DOCROOT" "$manifest" \
      && grep -Fxq "Base : $DBNAME" "$manifest" \
      && grep -Fxq 'Fichiers 24.0.2 extraits : VALIDES' "$manifest"; then
        BACKUP=$(dirname -- "$manifest")
        break
    fi
done
[[ -n "$BACKUP" ]] || fail 'Aucun journal de preparation valide pour CETTE installation.'
[[ ! -f "$BACKUP/JOURNAL_DEPLOIEMENT.txt" ]] || fail 'Le deploiement est deja journalise dans ce dossier. Verification manuelle requise.'

SQL="$BACKUP/base_avant_migration.sql.gz"
CODE="$BACKUP/code_avant_migration.tar.gz"
DOCS="$BACKUP/documents_avant_migration.tar.gz"
ZIP="$BACKUP/preparation/dolibarr-24.0.2.zip"
for f in "$SQL" "$CODE" "$DOCS" "$ZIP"; do
    [[ -s "$f" ]] || fail "Sauvegarde ou ZIP absent : $f"
done
[[ "$(stat -c %s -- "$SQL")" -gt 1000 ]] || fail 'Dump SQL anormalement petit.'
note 'Verification des sauvegardes et du package'
gzip -t "$SQL" || fail 'Dump SQL corrompu.'
tar -tzf "$CODE" >/dev/null || fail 'Archive du code corrompue.'
tar -tzf "$DOCS" >/dev/null || fail 'Archive des documents corrompue.'
printf '%s  %s\n' 'c49eead725c745159e87fcf04bc78f46f79e8c175b94946b4b8199b14c181ae5' "$ZIP" | sha256sum -c --status \
    || fail 'Empreinte du package Dolibarr 24.0.2 incorrecte.'
mapfile -t NEW_VERSIONS < <(find "$BACKUP/preparation/extrait" -type f -path '*/htdocs/version.inc.php' -print)
[[ ${#NEW_VERSIONS[@]} -eq 1 ]] || fail 'Repertoire Dolibarr 24 ambigu ou manquant.'
NEW_APP=$(dirname -- "${NEW_VERSIONS[0]}")
[[ -f "$NEW_APP/index.php" && -f "$NEW_APP/filefunc.inc.php" ]] || fail 'Dolibarr 24 incomplet.'
NEW_VERSION=$(php -r 'require $argv[1]; echo defined("DOL_VERSION") ? DOL_VERSION : "";' "${NEW_VERSIONS[0]}") \
    || fail 'Version nouvelle illisible.'
[[ "$NEW_VERSION" == '24.0.2' ]] || fail "Version du nouveau code incorrecte : $NEW_VERSION"

# Do not swap a directory with embedded user documents.
case "$DOCROOT/" in
    "$APP/"*) fail 'Les documents sont dans htdocs. Le deploiement doit etre adapte manuellement.' ;;
esac

OWNER=$(stat -c '%u:%g' -- "$APP")
STAGE_KB=$(du -sk -- "$NEW_APP" | awk '{print $1}')
FREE_KB=$(df -Pk -- "$PARENT" | awk 'NR == 2 { print $4 }')
[[ "$FREE_KB" =~ ^[0-9]+$ ]] || fail 'Impossible de determiner l espace libre.'
(( FREE_KB > STAGE_KB + 262144 )) || fail 'Espace libre insuffisant pour preparer le nouveau code.'

printf '\nInstallation  : %s\n' "$APP"
printf 'Actuel -> cible : %s -> %s\n' "$OLD_VERSION" "$NEW_VERSION"
printf 'Sauvegardes   : %s\n' "$BACKUP"
printf 'Documents    : %s (non modifies)\n' "$DOCROOT"
printf 'Base         : %s (non modifiee)\n' "$DBNAME"
printf 'Compte       : %s\n' "$OWNER"
printf 'URL          : %s\n' "${URL:-non fournie}"
if [[ -d "$APP/custom" ]]; then
    printf 'Modules       : htdocs/custom sera conserve\n'
else
    printf 'Modules       : pas de dossier htdocs/custom detecte\n'
fi
printf 'ATTENTION : toute modification directe des fichiers du coeur sera remplacee.\n'

if [[ "$MODE" == '--check' ]]; then
    printf '\nCONTROLES REUSSIS - AUCUN FICHIER DE PRODUCTION MODIFIE.\n'
    printf 'Ensuite, en fenetre de maintenance : bash %q --apply %q\n' "$0" "$APP"
    exit 0
fi

printf '\nLa base et les documents doivent etre hors utilisation.\n'
printf 'Le site ne doit pas rester accessible aux utilisateurs pendant la migration SQL.\n'
read -r -p 'Pour effectuer le remplacement du CODE, taper DEPLOYER : ' CONFIRM
[[ "$CONFIRM" == 'DEPLOYER' ]] || fail 'Operation annulee.'

# Garde l'ancien code ET la version en cours de preparation hors du dossier public.
# Les deux chemins doivent se trouver sur le meme filesystem pour un swap atomique.
[[ "$(stat -c %d -- "$BACKUP")" == "$(stat -c %d -- "$PARENT")" ]] \
    || fail 'Les sauvegardes sont sur un autre disque : bascule atomique impossible.'
STAGE="$BACKUP/htdocs-nouveau-24.0.2"
OLD_KEEP="$BACKUP/htdocs-code-19.0.2"
[[ ! -e "$STAGE" && ! -e "$OLD_KEEP" ]] || fail 'Un repertoire de deploiement existe deja.'

note 'Preparation de la nouvelle arborescence a cote de la production'
mkdir -m 0750 -- "$STAGE"
if ! rsync -a -- "$NEW_APP/" "$STAGE/"; then
    fail 'Copie du nouveau code echouee. Production intacte.'
fi
mkdir -p -- "$STAGE/conf"
cp -a -- "$APP/conf/conf.php" "$STAGE/conf/conf.php" || fail 'Copie conf.php impossible.'
if [[ -d "$APP/custom" ]]; then
    mkdir -p -- "$STAGE/custom"
    rsync -a -- "$APP/custom/" "$STAGE/custom/" || fail 'Copie des modules custom impossible.'
fi
chown -R -- "$OWNER" "$STAGE" || fail 'Attribution des droits impossible.'
[[ "$(sha256sum "$APP/conf/conf.php" | awk '{print $1}')" == "$(sha256sum "$STAGE/conf/conf.php" | awk '{print $1}')" ]] \
    || fail 'conf.php est different apres copie.'
[[ -f "$STAGE/version.inc.php" && -f "$STAGE/install/index.php" ]] || fail 'Arborescence de destination incomplete.'

note 'Remplacement des repertoires (les anciens sont conserves pour un retour arriere)'
mv -- "$APP" "$OLD_KEEP" || fail 'Impossible de renommer le code existant.'
if ! mv -- "$STAGE" "$APP"; then
    printf 'ECHEC du nouveau code ; tentative de restauration du repertoire precedent.\n' >&2
    mv -- "$OLD_KEEP" "$APP" || printf 'RESTAURATION MANUELLE REQUISE : %s -> %s\n' "$OLD_KEEP" "$APP" >&2
    exit 1
fi

cat > "$BACKUP/JOURNAL_DEPLOIEMENT.txt" <<EOF
Date : $(date -Is)
Code avant : $OLD_KEEP
Code nouveau : $APP
Base SQL : NON MIGREEE PAR CE SCRIPT
Repertoire documents : $DOCROOT (non modifie)
Sauvegardes : $BACKUP
EOF
printf '\nCODE DOLIBARR 24.0.2 DEPLOYE, BASE NON MIGREEE.\n'
printf 'Ancien code conserve : %s\n' "$OLD_KEEP"
printf 'Site a maintenir indisponible jusqu aux migrations et tests.\n'
printf '\nAutoriser TEMPORAIREMENT la migration en placant upgrade.unlock\n'
printf 'dans le repertoire DOCUMENTS, puis lancer l assistant depuis ton URL /install/index.php.\n'
printf 'Apres les migrations : retirer upgrade.unlock, recreer install.lock, tester le site.\n'
