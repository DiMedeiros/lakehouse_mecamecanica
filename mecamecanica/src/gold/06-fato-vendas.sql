-- Gold — fato_vendas
--
-- CONTRATO (escrito antes do SQL):
--   Granularidade: uma linha por ITEM de pedido (silver.itens_pedido).
--   Filtro: exclui pedidos cancelados. NÃO exclui devolução.
--   Dimensões: pedido_id, item_id, data_pedido, ano, mes, canal, cliente_id,
--              razao_social, segmento, cidade, vendedor_id, sku, categoria, marca.
--   Métricas:  quantidade, preco_praticado, receita, custo, margem, devolucao.
--   custo  = quantidade * custo_unitario do produto
--   margem = receita - custo
--   Devolução entra com quantidade e receita NEGATIVAS (silver.itens_pedido.quantidade
--   já é assinado), sinalizada pela flag devolucao. Quem quiser o bruto pede
--   SUM(receita) FILTER (WHERE NOT devolucao).
--   Particionado por (ano, mes).
--
-- cliente_id é remapeado para o id sobrevivente da dedup da Entrega 3 (ver
-- mapa_cliente) — sem isso, pedidos feitos sob um cliente_id descartado
-- ficariam sem cliente_id válido, quebrando a conformidade de receita.

CREATE OR REPLACE TABLE lakehouse_mecamecanica.gold.fato_vendas
USING DELTA
PARTITIONED BY (ano, mes)
COMMENT 'Fato de vendas, grão = item de pedido. Exclui pedidos cancelados; mantém devolução com sinal negativo (flag devolucao). SUM(receita) fecha exatamente com SUM(silver.pedidos.valor_liquido) — é o contrato de conformidade da gold (teste 1 de 08-testes.sql).'
AS
WITH mapa_cliente AS (
  SELECT cliente_id AS cliente_id_original, cliente_id AS cliente_id_canonico
  FROM lakehouse_mecamecanica.silver.clientes
  UNION ALL
  SELECT explode(cliente_ids_duplicados), cliente_id
  FROM lakehouse_mecamecanica.silver.clientes
  WHERE size(cliente_ids_duplicados) > 0
)
SELECT
  i.pedido_id,
  i.item_id,
  p.data_pedido,
  p.ano,
  p.mes,
  p.canal,
  m.cliente_id_canonico AS cliente_id,
  c.razao_social,
  c.segmento,
  c.cidade,
  p.vendedor_id,
  i.sku,
  pr.categoria,
  pr.marca,
  i.quantidade,
  i.preco_praticado,
  (i.quantidade * i.preco_praticado) AS receita,
  (i.quantidade * pr.custo_unitario) AS custo,
  ((i.quantidade * i.preco_praticado) - (i.quantidade * pr.custo_unitario)) AS margem,
  i.devolucao,
  current_timestamp() AS _processado_em
FROM lakehouse_mecamecanica.silver.itens_pedido i
JOIN lakehouse_mecamecanica.silver.pedidos p ON p.pedido_id = i.pedido_id
JOIN mapa_cliente m ON m.cliente_id_original = p.cliente_id
JOIN lakehouse_mecamecanica.silver.clientes c ON c.cliente_id = m.cliente_id_canonico
JOIN lakehouse_mecamecanica.silver.produtos pr ON pr.sku = i.sku
WHERE NOT p.cancelado;

COMMENT ON COLUMN lakehouse_mecamecanica.gold.fato_vendas.pedido_id IS
  'Pedido de origem do item. Chave técnica, valida contra silver.pedidos (teste 6).';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fato_vendas.item_id IS
  'Identificador do item de pedido (grão da tabela) em silver.itens_pedido.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fato_vendas.data_pedido IS
  'Data em que o pedido foi feito.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fato_vendas.ano IS
  'Ano do pedido. Coluna de partição.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fato_vendas.mes IS
  'Mês do pedido (1-12). Coluna de partição.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fato_vendas.canal IS
  'Canal pelo qual o pedido foi feito (ex.: visita, telefone, e-commerce).';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fato_vendas.cliente_id IS
  'Cliente que fez o pedido, já remapeado para o cadastro sobrevivente quando o pedido original referenciava um cliente_id descartado na deduplicação por CNPJ.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fato_vendas.razao_social IS
  'Razão social do cliente no momento da consulta (não histórica).';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fato_vendas.segmento IS
  'Segmento de mercado do cliente (ex.: oficina independente, concessionária).';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fato_vendas.cidade IS
  'Cidade do cliente.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fato_vendas.vendedor_id IS
  'Vendedor responsável pelo pedido.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fato_vendas.sku IS
  'Produto vendido neste item.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fato_vendas.categoria IS
  'Categoria do produto no momento da consulta.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fato_vendas.marca IS
  'Marca do produto no momento da consulta.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fato_vendas.quantidade IS
  'Quantidade vendida. Negativa quando o item é uma devolução.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fato_vendas.preco_praticado IS
  'Preço unitário efetivamente praticado no item, já com desconto aplicado.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fato_vendas.receita IS
  'quantidade * preco_praticado. Negativa em devolução — é o valor líquido, com devolução dentro. Para o bruto, use SUM(receita) FILTER (WHERE NOT devolucao).';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fato_vendas.custo IS
  'quantidade * custo_unitario do produto (dim_produto/silver.produtos).';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fato_vendas.margem IS
  'Receita menos custo do produto. Não considera desconto comercial nem frete.';
COMMENT ON COLUMN lakehouse_mecamecanica.gold.fato_vendas.devolucao IS
  'true quando o item é uma devolução (quantidade de origem negativa). Devolução fica dentro do fato de propósito — excluí-la infla a receita em ~R$ 1,26 milhão.';
