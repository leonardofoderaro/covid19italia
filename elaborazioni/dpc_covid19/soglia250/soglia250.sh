#!/bin/bash

set -x
set -e
set -u
set -o pipefail

folder="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$folder"/rawdata
mkdir -p "$folder"/processing

URL="https://raw.githubusercontent.com/pcm-dpc/COVID-19/master/dati-regioni/dpc-covid19-ita-regioni.csv"

# scarica dati
wget -O "$folder"/rawdata/tmp_regioni.csv "$URL"

# se il db esiste, cancellalo
if [ -f "$folder"/rawdata/dpc_covid.db ]; then
  rm "$folder"/rawdata/dpc_covid.db
fi

# crea file sqlite e importa dati regionali
sqlite3 -separator ',' "$folder"/rawdata/dpc_covid.db ".import $folder/rawdata/tmp_regioni.csv dpc-covid19-ita-regioni"

# calcola somma nuovi contagi settimanali
echo '
-- elimina tabella se esiste
DROP TABLE IF EXISTS `soglia_duecentocinquanta`;
-- crea tabella con la somma dei nuovi casi della riga corrente + le 6 precedenti, raggruppate per regione
CREATE table `soglia_duecentocinquanta` AS
SELECT data,codice_regione,codice_nuts_2,denominazione_regione,SUM(nuovi_positivi)
OVER (PARTITION BY denominazione_regione
        ORDER BY data
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) nuoviContagiSettimanali
FROM `dpc-covid19-ita-regioni`
ORDER BY data ASC
' | sqlite3 "$folder"/rawdata/dpc_covid.db

# esporta tabella
sqlite3 -header -csv "$folder"/rawdata/dpc_covid.db "select * from soglia_duecentocinquanta" >"$folder"/processing/soglia_duecentocinquanta.csv

# aggiungi dati popolazione e calcula incidenza per 100.000 persone
mlr --csv join --ul -j codice_regione -f "$folder"/processing/soglia_duecentocinquanta.csv \
  then unsparsify \
  then put '$soglia250=int($nuoviContagiSettimanali/$OBS_VALUE*100000)' \
  then cut -x -f nuoviContagiSettimanali,ITTER107,TIME_PERIOD,OBS_VALUE,Name \
  then sort -f data,denominazione_regione ../../../risorse/popolazione_regioni.csv | sponge "$folder"/processing/soglia_duecentocinquanta.csv

# crea la versione wide, con una colonna per ogni regione
mlr --csv cut -f data,denominazione_regione,soglia250 \
  then reshape -s denominazione_regione,soglia250 \
  then sort -f data "$folder"/processing/soglia_duecentocinquanta.csv >"$folder"/processing/soglia_duecentocinquanta_wide.csv
