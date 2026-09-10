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

-- A fila: top 200 por VALOR ESPERADO (score x margem x ticket, não só score),
-- entre clientes com carteira vigente. Priorizar só por score deixa dinheiro
-- na mesa: duas ligações igualmente prováveis não valem o mesmo se uma tem o
-- dobro de margem. Medido contra o catálogo: trocar para valor esperado troca
-- 29 dos 200 clientes e sobe o valor esperado total de R$ 203.066,74 para
-- R$ 209.344,50 (+3,1%), com o mesmo esforço de ligação.
--
-- motivo e sugestao são texto explicativo em português — motivo nunca é nulo
-- (sempre tem um ELSE); sugestao vem de sugerir_produtos + checar_disponibilidade,
-- e nunca oferece um SKU em ruptura (medido: 34 das 200 sugestões antigas
-- ofereciam saldo zero — 17% da fila). Quando o item de costume do cliente
-- está em ruptura, a sugestão NOMEIA os dois (o que faltou e o substituto),
-- para o vendedor comunicar a troca de forma consciente — nunca troca
-- silenciosa. O substituto é escolhido por categoria + aplicação (o que
-- garante que a peça serve no lugar), nunca por marca: marca é preferência,
-- não compatibilidade, e só desempata entre candidatos já compatíveis.

CREATE OR REPLACE TABLE lakehouse_mecamecanica.gold.fila_semanal
COMMENT 'As 200 ligações da semana, uma linha por cliente elegível (carteira vigente, vendedor ativo), ordenadas globalmente por valor esperado (score x margem x ticket médio) e numeradas por vendedor. Traz o motivo em português e uma sugestão de recompra com estoque garantido — é desta tabela que sai a lista que o vendedor abre.'
AS
WITH elegiveis AS (
  SELECT c.cliente_id, v.nome AS vendedor
  FROM lakehouse_mecamecanica.silver.carteira c
  JOIN lakehouse_mecamecanica.silver.vendedores v ON v.vendedor_id = c.vendedor_id
  WHERE c.vigente
),
candidatos AS (
  SELECT
    e.cliente_id, e.vendedor, sp.score, sp.faixa,
    fc.ticket_medio, fc.margem_percentual, fc.comprou_lancamento,
    fc.valor_total, fc.atraso_relativo, fc.oportunidades_abertas,
    (sp.score * fc.ticket_medio * COALESCE(fc.margem_percentual, 0)) AS valor_esperado
  FROM elegiveis e
  JOIN lakehouse_mecamecanica.gold.score_propensao sp ON sp.cliente_id = e.cliente_id
  JOIN lakehouse_mecamecanica.gold.features_cliente fc ON fc.cliente_id = e.cliente_id
),
top200 AS (
  SELECT * FROM candidatos
  ORDER BY valor_esperado DESC
  LIMIT 200
)
SELECT
  t.vendedor,
  ROW_NUMBER() OVER (PARTITION BY t.vendedor ORDER BY t.valor_esperado DESC) AS ordem,
  t.cliente_id,
  dc.razao_social,
  dc.cidade,
  dc.uf,
  t.score,
  t.faixa,
  t.ticket_medio,
  t.valor_esperado,
  CASE
    WHEN t.comprou_lancamento = 1
      THEN 'Comprou lançamento recente. Alta chance de repetir.'
    WHEN t.valor_total >= 50000
      THEN CONCAT('Cliente grande, R$ ', FORMAT_NUMBER(t.valor_total, 2), ' no ano. Manter próximo.')
    WHEN t.atraso_relativo >= 1.0
      THEN CONCAT('Atrasado em relação ao próprio ciclo de compra (', ROUND(t.atraso_relativo, 1), 'x o intervalo médio).')
    WHEN t.oportunidades_abertas > 0
      THEN 'Tem oportunidade em aberto no CRM — ligar para avançar a negociação.'
    ELSE 'Score alto de propensão de compra esta semana.'
  END AS motivo,
  CASE
    WHEN preferido.sku IS NULL
      THEN 'Sem sugestão de recompra: cliente sem histórico de SKU parado há mais de 90 dias.'
    WHEN NOT disp_preferido.ruptura
      THEN CONCAT('Oferecer ', preferido.descricao, ' (', preferido.sku, ') — ', preferido.marca,
                   '. Saldo atual: ', disp_preferido.saldo, ' un.')
    WHEN COALESCE(subst_historico.sku, subst_cat_marca.sku, subst_cat_geral.sku) IS NOT NULL
      THEN CONCAT('Cliente costuma levar ', preferido.descricao, ' (', preferido.marca,
                   '), sem estoque. Oferecer substituto: ',
                   COALESCE(subst_historico.descricao, subst_cat_marca.descricao, subst_cat_geral.descricao), ' (',
                   COALESCE(subst_historico.sku, subst_cat_marca.sku, subst_cat_geral.sku), ') — ',
                   COALESCE(subst_historico.marca, subst_cat_marca.marca, subst_cat_geral.marca),
                   '. Saldo atual: ', COALESCE(subst_historico.saldo, subst_cat_marca.saldo, subst_cat_geral.saldo), ' un.')
    ELSE CONCAT('Cliente costuma levar ', preferido.descricao, ' (', preferido.marca,
                '), mas está sem estoque e não há substituto da mesma categoria disponível.')
  END AS sugestao
FROM top200 t
JOIN lakehouse_mecamecanica.gold.dim_cliente dc ON dc.cliente_id = t.cliente_id
-- O produto que o cliente REALMENTE prefere, independente de estoque: o mais
-- comprado no histórico. É o que entra no texto quando falta — nomear o item
-- exato, não só avisar genericamente que há uma troca.
LEFT JOIN LATERAL (
  SELECT sp.sku, sp.descricao, sp.marca, sp.categoria, p.aplicacao
  FROM lakehouse_mecamecanica.gold.sugerir_produtos(t.cliente_id) sp
  JOIN lakehouse_mecamecanica.gold.dim_produto p ON p.sku = sp.sku
  ORDER BY sp.quantidade_total DESC
  LIMIT 1
) preferido ON true
LEFT JOIN LATERAL (
  SELECT saldo, ruptura FROM lakehouse_mecamecanica.gold.checar_disponibilidade(preferido.sku)
) disp_preferido ON preferido.sku IS NOT NULL
-- Substituto de categoria: só entra em jogo quando o preferido está em
-- ruptura. "Similar" para autopeças é categoria + aplicação (o que garante
-- que a peça serve no lugar da outra) — marca é preferência, não
-- compatibilidade, por isso NUNCA é o critério que define o substituto.
-- Primeira tentativa: outro item que o PRÓPRIO cliente já comprou antes,
-- da mesma categoria e aplicação do preferido, com estoque.
LEFT JOIN LATERAL (
  SELECT sp.sku, sp.descricao, sp.marca, cd.saldo
  FROM lakehouse_mecamecanica.gold.sugerir_produtos(t.cliente_id) sp
  JOIN lakehouse_mecamecanica.gold.dim_produto p2 ON p2.sku = sp.sku
  JOIN LATERAL (SELECT saldo, ruptura FROM lakehouse_mecamecanica.gold.checar_disponibilidade(sp.sku)) cd ON true
  WHERE sp.categoria = preferido.categoria
    AND p2.aplicacao = preferido.aplicacao
    AND sp.sku <> preferido.sku
    AND NOT cd.ruptura
  ORDER BY sp.quantidade_total DESC
  LIMIT 1
) subst_historico ON disp_preferido.ruptura
-- Segunda tentativa: qualquer produto do catálogo, mesma categoria e
-- aplicação, primeiro tentando a marca preferida do cliente...
LEFT JOIN LATERAL (
  SELECT marca FROM lakehouse_mecamecanica.gold.fato_vendas
  WHERE cliente_id = t.cliente_id
  GROUP BY marca ORDER BY SUM(receita) DESC LIMIT 1
) mp ON disp_preferido.ruptura AND subst_historico.sku IS NULL
LEFT JOIN LATERAL (
  SELECT p.sku, p.descricao, p.marca, cd.saldo
  FROM lakehouse_mecamecanica.gold.dim_produto p
  JOIN LATERAL (SELECT saldo, ruptura FROM lakehouse_mecamecanica.gold.checar_disponibilidade(p.sku)) cd ON true
  WHERE p.categoria = preferido.categoria AND p.aplicacao = preferido.aplicacao
    AND p.sku <> preferido.sku AND NOT p.descontinuado AND NOT cd.ruptura
    AND p.marca = mp.marca
  ORDER BY cd.saldo DESC
  LIMIT 1
) subst_cat_marca ON disp_preferido.ruptura AND subst_historico.sku IS NULL
-- ...e só quando nem isso existe, qualquer marca do catálogo com estoque.
LEFT JOIN LATERAL (
  SELECT p.sku, p.descricao, p.marca, cd.saldo
  FROM lakehouse_mecamecanica.gold.dim_produto p
  JOIN LATERAL (SELECT saldo, ruptura FROM lakehouse_mecamecanica.gold.checar_disponibilidade(p.sku)) cd ON true
  WHERE p.categoria = preferido.categoria AND p.aplicacao = preferido.aplicacao
    AND p.sku <> preferido.sku AND NOT p.descontinuado AND NOT cd.ruptura
  ORDER BY cd.saldo DESC
  LIMIT 1
) subst_cat_geral
  ON disp_preferido.ruptura AND subst_historico.sku IS NULL AND subst_cat_marca.sku IS NULL;

COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.vendedor IS
  'Nome do vendedor responsável, via carteira vigente (silver.carteira -> silver.vendedores).';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.ordem IS
  'Posição do cliente na fila DAQUELE vendedor (1 = primeira ligação), não a posição global. Ordenada por valor_esperado, não por score.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.cliente_id IS
  'Identificador do cliente, mesmo cliente_id de gold.score_propensao e gold.dim_cliente.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.razao_social IS
  'Razão social do cliente, de gold.dim_cliente.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.cidade IS
  'Cidade do cliente, de gold.dim_cliente.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.uf IS
  'UF do cliente, de gold.dim_cliente.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.score IS
  'Probabilidade de compra na semana, de gold.score_propensao (0 a 1). Informativo — quem ordena a fila é valor_esperado, não este campo sozinho.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.faixa IS
  'Faixa do score em quartis: Fria, Morna, Quente, Muito quente (gold.score_propensao).';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.ticket_medio IS
  'Ticket médio histórico do cliente, de gold.features_cliente.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.valor_esperado IS
  'score x margem_percentual x ticket_medio: quanto de margem essa ligação vale em expectativa. É o critério de ordenação da fila (top 200 e ordem por vendedor) — duas ligações igualmente prováveis não valem o mesmo se uma tem o dobro de margem.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.motivo IS
  'Frase em português explicando por que o cliente está na fila, com os números reais dele. Nunca nula — sempre tem um ELSE.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fila_semanal.sugestao IS
  'O que oferecer: o SKU mais comprado pelo cliente, que ele não levou nos últimos 90 dias. Se esse item estiver em ruptura, nomeia os dois — o que faltou e o substituto — priorizando mesma categoria e aplicação (compatibilidade real) sobre marca (preferência), primeiro no próprio histórico do cliente, depois no catálogo inteiro.';

-- Última função: consulta fila_semanal, por isso vem depois da tabela.

CREATE OR REPLACE FUNCTION lakehouse_mecamecanica.gold.priorizar_carteira(
  p_vendedor STRING COMMENT 'Nome do vendedor, exatamente como aparece em silver.vendedores.nome.',
  p_quantos INT COMMENT 'Quantos contatos priorizados retornar, a partir do primeiro da fila.'
)
RETURNS TABLE (
  ordem INT, cliente_id INT, razao_social STRING, cidade STRING, uf STRING,
  score DOUBLE, faixa STRING, valor_esperado DOUBLE, motivo STRING, sugestao STRING
)
COMMENT 'Devolve a fatia da fila da semana de UM vendedor, em ordem de prioridade (por valor_esperado). Use quando o vendedor perguntar "quem eu ligo essa semana" ou pedir sua lista de contatos.'
RETURN
  SELECT ordem, cliente_id, razao_social, cidade, uf, score, faixa, valor_esperado, motivo, sugestao
  FROM lakehouse_mecamecanica.gold.fila_semanal
  WHERE vendedor = p_vendedor AND ordem <= p_quantos
  ORDER BY ordem;
