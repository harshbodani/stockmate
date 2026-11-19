#!/usr/bin/env bash
# Recreate the StockMate database from scratch.  Usage: ./reset.sh [dbname]   (uses your normal psql settings)
set -e
DB=${1:-stockmate}
cd "$(dirname "$0")"
dropdb --if-exists "$DB"
createdb "$DB"
for f in schema functions seed; do psql -v ON_ERROR_STOP=1 -q -d "$DB" -f $f.sql; done
echo "Database '$DB' ready."
