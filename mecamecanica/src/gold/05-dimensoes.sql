-- Gold — dimensões conformadas: dim_cliente, dim_produto, dim_vendedor,
-- dim_calendario. Lêem só da silver.
--
-- mapa_cliente resolve cliente_id: a dedup da silver (Entrega 3) manteve o
-- cadastro mais antigo por CNPJ e guardou os cliente_id descartados em
-- cliente_ids_duplicados. silver.pedidos ainda referencia esses ids
-- descartados em alguns pedidos antigos — sem este remapeamento, esses
-- pedidos ficariam órfãos (nenhum JOIN direto com silver.clientes os acha).

CREATE OR REPLACE TABLE lakehouse_mecamecanica.gold.dim_cliente
COMMENT 'Dimensão cliente, grão: um cliente sobrevivente da deduplicação por CNPJ. Métricas de pedido agregam também os pedidos feitos sob um cliente_id descartado na dedup (remapeados para o id canônico).'
AS
WITH mapa_cliente AS (
  SELECT cliente_id AS cliente_id_original, cliente_id AS cliente_id_canonico
  FROM lakehouse_mecamecanica.silver.clientes
  UNION ALL
  SELECT explode(cliente_ids_duplicados), cliente_id
  FROM lakehouse_mecamecanica.silver.clientes
  WHERE size(cliente_ids_duplicados) > 0
),
pedidos_cliente AS (
  SELECT
    m.cliente_id_canonico AS cliente_id,
    MIN(p.data_pedido) AS data_primeiro_pedido,
    MAX(p.data_pedido) AS data_ultimo_pedido,
    COUNT(*) AS total_pedidos,
    SUM(p.valor_liquido) AS receita_acumulada
  FROM lakehouse_mecamecanica.silver.pedidos p
  JOIN mapa_cliente m ON m.cliente_id_original = p.cliente_id
  GROUP BY m.cliente_id_canonico
)
SELECT
  c.cliente_id,
  c.cnpj,
  c.razao_social,
  c.segmento,
  c.cidade,
  c.uf,
  c.data_cadastro,
  pc.data_primeiro_pedido,
  pc.data_ultimo_pedido,
  coalesce(pc.total_pedidos, 0) AS total_pedidos,
  coalesce(pc.receita_acumulada, CAST(0 AS DECIMAL(18,2))) AS receita_acumulada,
  datediff(current_date(), pc.data_ultimo_pedido) AS dias_sem_comprar,
  current_timestamp() AS _processado_em
FROM lakehouse_mecamecanica.silver.clientes c
LEFT JOIN pedidos_cliente pc ON pc.cliente_id = c.cliente_id;

COMMENT ON COLUMN lakehouse_mecamecanica.gold.dim_cliente.total_pedidos IS
  'Conta todos os pedidos do cliente, inclusive cancelados — é atividade, não receita.';

COMMENT ON COLUMN lakehouse_mecamecanica.gold.dim_cliente.receita_acumulada IS
  'Soma de valor_liquido (silver.pedidos), que já é zero em pedidos cancelados.';

COMMENT ON COLUMN lakehouse_mecamecanica.gold.dim_cliente.dias_sem_comprar IS
  'Dias corridos desde o último pedido até hoje. NULL para cliente que nunca comprou.';

CREATE OR REPLACE TABLE lakehouse_mecamecanica.gold.dim_produto
COMMENT 'Dimensão produto, grão: um SKU.'
AS
SELECT
  sku,
  descricao,
  marca,
  categoria,
  aplicacao,
  custo_unitario,
  preco_tabela,
  data_lancamento,
  (NOT ativo) AS descontinuado,
  current_timestamp() AS _processado_em
FROM lakehouse_mecamecanica.silver.produtos;

COMMENT ON COLUMN lakehouse_mecamecanica.gold.dim_produto.descontinuado IS
  'true quando o produto não está mais ativo em silver.produtos.';

CREATE OR REPLACE TABLE lakehouse_mecamecanica.gold.dim_vendedor
COMMENT 'Dimensão vendedor, grão: um vendedor.'
AS
SELECT
  vendedor_id,
  nome,
  regiao,
  meta_mensal,
  (data_desligamento IS NULL) AS ativo,
  current_timestamp() AS _processado_em
FROM lakehouse_mecamecanica.silver.vendedores;

CREATE OR REPLACE TABLE lakehouse_mecamecanica.gold.dim_calendario
COMMENT 'Dimensão calendário, grão: um dia. Intervalo calculado a partir do menor e maior data_pedido de silver.pedidos (hoje cobre os 24 meses de dados do curso).'
AS
WITH limites AS (
  SELECT
    date_trunc('month', MIN(data_pedido)) AS inicio,
    last_day(date_trunc('month', MAX(data_pedido))) AS fim
  FROM lakehouse_mecamecanica.silver.pedidos
),
dias AS (
  SELECT explode(sequence(inicio, fim, interval 1 day)) AS data
  FROM limites
)
SELECT
  data,
  year(data) AS ano,
  month(data) AS mes,
  element_at(
    array('Janeiro','Fevereiro','Março','Abril','Maio','Junho',
          'Julho','Agosto','Setembro','Outubro','Novembro','Dezembro'),
    month(data)
  ) AS nome_mes,
  quarter(data) AS trimestre,
  element_at(
    array('Domingo','Segunda-feira','Terça-feira','Quarta-feira',
          'Quinta-feira','Sexta-feira','Sábado'),
    dayofweek(data)
  ) AS dia_semana,
  (month(data) IN (4, 6, 10)) AS mes_pico_setor,
  current_timestamp() AS _processado_em
FROM dias;

COMMENT ON COLUMN lakehouse_mecamecanica.gold.dim_calendario.mes_pico_setor IS
  'true em abril, junho e outubro — os meses de pico de vendas do setor de autopeças (troca de itens sazonais/preventiva).';
