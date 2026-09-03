-- Silver — pedidos
--
-- ANSI mode está ligado neste warehouse: to_date/CAST em valor malformado ou
-- vazio ABORTA a query. Toda conversão usa try_to_date/try_cast.

CREATE OR REPLACE TABLE lakehouse_mecamecanica.silver.pedidos
COMMENT 'Pedidos tipados e com valor líquido calculado. Pedido cancelado sempre tem valor_liquido = 0, mesmo com devolução envolvida — a constraint pedido_cancelado_zerado garante isso.'
AS
WITH origem AS (
  SELECT COUNT(*) AS n FROM lakehouse_mecamecanica.bronze.pedidos
)
SELECT
  b.pedido_id,
  b.cliente_id,
  b.vendedor_id,
  coalesce(
    try_to_date(b.data_pedido, 'yyyy-MM-dd'),
    try_to_date(b.data_pedido, 'dd/MM/yyyy')
  ) AS data_pedido,
  b.canal,
  b.status,
  (b.status = 'Cancelado') AS cancelado,
  try_cast(b.valor_total AS DECIMAL(18,2)) AS valor_total,
  CASE
    WHEN b.status = 'Cancelado' THEN CAST(0 AS DECIMAL(18,2))
    ELSE try_cast(b.valor_total AS DECIMAL(18,2))
  END AS valor_liquido,
  year(coalesce(
    try_to_date(b.data_pedido, 'yyyy-MM-dd'),
    try_to_date(b.data_pedido, 'dd/MM/yyyy')
  )) AS ano,
  month(coalesce(
    try_to_date(b.data_pedido, 'yyyy-MM-dd'),
    try_to_date(b.data_pedido, 'dd/MM/yyyy')
  )) AS mes,
  current_timestamp() AS _processado_em,
  origem.n AS _linhas_origem
FROM lakehouse_mecamecanica.bronze.pedidos b
CROSS JOIN origem;

COMMENT ON COLUMN lakehouse_mecamecanica.silver.pedidos.cancelado IS
  'true quando status = ''Cancelado'' (grafia exata da origem).';

COMMENT ON COLUMN lakehouse_mecamecanica.silver.pedidos.valor_liquido IS
  'Zero quando cancelado (literal, nunca depende de parse), valor_total caso contrário. Pode ser negativo em pedidos não cancelados com item devolvido — isso é negócio legítimo, não sujeira; a constraint só exige valor zero quando cancelado.';

ALTER TABLE lakehouse_mecamecanica.silver.pedidos
  ADD CONSTRAINT data_pedido_nao_nula CHECK (data_pedido IS NOT NULL);

ALTER TABLE lakehouse_mecamecanica.silver.pedidos
  ADD CONSTRAINT pedido_cancelado_zerado CHECK (NOT cancelado OR valor_liquido = 0);
