#!/usr/bin/env bash
# Build and start StockMate.  Requires: JDK 17+, Maven, PostgreSQL with the "stockmate" database created (see README).
set -e
cd "$(dirname "$0")"
(cd backend && mvn -q package -DskipTests)
exec java -jar backend/target/stockmate.jar
