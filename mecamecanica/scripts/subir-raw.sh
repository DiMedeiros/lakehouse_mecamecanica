#!/usr/bin/env bash
# Sobe os CSVs de dados/erp e dados/crm (raiz do repositório) para o Volume
# bronze.raw. O Volume precisa já existir (rode `databricks bundle deploy`
# antes) e o comando exige o esquema `dbfs:` no destino, mesmo apontando
# para um Volume do Unity Catalog.
set -euo pipefail

PROFILE="${1:?Uso: $0 <profile> [catalogo]}"
CATALOG="${2:-lakehouse_mecamecanica}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DADOS_DIR="$REPO_ROOT/dados"

for sistema in erp crm; do
  databricks fs cp --recursive --overwrite \
    "$DADOS_DIR/$sistema" \
    "dbfs:/Volumes/${CATALOG}/bronze/raw/${sistema}" \
    --profile "$PROFILE"
done
