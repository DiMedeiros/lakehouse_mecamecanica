#!/usr/bin/env bash
# Cria o catálogo do projeto via SQL, fora do bundle.
#
# POR QUE NÃO ESTÁ NO BUNDLE: quando o workspace tem o Default Storage
# habilitado (comum em contas gratuitas/trial), a API do Unity Catalog
# recusa criar catálogo pelo bundle — ela exige uma MANAGED LOCATION que
# essa configuração não tem:
#   Error: Metastore storage root URL does not exist.
#          Default Storage is enabled in your account. (400 INVALID_STATE)
# O comando SQL funciona normalmente, então criamos o catálogo por aqui.
set -euo pipefail

PROFILE="${1:?Uso: $0 <profile> [catalogo]}"
CATALOG="${2:-lakehouse_mecamecanica}"

databricks experimental aitools tools query \
  "CREATE CATALOG IF NOT EXISTS ${CATALOG}" \
  --profile "$PROFILE"
