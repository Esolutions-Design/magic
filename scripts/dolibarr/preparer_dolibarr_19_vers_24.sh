#!/usr/bin/env bash
# Preparation UNIQUEMENT. Ne modifie ni le code Dolibarr en production,
# ni ses documents, ni sa base de donnees.
# Usage: sudo bash preparer_dolibarr_19_vers_24.sh /chemin/vers/dolibarr/htdocs
set -Eeuo pipefail
umask 077

SOURCE_VERSION='19.0.2'
TARGET_VERSION='24.0.2'
ZIP_SHA256='c49eead725c745159e87fcf04bc78f46f79e8c175b94946b4b8199b14c181ae5'
ZIP_URL='https://sourceforge.net/projects/dolibarr/files/Dolibarr%20ERP-CRM/24.0.2/dolibarr-24.0.2.zip/download'
BACKUP_BASE='/root/sauvegardes-dolibarr'

fail() { printf '\nERREUR : %s\n' "$*" >&2; exit 1; }
note() { printf '\n==> %s\n' "$*"; }

if [[ $# -ne 1 ]]; then
    printf 'Utilisation : sudo bash %s /var/www/DOMAINE/web/dolibarr/htdocs\n' "$0" >&2
    exit 2
fi
[[ $EUID -eq 0 ]] || fail 'Executer en root.'
for bin in php readlink stat tar gzip curl unzip sha256sum df du find grep awk; do
    command -v "$bin" >/dev/null 2>&1 || fail "Commande manquante : $bin"
done

APP=$(readlink -f -- "$1")
[[ -d "$APP" && "$APP" != '/' ]] || fail "Repertoire Dolibarr incorrect : $APP"
CONF="$APP/conf/conf.php"
for required in "$CONF" "$APP/index.php" "$APP/filefunc.inc.php" "$APP/install/index.php"; do
    [[ -f "$required" ]] || fail "Fichier Dolibarr manquant : $required"
done

# Dolibarr 19 declare DOL_VERSION dans filefunc.inc.php. Ce n'est
# qu'a partir d'une version plus recente qu'il utilise version.inc.php.
OLD_VERSION=$(php -r '
    define("DOL_INC_FOR_VERSION_ERROR", 1);
    chdir(dirname($argv[1]));
    require $argv[1];
    if (!defined("DOL_VERSION")) exit(2);
    echo DOL_VERSION;
' "$APP/filefunc.inc.php") || fail 'Impossible de lire la version actuelle.'
[[ "$OLD_VERSION" == "$SOURCE_VERSION" ]] || fail "Version trouvee : $OLD_VERSION ; attendue : $SOURCE_VERSION. Aucune modification."

CONFIG=$(php -r '
    require $argv[1];
    $data = (string) ($dolibarr_main_data_root ?? "");
    $db = (string) ($dolibarr_main_db_name ?? "");
    $type = strtolower((string) ($dolibarr_main_db_type ?? "mysqli"));
    if ($data === "" || $db === "") exit(3);
    echo $data, "\n", $db, "\n", $type, "\n";
' "$CONF") || fail 'Dossier des documents ou nom de base absent dans conf.php.'
mapfile -t LINES <<< "$CONFIG"
DOCROOT=${LINES[0]:-}
DBNAME=${LINES[1]:-}
DBTYPE=${LINES[2]:-}
[[ "$DOCROOT" == /* && "$DOCROOT" != '/' && -d "$DOCROOT" ]] || fail "Repertoire des documents incorrect : $DOCROOT"
DOCROOT=$(readlink -f -- "$DOCROOT")
[[ "$DBTYPE" == 'mysqli' || "$DBTYPE" == 'mysql' ]] || fail "Type de base non pris en charge : $DBTYPE"
[[ -n "$DBNAME" ]] || fail 'Nom de base manquant.'

if command -v mariadb-dump >/dev/null 2>&1; then
    DUMP_CMD=mariadb-dump
elif command -v mysqldump >/dev/null 2>&1; then
    DUMP_CMD=mysqldump
else
    fail 'mariadb-dump ou mysqldump est indispensable.'
fi

note 'CONTROLES DE PREPARATION (sans toucher au site)'
printf 'Code                : %s\n' "$APP"
printf 'Version actuelle    : %s\n' "$OLD_VERSION"
printf 'Version cible       : %s\n' "$TARGET_VERSION"
printf 'Documents           : %s\n' "$DOCROOT"
printf 'Base                : %s\n' "$DBNAME"
printf 'PHP CLI             : %s\n' "$(php -r 'echo PHP_VERSION;')"
printf 'Espace disponible :\n'
df -h -- "$BACKUP_BASE" 2>/dev/null || df -h -- /root
# Refuse les environnements visiblement trop remplis pour les sauvegardes
# et la decompression de l'archive. La taille de la base reste inconnue.
FREE_KB=$(df -Pk -- /root | awk 'NR == 2 { print $4 }')
CODE_KB=$(du -sk -- "$APP" | awk '{ print $1 }')
DOC_KB=$(du -sk -- "$DOCROOT" | awk '{ print $1 }')
REQUIRED_KB=$((CODE_KB + DOC_KB + 1048576))
[[ "$FREE_KB" =~ ^[0-9]+$ ]] || fail 'Espace libre inconnu.'
if (( FREE_KB < REQUIRED_KB )); then
    fail "Espace disque probablement insuffisant pour sauvegarder (libre : $FREE_KB Ko, recommande : $REQUIRED_KB Ko)."
fi
printf '\nLes utilisateurs doivent arreter toute saisie pendant la sauvegarde.\n'
printf 'Aucun fichier de production ne sera remplace par cette preparation.\n'
read -r -p 'Lancer la sauvegarde et preparer la version 24.0.2 ? Taper OUI : ' CONFIRM
[[ "$CONFIRM" == 'OUI' ]] || fail 'Annule par utilisateur.'

mkdir -p -- "$BACKUP_BASE"
STAMP=$(date '+%Y%m%d-%H%M%S')
BACKUP="$BACKUP_BASE/facturation.esolutions-design.fr-$STAMP"
mkdir -p -- "$BACKUP/preparation"
chmod 700 "$BACKUP"
TMP_CNF=''
cleanup() {
    if [[ -n "$TMP_CNF" ]]; then
        rm -f -- "$TMP_CNF"
    fi
}
trap cleanup EXIT
TMP_CNF=$(mktemp "$BACKUP/preparation/.mysql-client-XXXXXX")
chmod 600 "$TMP_CNF"

# Le mot de passe de la base n'apparait jamais dans la ligne de commande.
php -r '
    require $argv[1];
    function q($value) { return "\"" . addcslashes((string) $value, "\\\"\n\r\t") . "\""; }
    $values = [
        "user" => (string) ($dolibarr_main_db_user ?? ""),
        "password" => (string) ($dolibarr_main_db_pass ?? ""),
        "host" => (string) ($dolibarr_main_db_host ?? "localhost")
    ];
    if (!empty($dolibarr_main_db_port)) {
        $values["port"] = (string) $dolibarr_main_db_port;
    }
    $out = "[client]\n";
    foreach ($values as $k => $v) $out .= $k . "=" . q($v) . "\n";
    if (file_put_contents($argv[2], $out) === false) exit(1);
' "$CONF" "$TMP_CNF" || fail 'Impossible de preparer la connexion MariaDB.'

note 'Sauvegarde SQL complete, transactionnelle pour les tables InnoDB'
"$DUMP_CMD" --defaults-extra-file="$TMP_CNF" \
    --single-transaction --quick --triggers --routines --events --hex-blob \
    "$DBNAME" | gzip -6 > "$BACKUP/base_avant_migration.sql.gz" \
    || fail "Echec de la sauvegarde SQL. Le code de production n'a pas ete modifie."
gzip -t "$BACKUP/base_avant_migration.sql.gz" || fail 'Sauvegarde SQL corrompue.'
# Un fichier gzip de 20 octets represente une entree vide, non une sauvegarde.
SQL_SIZE=$(stat -c '%s' "$BACKUP/base_avant_migration.sql.gz")
[[ "$SQL_SIZE" -gt 100 ]] || fail "Sauvegarde SQL suspecte ($SQL_SIZE octets)."

note 'Sauvegarde du code actuel, de conf.php et des modules personnalises'
tar -czpf "$BACKUP/code_avant_migration.tar.gz" -C "$APP" . \
    || fail 'Sauvegarde du code impossible.'
tar -tzf "$BACKUP/code_avant_migration.tar.gz" >/dev/null \
    || fail 'Archive du code illisible.'

case "$DOCROOT/" in
    "$APP/"*)
        note 'Les documents sont inclus dans la sauvegarde du code.'
        ;;
    *)
        note 'Sauvegarde separee de tous les documents, factures PDF et pieces jointes'
        tar -czpf "$BACKUP/documents_avant_migration.tar.gz" -C "$DOCROOT" . \
            || fail 'Sauvegarde des documents impossible.'
        tar -tzf "$BACKUP/documents_avant_migration.tar.gz" >/dev/null \
            || fail 'Archive des documents illisible.'
        ;;
esac

note 'Telechargement de Dolibarr officiel 24.0.2'
ZIP="$BACKUP/preparation/dolibarr-24.0.2.zip"
curl --fail --location --retry 3 --connect-timeout 30 \
    --output "$ZIP" "$ZIP_URL" || fail 'Telechargement impossible (site non modifie).'
printf '%s  %s\n' "$ZIP_SHA256" "$ZIP" | sha256sum --check --status \
    || fail 'Empreinte SHA-256 inattendue : archive refusee.'

note 'Verification et extraction de la nouvelle version dans la zone de preparation'
unzip -q "$ZIP" -d "$BACKUP/preparation/extrait" \
    || fail 'Archive ZIP corrompue.'
VERSION_FILE=$(find "$BACKUP/preparation/extrait" -type f -path '*/htdocs/version.inc.php' -print -quit)
[[ -n "$VERSION_FILE" ]] || fail 'version.inc.php de la version 24 introuvable dans le ZIP.'
NEW_APP=$(dirname "$VERSION_FILE")
[[ -f "$NEW_APP/index.php" && -f "$NEW_APP/filefunc.inc.php" ]] \
    || fail 'Arborescence Dolibarr 24 incomplete.'
NEW_VERSION=$(php -r 'require $argv[1]; echo defined("DOL_VERSION") ? DOL_VERSION : "";' "$VERSION_FILE") \
    || fail 'Impossible de lire la version cible.'
[[ "$NEW_VERSION" == "$TARGET_VERSION" ]] || fail "Version cible incorrecte : $NEW_VERSION"

# Cree un journal seulement apres verification de toutes les etapes.
cat > "$BACKUP/JOURNAL_PREPARATION.txt" <<EOF
Date : $(date -Is)
Installation : $APP
Version source : $OLD_VERSION
Version destination : $TARGET_VERSION
Base : $DBNAME
Documents : $DOCROOT
Sauvegarde SQL : VALIDEE
Sauvegarde code : VALIDEE
Sauvegarde documents : VALIDEE
Archive officielle SHA256 : VALIDEE
Fichiers 24.0.2 extraits : VALIDES
Migration base : NON EFFECTUEE
Remplacement du code : NON EFFECTUE
EOF

printf '\n=============================================================\n'
printf 'PREPARATION REUSSIE : aucune modification du site en production\n'
printf 'Sauvegardes et version 24 : %s\n' "$BACKUP"
printf 'Nouvelle arborescence : %s\n' "$NEW_APP"
printf 'Conserver ce dossier ; ne PAS lancer la migration SQL encore.\n'
printf '=============================================================\n'