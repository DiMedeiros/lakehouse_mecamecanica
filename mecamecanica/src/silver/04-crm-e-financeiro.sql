-- Silver — CRM e financeiro: vendedores, carteira, oportunidades, visitas,
-- pagamentos, estoque.
--
-- Ordem importa: carteira faz LEFT JOIN em vendedores, que precisa existir
-- primeiro neste script.

CREATE OR REPLACE TABLE lakehouse_mecamecanica.silver.vendedores
COMMENT 'Vendedores tipados. data_desligamento fica NULL quando o vendedor está ativo (a origem usa string vazia como sentinela).'
AS
WITH origem AS (
  SELECT COUNT(*) AS n FROM lakehouse_mecamecanica.bronze.vendedores
)
SELECT
  b.vendedor_id,
  b.nome,
  b.regiao,
  b.uf,
  coalesce(
    try_to_date(b.data_admissao, 'yyyy-MM-dd'),
    try_to_date(b.data_admissao, 'dd/MM/yyyy')
  ) AS data_admissao,
  coalesce(
    try_to_date(b.data_desligamento, 'yyyy-MM-dd'),
    try_to_date(b.data_desligamento, 'dd/MM/yyyy')
  ) AS data_desligamento,
  try_cast(nullif(b.meta_mensal, '') AS DECIMAL(18,2)) AS meta_mensal,
  current_timestamp() AS _processado_em,
  origem.n AS _linhas_origem
FROM lakehouse_mecamecanica.bronze.vendedores b
CROSS JOIN origem;

CREATE OR REPLACE TABLE lakehouse_mecamecanica.silver.carteira
COMMENT 'Carteira de clientes por vendedor. Não corrige carteira de vendedor desligado — expõe o problema em orfao_vendedor_desligado para o gestor decidir.'
AS
WITH origem AS (
  SELECT COUNT(*) AS n FROM lakehouse_mecamecanica.bronze.carteira
)
SELECT
  b.carteira_id,
  b.cliente_id,
  b.vendedor_id,
  coalesce(
    try_to_date(b.data_inicio, 'yyyy-MM-dd'),
    try_to_date(b.data_inicio, 'dd/MM/yyyy')
  ) AS data_inicio,
  coalesce(
    try_to_date(b.data_fim, 'yyyy-MM-dd'),
    try_to_date(b.data_fim, 'dd/MM/yyyy')
  ) AS data_fim,
  (
    coalesce(try_to_date(b.data_fim, 'yyyy-MM-dd'), try_to_date(b.data_fim, 'dd/MM/yyyy')) IS NULL
    AND v.vendedor_id IS NOT NULL
    AND v.data_desligamento IS NULL
  ) AS vigente,
  (
    coalesce(try_to_date(b.data_fim, 'yyyy-MM-dd'), try_to_date(b.data_fim, 'dd/MM/yyyy')) IS NULL
    AND v.data_desligamento IS NOT NULL
  ) AS orfao_vendedor_desligado,
  current_timestamp() AS _processado_em,
  origem.n AS _linhas_origem
FROM lakehouse_mecamecanica.bronze.carteira b
CROSS JOIN origem
LEFT JOIN lakehouse_mecamecanica.silver.vendedores v ON v.vendedor_id = b.vendedor_id;

COMMENT ON COLUMN lakehouse_mecamecanica.silver.carteira.vigente IS
  'true quando a carteira não tem data_fim E o vendedor associado existe e não está desligado.';

COMMENT ON COLUMN lakehouse_mecamecanica.silver.carteira.orfao_vendedor_desligado IS
  'true quando a carteira segue sem data_fim, mas o vendedor associado já foi desligado — dado não corrigido de propósito, para o gestor decidir o que fazer.';

CREATE OR REPLACE TABLE lakehouse_mecamecanica.silver.oportunidades
COMMENT 'Oportunidades de venda tipadas. Etapas de origem confirmadas por SELECT DISTINCT: ''Fechado ganho'' e ''Fechado perdido'' (não ''Ganha''/''Perdida'').'
AS
WITH origem AS (
  SELECT COUNT(*) AS n FROM lakehouse_mecamecanica.bronze.oportunidades
)
SELECT
  b.oportunidade_id,
  b.cliente_id,
  b.vendedor_id,
  b.origem,
  coalesce(
    try_to_date(b.data_abertura, 'yyyy-MM-dd'),
    try_to_date(b.data_abertura, 'dd/MM/yyyy')
  ) AS data_abertura,
  b.etapa,
  (b.etapa = 'Fechado ganho') AS ganha,
  (b.etapa = 'Fechado perdido') AS perdida,
  try_cast(nullif(b.probabilidade_pct, '') AS DECIMAL(5,2)) AS probabilidade_pct,
  try_cast(nullif(b.valor_estimado, '') AS DECIMAL(18,2)) AS valor_estimado,
  coalesce(
    try_to_date(b.data_fechamento, 'yyyy-MM-dd'),
    try_to_date(b.data_fechamento, 'dd/MM/yyyy')
  ) AS data_fechamento,
  CAST(try_cast(nullif(b.ciclo_dias, '') AS DOUBLE) AS INT) AS ciclo_dias,
  nullif(b.motivo_perda, '') AS motivo_perda,
  current_timestamp() AS _processado_em,
  origem.n AS _linhas_origem
FROM lakehouse_mecamecanica.bronze.oportunidades b
CROSS JOIN origem;

CREATE OR REPLACE TABLE lakehouse_mecamecanica.silver.visitas
COMMENT 'Visitas de vendedores a clientes, tipadas.'
AS
WITH origem AS (
  SELECT COUNT(*) AS n FROM lakehouse_mecamecanica.bronze.visitas
)
SELECT
  b.visita_id,
  b.cliente_id,
  b.vendedor_id,
  coalesce(
    try_to_date(b.data_visita, 'yyyy-MM-dd'),
    try_to_date(b.data_visita, 'dd/MM/yyyy')
  ) AS data_visita,
  b.resultado,
  CAST(try_cast(nullif(b.duracao_min, '') AS DOUBLE) AS INT) AS duracao_min,
  current_timestamp() AS _processado_em,
  origem.n AS _linhas_origem
FROM lakehouse_mecamecanica.bronze.visitas b
CROSS JOIN origem;

CREATE OR REPLACE TABLE lakehouse_mecamecanica.silver.pagamentos
COMMENT 'Pagamentos de pedidos, tipados. data_pagamento fica NULL quando o pagamento ainda está pendente.'
AS
WITH origem AS (
  SELECT COUNT(*) AS n FROM lakehouse_mecamecanica.bronze.pagamentos
)
SELECT
  b.pagamento_id,
  b.pedido_id,
  b.forma_pagamento,
  CAST(try_cast(nullif(b.parcelas, '') AS DOUBLE) AS INT) AS parcelas,
  try_cast(nullif(b.valor, '') AS DECIMAL(18,2)) AS valor,
  try_cast(nullif(b.taxa_pct, '') AS DECIMAL(5,2)) AS taxa_pct,
  try_cast(nullif(b.valor_liquido, '') AS DECIMAL(18,2)) AS valor_liquido,
  coalesce(
    try_to_date(b.data_vencimento, 'yyyy-MM-dd'),
    try_to_date(b.data_vencimento, 'dd/MM/yyyy')
  ) AS data_vencimento,
  coalesce(
    try_to_date(b.data_pagamento, 'yyyy-MM-dd'),
    try_to_date(b.data_pagamento, 'dd/MM/yyyy')
  ) AS data_pagamento,
  b.status_pagamento,
  current_timestamp() AS _processado_em,
  origem.n AS _linhas_origem
FROM lakehouse_mecamecanica.bronze.pagamentos b
CROSS JOIN origem;

CREATE OR REPLACE TABLE lakehouse_mecamecanica.silver.estoque
COMMENT 'Snapshot de estoque por SKU. ruptura é recalculada a partir de saldo = 0, não copiada do flag da origem.'
AS
WITH origem AS (
  SELECT COUNT(*) AS n FROM lakehouse_mecamecanica.bronze.estoque
)
SELECT
  b.sku,
  coalesce(
    try_to_date(b.data_snapshot, 'yyyy-MM-dd'),
    try_to_date(b.data_snapshot, 'dd/MM/yyyy')
  ) AS data_snapshot,
  CAST(try_cast(nullif(b.saldo, '') AS DOUBLE) AS INT) AS saldo,
  coalesce(CAST(try_cast(nullif(b.saldo, '') AS DOUBLE) AS INT) = 0, false) AS ruptura,
  current_timestamp() AS _processado_em,
  origem.n AS _linhas_origem
FROM lakehouse_mecamecanica.bronze.estoque b
CROSS JOIN origem;

COMMENT ON COLUMN lakehouse_mecamecanica.silver.estoque.ruptura IS
  'Recalculada a partir de saldo = 0 (não copiada do flag S/N da bronze) — valida a origem em vez de confiar cegamente nela. NULL de saldo vira false via coalesce, para não sumir de filtros WHERE NOT ruptura.';
