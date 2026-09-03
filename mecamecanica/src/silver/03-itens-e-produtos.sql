-- Silver — produtos e itens_pedido
--
-- Ordem importa: itens_pedido faz LEFT JOIN em produtos para marcar
-- sku_descontinuado, então produtos precisa existir primeiro neste script.

CREATE OR REPLACE TABLE lakehouse_mecamecanica.silver.produtos
COMMENT 'Catálogo de produtos tipado. QUALIFY garante um registro por sku mesmo que a origem um dia venha com sku duplicado (hoje não acontece, mas Delta/UC não impõe unicidade).'
AS
WITH origem AS (
  SELECT COUNT(*) AS n FROM lakehouse_mecamecanica.bronze.produtos
)
SELECT
  b.sku,
  b.descricao,
  b.categoria,
  b.marca,
  b.aplicacao,
  try_cast(nullif(b.preco_tabela, '') AS DECIMAL(18,2)) AS preco_tabela,
  try_cast(nullif(b.custo_unitario, '') AS DECIMAL(18,2)) AS custo_unitario,
  b.unidade,
  (b.ativo = 'S') AS ativo,
  coalesce(
    try_to_date(b.data_lancamento, 'yyyy-MM-dd'),
    try_to_date(b.data_lancamento, 'dd/MM/yyyy')
  ) AS data_lancamento,
  current_timestamp() AS _processado_em,
  origem.n AS _linhas_origem
FROM lakehouse_mecamecanica.bronze.produtos b
CROSS JOIN origem
QUALIFY row_number() OVER (PARTITION BY b.sku ORDER BY b._ingerido_em DESC) = 1;

CREATE OR REPLACE TABLE lakehouse_mecamecanica.silver.itens_pedido
COMMENT 'Itens de pedido com devolução sinalizada (nunca descartada) e SKU descontinuado marcado via join com produtos.'
AS
WITH origem AS (
  SELECT COUNT(*) AS n FROM lakehouse_mecamecanica.bronze.itens_pedido
)
SELECT
  b.item_id,
  b.pedido_id,
  b.sku,
  CAST(try_cast(nullif(b.quantidade, '') AS DOUBLE) AS INT) AS quantidade,
  (try_cast(nullif(b.quantidade, '') AS DOUBLE) < 0) AS devolucao,
  abs(CAST(try_cast(nullif(b.quantidade, '') AS DOUBLE) AS INT)) AS quantidade_abs,
  try_cast(nullif(b.preco_praticado, '') AS DECIMAL(18,2)) AS preco_praticado,
  try_cast(nullif(b.desconto_pct, '') AS DECIMAL(5,2)) AS desconto_pct,
  try_cast(nullif(b.valor_bruto, '') AS DECIMAL(18,2)) AS valor_bruto,
  coalesce(NOT p.ativo, true) AS sku_descontinuado,
  current_timestamp() AS _processado_em,
  origem.n AS _linhas_origem
FROM lakehouse_mecamecanica.bronze.itens_pedido b
CROSS JOIN origem
LEFT JOIN lakehouse_mecamecanica.silver.produtos p ON p.sku = b.sku;

COMMENT ON COLUMN lakehouse_mecamecanica.silver.itens_pedido.devolucao IS
  'true quando a quantidade de origem é negativa: isso é devolução, não erro. A linha é mantida, nunca descartada.';

COMMENT ON COLUMN lakehouse_mecamecanica.silver.itens_pedido.quantidade_abs IS
  'Valor absoluto da quantidade, sempre positivo, para uso em somas e contratos que não fazem sentido com sinal.';

COMMENT ON COLUMN lakehouse_mecamecanica.silver.itens_pedido.sku_descontinuado IS
  'true quando o produto referenciado não está mais ativo em silver.produtos, ou não existe mais lá — trata SKU ausente como descontinuado.';

ALTER TABLE lakehouse_mecamecanica.silver.itens_pedido
  ADD CONSTRAINT quantidade_abs_positiva CHECK (quantidade_abs IS NOT NULL AND quantidade_abs > 0);
