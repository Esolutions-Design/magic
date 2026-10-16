#!/usr/bin/env bash
# Correctif controle Dolibarr GRCO / MariaDB 10.1 : index ticket.barcode.
# Modifie exclusivement c1_fact_grco.llx_ticket, jamais les autres bases.
# Verifie structure + absence de tickets. Sauvegarde SQL de l'etat partiellement migre.
# Syntaxe: bash corriger_barcode_grco.sh --check|--apply
set -Eeuo pipefail
umask 077

fail() { printf 'ERREUR: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 1 && ( "$1" == --check || "$1" == --apply ) ]] || fail 'Usage : bash corriger_barcode_grco.sh --check|--apply'
[[ "$EUID" -eq 0 ]] || fail 'Executer en root.'

CONF='/var/www/clients/client1/web18/web/dolibarr/htdocs/conf/conf.php'
DOCROOT='/var/www/clients/client1/web18/web/dolibarr/documents'
BASE='/root/sauvegardes-dolibarr'
[[ -f "$CONF" ]] || fail "Configuration GRCO absente : $CONF"
[[ -d "$DOCROOT" ]] || fail "Documents GRCO absents : $DOCROOT"
[[ ! -e "$DOCROOT/upgrade.unlock" ]] || fail 'upgrade.unlock est present : arreter les migrations web et retirer ce verrou avant le correctif.'
[[ -d "$BASE" ]] || fail 'Repertoire de sauvegardes introuvable.'
for c in php gzip stat mktemp chmod date; do command -v "$c" >/dev/null || fail "Outil manquant : $c"; done

# Verification CLI + metadata en lecture seule. Relancee juste avant les deux ALTER.
check() {
    php -r '
        mysqli_report(MYSQLI_REPORT_OFF);
        require $argv[1];
        if (($dolibarr_main_db_name ?? "") !== "c1_fact_grco") { fwrite(STDERR, "Mauvaise base Dolibarr.\n"); exit(2); }
        $db = @new mysqli($dolibarr_main_db_host, $dolibarr_main_db_user, $dolibarr_main_db_pass, $dolibarr_main_db_name);
        if ($db->connect_errno) { fwrite(STDERR, "Connexion impossible.\n"); exit(2); }
        function queryone($db, $sql) {
            $r=$db->query($sql);
            if (!$r) { fwrite(STDERR, "Erreur verification : ".$db->error."\n"); exit(2); }
            return $r->fetch_assoc();
        }
        $s = queryone($db, "SELECT ENGINE, ROW_FORMAT FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=\x27llx_ticket\x27");
        $c = queryone($db, "SELECT COLUMN_TYPE, COLLATION_NAME, IS_NULLABLE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=\x27llx_ticket\x27 AND COLUMN_NAME=\x27barcode\x27");
        $n = queryone($db, "SELECT COUNT(*) AS total FROM llx_ticket");
        $i = queryone($db, "SELECT COUNT(*) AS total FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=\x27llx_ticket\x27 AND INDEX_NAME=\x27uk_ticket_barcode_barcode_type\x27");
        $v = queryone($db, "SELECT value FROM llx_const WHERE name=\x27MAIN_VERSION_LAST_UPGRADE\x27 LIMIT 1");
        echo "Base : c1_fact_grco; version DB : ".($v["value"] ?? "?")."\n";
        echo "Ticket : ".($s["ENGINE"] ?? "?")." / ".($s["ROW_FORMAT"] ?? "?")."\n";
        echo "Barcode : ".($c["COLUMN_TYPE"] ?? "?")." / ".($c["COLLATION_NAME"] ?? "?")." / NULL=".($c["IS_NULLABLE"] ?? "?")."\n";
        echo "Nombre de tickets : ".$n["total"]." ; index deja cree : ".$i["total"]."\n";
        if (!$s || $s["ENGINE"]!=="InnoDB" || $s["ROW_FORMAT"]!=="Compact"
            || !$c || $c["COLUMN_TYPE"]!=="varchar(255)" || $c["COLLATION_NAME"]!=="utf8mb4_general_ci"
            || $c["IS_NULLABLE"]!=="YES" || $n["total"]!=="0" || $i["total"]!=="0"
            || !$v || $v["value"]!=="19.0.2") {
            fwrite(STDERR, "Etat different de celui attendu : aucune modification.\n"); exit(2);
        }
        $db->close();
    ' "$CONF"
}

printf '\n=== Verification de securite GRCO ===\n'
check || fail 'Controle non valide. Aucune modification.'
if [[ "$1" == --check ]]; then
    printf '\nCONTROLE OK. --check na modifie ni base ni fichier.\n'
    printf 'La commande --apply sauvegardera et corrigera uniquement llx_ticket.barcode + son index.\n'
    exit 0
fi

printf '\nAttention : GRCO doit etre en maintenance, sans utilisateur actif.\n'
read -r -p 'Confirmer par le mot CORRIGER : ' answer
[[ "$answer" == CORRIGER ]] || fail 'Annule.'

for c in mysqldump mariadb-dump; do
    if command -v "$c" >/dev/null 2>&1; then DUMP="$c"; break; fi
done
[[ -n "${DUMP:-}" ]] || fail 'mysqldump ou mariadb-dump introuvable.'

# Fichier temporaire protege : le mot de passe ne figure ni dans la ligne de commande
# ni dans les journaux du script.
CNF=$(mktemp /root/grco-mysql-XXXXXX)
trap 'rm -f -- "$CNF"' EXIT
chmod 600 "$CNF"
php -r '
    require $argv[1];
    if (($dolibarr_main_db_name ?? "")!=="c1_fact_grco") exit(2);
    function q($v) { return "\"" . addcslashes((string)$v, "\\\"\n\r\t") . "\""; }
    $s="[client]\n";
    $s.="host=".q($dolibarr_main_db_host)."\n";
    $s.="user=".q($dolibarr_main_db_user)."\n";
    $s.="password=".q($dolibarr_main_db_pass)."\n";
    if (!empty($dolibarr_main_db_port)) $s.="port=".q($dolibarr_main_db_port)."\n";
    if (file_put_contents($argv[2], $s)===false) exit(3);
' "$CONF" "$CNF" || fail 'Echec configuration sauvegarde.'

DEST="$BASE/GRCO-etat-partiel-avant-correctif-$(date +%Y%m%d-%H%M%S).sql.gz"
printf '\n=== Sauvegarde de l etat SQL actuel ===\n'
"$DUMP" --defaults-extra-file="$CNF" --single-transaction --quick --triggers --routines --events --hex-blob c1_fact_grco | gzip -6 > "$DEST" || fail "Echec sauvegarde. Archive a inspecter : $DEST"
gzip -t "$DEST" || fail 'Archive sauvegarde illisible.'
[[ $(stat -c %s "$DEST") -gt 1000 ]] || fail 'Sauvegarde SQL anormalement petite.'
printf 'Sauvegarde valide : %s\n' "$DEST"

printf '\n=== Revalidation et correction de llx_ticket ===\n'
check || fail 'La base a change depuis le controle : aucun ALTER effectue.'
php -r '
    mysqli_report(MYSQLI_REPORT_OFF);
    require $argv[1];
    if (($dolibarr_main_db_name ?? "")!=="c1_fact_grco") exit(2);
    $db=@new mysqli($dolibarr_main_db_host,$dolibarr_main_db_user,$dolibarr_main_db_pass,$dolibarr_main_db_name);
    if ($db->connect_errno) { fwrite(STDERR,"Connexion impossible\n"); exit(2); }
    $statements=array(
       "ALTER TABLE llx_ticket MODIFY COLUMN barcode VARCHAR(255) CHARACTER SET latin1 COLLATE latin1_swedish_ci DEFAULT NULL",
       "ALTER TABLE llx_ticket ADD UNIQUE INDEX uk_ticket_barcode_barcode_type (barcode, fk_barcode_type, entity)"
    );
    foreach ($statements as $sql) {
        if (!$db->query($sql)) { fwrite(STDERR,"ECHEC SQL : ".$db->error."\n"); exit(3); }
        echo "Effectue : ".$sql."\n";
    }
    $r=$db->query("SELECT INDEX_NAME, COLUMN_NAME, SEQ_IN_INDEX FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=\x27llx_ticket\x27 AND INDEX_NAME=\x27uk_ticket_barcode_barcode_type\x27 ORDER BY SEQ_IN_INDEX");
    if (!$r || $r->num_rows!==3) { fwrite(STDERR,"Index incomplet : intervention manuelle requise.\n"); exit(4); }
    while ($a=$r->fetch_assoc()) echo json_encode($a)."\n";
    $db->close();
' "$CONF" || fail 'Correction inachevee : ne PAS relancer migration SQL ou le script de deploiement.'
printf '\nCORRECTIF APPLIQUE SUR GRCO. Esolutions intact.\n'
printf 'NE PAS relancer la migration 19->20 a ce stade. Examiner les autres erreurs avant de passer a upgrade2.\n'
