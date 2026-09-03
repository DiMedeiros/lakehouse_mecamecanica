-- Gold — três marts, um por diretoria.
--
-- mart_vendas_por_vendedor e mart_produto_performance derivam do MESMO fato
-- (gold.fato_vendas) — nunca recriam a lógica de receita/margem.
--
-- mart_financeiro_recebimento é exceção deliberada: precisa de
-- data_vencimento/data_pagamento/taxa_pct, que não existem em fato_vendas
-- (grão item-de-pedido) e não podem ser unidas a ele sem fan-out (um pedido
-- tem N parcelas). Lê direto de silver.pagamentos.

CREATE OR REPLACE TABLE lakehouse_mecamecanica.gold.mart_vendas_por_vendedor
COMMENT 'Mart comercial, grão: vendedor × mês. Receita/margem vêm de gold.fato_vendas; meta e atingimento comparam contra silver.vendedores.'
AS
WITH agregado AS (
  SELECT
    vendedor_id,
    ano,
    mes,
    SUM(receita) AS receita,
    SUM(margem) AS margem,
    COUNT(DISTINCT cliente_id) AS clientes_atendidos,
    COUNT(DISTINCT pedido_id) AS total_pedidos
  FROM lakehouse_mecamecanica.gold.fato_vendas
  GROUP BY vendedor_id, ano, mes
)
SELECT
  a.vendedor_id,
  v.nome,
  v.regiao,
  a.ano,
  a.mes,
  a.receita,
  a.margem,
  v.meta_mensal AS meta,
  ROUND(100 * a.receita / v.meta_mensal, 1) AS atingimento_pct,
  a.clientes_atendidos,
  ROUND(a.receita / a.total_pedidos, 2) AS ticket_medio,
  current_timestamp() AS _processado_em
FROM agregado a
JOIN lakehouse_mecamecanica.gold.dim_vendedor v ON v.vendedor_id = a.vendedor_id;

COMMENT ON COLUMN lakehouse_mecamecanica.gold.mart_vendas_por_vendedor.atingimento_pct IS
  'receita do mês / meta_mensal do vendedor, em percentual.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.mart_vendas_por_vendedor.ticket_medio IS
  'receita do mês dividida pelo número de pedidos distintos do mês (não de itens).';

CREATE OR REPLACE TABLE lakehouse_mecamecanica.gold.mart_produto_performance
COMMENT 'Mart de produto, grão: SKU × mês. Receita/margem/quantidade vêm de gold.fato_vendas; classe_abc classifica o SKU pela receita total (todos os meses), não mês a mês — evita o mesmo SKU oscilar de classe sem mudança real de receita.'
AS
WITH por_sku_mes AS (
  SELECT
    sku, categoria, marca, ano, mes,
    SUM(quantidade) AS quantidade,
    SUM(receita) AS receita,
    SUM(margem) AS margem
  FROM lakehouse_mecamecanica.gold.fato_vendas
  GROUP BY sku, categoria, marca, ano, mes
),
receita_por_sku AS (
  SELECT sku, SUM(receita) AS receita_sku
  FROM lakehouse_mecamecanica.gold.fato_vendas
  GROUP BY sku
),
classificado AS (
  SELECT
    sku,
    CASE
      WHEN acumulado_pct <= 0.8 THEN 'A'
      WHEN acumulado_pct <= 0.95 THEN 'B'
      ELSE 'C'
    END AS classe_abc
  FROM (
    SELECT
      sku,
      SUM(receita_sku) OVER (
        ORDER BY receita_sku DESC, sku ASC
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ) / SUM(receita_sku) OVER () AS acumulado_pct
    FROM receita_por_sku
  )
)
SELECT
  p.sku,
  p.categoria,
  p.marca,
  p.ano,
  p.mes,
  p.quantidade,
  p.receita,
  p.margem,
  ROUND(100 * p.margem / p.receita, 1) AS margem_pct,
  cl.classe_abc,
  current_timestamp() AS _processado_em
FROM por_sku_mes p
JOIN classificado cl ON cl.sku = p.sku;

COMMENT ON COLUMN lakehouse_mecamecanica.gold.mart_produto_performance.classe_abc IS
  'Curva ABC por receita acumulada do SKU (A = até 80% acumulado, B = até 95%, C = resto), calculada uma vez sobre a receita total do SKU e repetida em todas as linhas mensais dele.';

CREATE OR REPLACE TABLE lakehouse_mecamecanica.gold.mart_financeiro_recebimento
COMMENT 'Mart financeiro, grão: mês de vencimento. Lê direto de silver.pagamentos (não de fato_vendas — parcelas de pagamento têm grão diferente de item de pedido).'
AS
SELECT
  year(data_vencimento) AS ano_vencimento,
  month(data_vencimento) AS mes_vencimento,
  ROUND(SUM(valor), 2) AS valor_a_receber,
  ROUND(SUM(valor) FILTER (WHERE data_pagamento IS NOT NULL), 2) AS valor_recebido,
  ROUND(AVG(datediff(data_pagamento, data_vencimento)) FILTER (WHERE data_pagamento IS NOT NULL), 1) AS atraso_medio_dias,
  ROUND(SUM(valor - valor_liquido), 2) AS custo_de_taxa,
  current_timestamp() AS _processado_em
FROM lakehouse_mecamecanica.silver.pagamentos
WHERE data_vencimento IS NOT NULL
GROUP BY year(data_vencimento), month(data_vencimento);

COMMENT ON COLUMN lakehouse_mecamecanica.gold.mart_financeiro_recebimento.atraso_medio_dias IS
  'Média de (data_pagamento - data_vencimento) entre os pagamentos já pagos. Negativo = pago adiantado, em média.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.mart_financeiro_recebimento.custo_de_taxa IS
  'Soma de (valor - valor_liquido): quanto foi retido em taxa/juros de meio de pagamento.';
