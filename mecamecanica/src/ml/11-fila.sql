-- ML — fila_semanal: as 200 ligações da semana, priorizadas por
-- gold.score_propensao, mais as quatro funções SQL que o agente (Genie "Fila
-- da semana") consulta. Depende de ml_modelo já ter rodado (score_propensao
-- precisa ter a _referencia mais recente).
--
-- Elegibilidade: carteira vigente já implica vendedor ativo (silver.carteira
-- .vigente exige v.data_desligamento IS NULL — ver 04-crm-e-financeiro.sql),
-- então basta filtrar vigente = true.

-- Três funções de consulta, independentes de fila_semanal. Vêm primeiro
-- porque sugerir_produtos/checar_disponibilidade são usadas para montar a
-- coluna sugestao logo abaixo.

CREATE OR REPLACE FUNCTION lakehouse_mecamecanica.gold.checar_disponibilidade(p_sku STRING COMMENT 'SKU a consultar.')
RETURNS TABLE (sku STRING, data_snapshot DATE, saldo INT, ruptura BOOLEAN)
COMMENT 'Saldo em estoque e se está em ruptura, no snapshot mais recente disponível. Use antes de prometer prazo ou oferecer um produto ao cliente.'
RETURN
  SELECT sku, data_snapshot, saldo, ruptura
  FROM (
    SELECT sku, data_snapshot, saldo, ruptura,
           ROW_NUMBER() OVER (PARTITION BY sku ORDER BY data_snapshot DESC) AS rn
    FROM lakehouse_mecamecanica.silver.estoque
    WHERE sku = p_sku
  )
  WHERE rn = 1;

CREATE OR REPLACE FUNCTION lakehouse_mecamecanica.gold.sugerir_produtos(p_cliente_id INT COMMENT 'cliente_id a consultar.')
RETURNS TABLE (sku STRING, descricao STRING, marca STRING, categoria STRING, quantidade_total DOUBLE, ultima_compra DATE)
COMMENT 'SKUs que o cliente já comprou historicamente mas não comprou nos últimos 90 dias, do mais para o menos comprado. Use quando o vendedor perguntar o que oferecer para um cliente.'
RETURN
  SELECT
    fv.sku, p.descricao, fv.marca, fv.categoria,
    SUM(fv.quantidade) AS quantidade_total,
    MAX(fv.data_pedido) AS ultima_compra
  FROM lakehouse_mecamecanica.gold.fato_vendas fv
  JOIN lakehouse_mecamecanica.gold.dim_produto p ON p.sku = fv.sku
  WHERE fv.cliente_id = p_cliente_id
  GROUP BY fv.sku, p.descricao, fv.marca, fv.categoria
  HAVING MAX(fv.data_pedido) < (
    SELECT DATE_SUB(MAX(_referencia), 90) FROM lakehouse_mecamecanica.gold.score_propensao
  )
  ORDER BY quantidade_total DESC;

CREATE OR REPLACE FUNCTION lakehouse_mecamecanica.gold.contexto_cliente(p_cliente_id INT COMMENT 'cliente_id a consultar.')
RETURNS TABLE (
  razao_social STRING, cidade STRING, uf STRING,
  total_pedidos DOUBLE, valor_total DOUBLE, ticket_medio DOUBLE,
  marca_preferida STRING, ultima_compra DATE, recencia_dias DOUBLE
)
COMMENT 'Histórico e perfil de compra de um cliente: total de pedidos, ticket médio, marca que ele mais compra e há quantos dias não compra. Use antes de ligar, para entender o cliente.'
RETURN
  SELECT
    d.razao_social, d.cidade, d.uf,
    f.frequencia_pedidos AS total_pedidos,
    f.valor_total, f.ticket_medio,
    mp.marca AS marca_preferida,
    uc.ultima_compra,
    f.recencia_dias
  FROM lakehouse_mecamecanica.gold.features_cliente f
  JOIN lakehouse_mecamecanica.gold.dim_cliente d ON d.cliente_id = f.cliente_id
  LEFT JOIN (
    SELECT cliente_id, marca FROM (
      SELECT cliente_id, marca,
             ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY SUM(receita) DESC) AS rn
      FROM lakehouse_mecamecanica.gold.fato_vendas
      WHERE cliente_id = p_cliente_id
      GROUP BY cliente_id, marca
    ) WHERE rn = 1
  ) mp ON mp.cliente_id = f.cliente_id
  LEFT JOIN (
    SELECT cliente_id, MAX(data_pedido) AS ultima_compra
    FROM lakehouse_mecamecanica.gold.fato_vendas
    WHERE cliente_id = p_cliente_id
    GROUP BY cliente_id
  ) uc ON uc.cliente_id = f.cliente_id
  WHERE f.cliente_id = p_cliente_id;

-- A fila: top 200 globalmente por score, entre clientes com carteira vigente.
-- motivo e sugestao são texto explicativo em português — motivo nunca é nulo
-- (sempre tem um ELSE); sugestao vem de sugerir_produtos + checar_disponibilidade.

CREATE OR REPLACE TABLE lakehouse_mecamecanica.gold.fila_semanal
COMMENT 'As 200 ligações da semana, uma linha por cliente elegível (carteira vigente, vendedor ativo), ordenadas globalmente por score e numeradas por vendedor. Traz o motivo em português e uma sugestão de recompra — é desta tabela que sai a lista que o vendedor abre.'
AS
WITH elegiveis AS (
  SELECT c.cliente_id, v.nome AS vendedor
  FROM lakehouse_mecamecanica.silver.carteira c
  JOIN lakehouse_mecamecanica.silver.vendedores v ON v.vendedor_id = c.vendedor_id
  WHERE c.vigente
),
top200 AS (
  SELECT e.cliente_id, e.vendedor, sp.score, sp.faixa
  FROM elegiveis e
  JOIN lakehouse_mecamecanica.gold.score_propensao sp ON sp.cliente_id = e.cliente_id
  ORDER BY sp.score DESC
  LIMIT 200
)
SELECT
  t.vendedor,
  ROW_NUMBER() OVER (PARTITION BY t.vendedor ORDER BY t.score DESC) AS ordem,
  t.cliente_id,
  dc.razao_social,
  dc.cidade,
  dc.uf,
  t.score,
  t.faixa,
  fc.ticket_medio,
  CASE
    WHEN fc.comprou_lancamento = 1
      THEN 'Comprou lançamento recente. Alta chance de repetir.'
    WHEN fc.valor_total >= 50000
      THEN CONCAT('Cliente grande, R$ ', FORMAT_NUMBER(fc.valor_total, 2), ' no ano. Manter próximo.')
    WHEN fc.atraso_relativo >= 1.0
      THEN CONCAT('Atrasado em relação ao próprio ciclo de compra (', ROUND(fc.atraso_relativo, 1), 'x o intervalo médio).')
    WHEN fc.oportunidades_abertas > 0
      THEN 'Tem oportunidade em aberto no CRM — ligar para avançar a negociação.'
    ELSE 'Score alto de propensão de compra esta semana.'
  END AS motivo,
  CASE
    WHEN prod.sku IS NOT NULL
      THEN CONCAT('Oferecer ', prod.descricao, ' (', prod.sku, ') — ', prod.marca,
                   '. Saldo atual: ', COALESCE(CAST(est.saldo AS STRING), '?'), ' un.')
    ELSE 'Sem sugestão de recompra: nenhum SKU do histórico parado há mais de 90 dias.'
  END AS sugestao
FROM top200 t
JOIN lakehouse_mecamecanica.gold.dim_cliente dc ON dc.cliente_id = t.cliente_id
JOIN lakehouse_mecamecanica.gold.features_cliente fc ON fc.cliente_id = t.cliente_id
LEFT JOIN LATERAL (
  SELECT sku, descricao, marca
  FROM lakehouse_mecamecanica.gold.sugerir_produtos(t.cliente_id)
  ORDER BY quantidade_total DESC
  LIMIT 1
) prod ON true
LEFT JOIN LATERAL (
  SELECT saldo FROM lakehouse_mecamecanica.gold.checar_disponibilidade(prod.sku)
) est ON true;

COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.vendedor IS
  'Nome do vendedor responsável, via carteira vigente (silver.carteira -> silver.vendedores).';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.ordem IS
  'Posição do cliente na fila DAQUELE vendedor (1 = primeira ligação), não a posição global.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.cliente_id IS
  'Identificador do cliente, mesmo cliente_id de gold.score_propensao e gold.dim_cliente.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.razao_social IS
  'Razão social do cliente, de gold.dim_cliente.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.cidade IS
  'Cidade do cliente, de gold.dim_cliente.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.uf IS
  'UF do cliente, de gold.dim_cliente.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.score IS
  'Probabilidade de compra na semana, de gold.score_propensao (0 a 1). Maior = mais prioritário.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.faixa IS
  'Faixa do score em quartis: Fria, Morna, Quente, Muito quente (gold.score_propensao).';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.ticket_medio IS
  'Ticket médio histórico do cliente, de gold.features_cliente.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.motivo IS
  'Frase em português explicando por que o cliente está na fila, com os números reais dele. Nunca nula — sempre tem um ELSE.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.sugestao IS
  'O que oferecer: o SKU mais comprado pelo cliente, na marca preferida dele, que ele não levou nos últimos 90 dias, com o saldo do snapshot mais recente de silver.estoque.';

-- Última função: consulta fila_semanal, por isso vem depois da tabela.

CREATE OR REPLACE FUNCTION lakehouse_mecamecanica.gold.priorizar_carteira(
  p_vendedor STRING COMMENT 'Nome do vendedor, exatamente como aparece em silver.vendedores.nome.',
  p_quantos INT COMMENT 'Quantos contatos priorizados retornar, a partir do primeiro da fila.'
)
RETURNS TABLE (
  ordem INT, cliente_id INT, razao_social STRING, cidade STRING, uf STRING,
  score DOUBLE, faixa STRING, motivo STRING, sugestao STRING
)
COMMENT 'Devolve a fatia da fila da semana de UM vendedor, em ordem de prioridade. Use quando o vendedor perguntar "quem eu ligo essa semana" ou pedir sua lista de contatos.'
RETURN
  SELECT ordem, cliente_id, razao_social, cidade, uf, score, faixa, motivo, sugestao
  FROM lakehouse_mecamecanica.gold.fila_semanal
  WHERE vendedor = p_vendedor AND ordem <= p_quantos
  ORDER BY ordem;
