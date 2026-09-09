-- Gold — seis views de métricas de negócio, para consumo direto por Genie
-- (genie_direcao, genie_comercial) e dashboard. Views, não tabelas: sempre
-- refletem o estado mais recente de fato_vendas/dim_cliente/dim_calendario/
-- dim_produto/silver.estoque, sem reprocessar.
--
-- Ninguém da diretoria pergunta por `fato_vendas`. Pergunta por *ranking de
-- marcas* e por *clientes em risco*. A view existe para que o nome da
-- pergunta e o nome da tabela sejam a mesma palavra — é isso que faz o
-- agente acertar de primeira em vez de tentar adivinhar qual JOIN fazer.
--
-- O COMMENT de cada view diz QUAL PERGUNTA ela responde, não o que ela é.
-- É assim que o Genie escolhe onde procurar (ver 11-auditoria-metadado.sql).

CREATE OR REPLACE VIEW lakehouse_mecamecanica.gold.clientes_em_risco (
  cliente_id COMMENT 'Identificador do cliente.',
  razao_social COMMENT 'Razão social do cliente.',
  segmento COMMENT 'Segmento do cliente.',
  cidade COMMENT 'Cidade do cliente.',
  uf COMMENT 'UF do cliente.',
  ultimo_pedido COMMENT 'Data do último pedido do cliente.',
  dias_sem_comprar COMMENT 'Dias desde o último pedido do cliente, até a última carga da gold.',
  total_pedidos COMMENT 'Quantos pedidos o cliente já fez, contando inclusive os anteriores ao período de risco.',
  receita_acumulada COMMENT 'Quanto o cliente já comprou no total, desde o primeiro pedido.',
  receita_media_mensal COMMENT 'Receita média mensal do cliente, calculada sobre o período em que ele comprou (do primeiro ao último pedido) — quanto ele costumava comprar antes de sumir.'
)
COMMENT 'Responde: quais clientes pararam de comprar (mais de 90 dias sem pedido), e quanta receita a empresa está deixando de ganhar com isso?'
WITH SCHEMA COMPENSATION
AS SELECT
  d.cliente_id, d.razao_social, d.segmento, d.cidade, d.uf,
  d.data_ultimo_pedido AS ultimo_pedido,
  d.dias_sem_comprar,
  d.total_pedidos,
  d.receita_acumulada,
  d.receita_acumulada / GREATEST(MONTHS_BETWEEN(d.data_ultimo_pedido, d.data_primeiro_pedido) + 1, 1) AS receita_media_mensal
FROM lakehouse_mecamecanica.gold.dim_cliente d
WHERE d.dias_sem_comprar > 90;

CREATE OR REPLACE VIEW lakehouse_mecamecanica.gold.ranking_marcas (
  marca COMMENT 'Marca do produto.',
  receita COMMENT 'Receita total da marca, todo o histórico.',
  margem COMMENT 'Margem total da marca.',
  margem_pct COMMENT 'Margem dividida pela receita da marca (0 a 1).',
  participacao_pct COMMENT 'Participação da marca na receita total da empresa (0 a 1).',
  skus COMMENT 'Quantidade de SKUs distintos vendidos da marca.',
  pedidos COMMENT 'Pedidos distintos que contiveram a marca.'
)
COMMENT 'Responde: quais marcas mais vendem, com que margem, e qual a participação de cada uma na receita total da empresa?'
WITH SCHEMA COMPENSATION
AS WITH por_marca AS (
  SELECT marca,
         SUM(receita) AS receita,
         SUM(margem) AS margem,
         COUNT(DISTINCT sku) AS skus,
         COUNT(DISTINCT pedido_id) AS pedidos
  FROM lakehouse_mecamecanica.gold.fato_vendas
  GROUP BY marca
),
total AS (
  SELECT SUM(receita) AS receita_total FROM lakehouse_mecamecanica.gold.fato_vendas
)
SELECT
  m.marca, m.receita, m.margem,
  m.margem / NULLIF(m.receita, 0) AS margem_pct,
  m.receita / NULLIF(t.receita_total, 0) AS participacao_pct,
  m.skus, m.pedidos
FROM por_marca m
CROSS JOIN total t;

CREATE OR REPLACE VIEW lakehouse_mecamecanica.gold.receita_mensal (
  ano COMMENT 'Ano do pedido.',
  mes COMMENT 'Mês do pedido (1 a 12).',
  nome_mes COMMENT 'Nome do mês, de gold.dim_calendario.',
  mes_pico_setor COMMENT 'true se este mês é pico sazonal do setor de autopeças. Sazonalidade INVERTIDA: o pico é o mês ANTERIOR à data comemorativa (ex.: abril antes do Dia das Mães), não o mês dela.',
  mes_vale_setor COMMENT 'true em dezembro e janeiro. Vale ESPERADO do setor — as oficinas já estão abastecidas — não é queda de desempenho.',
  receita COMMENT 'Soma da receita líquida do mês (devolução já incluída, com sinal negativo).',
  margem COMMENT 'Soma da margem do mês.',
  margem_pct COMMENT 'Margem sobre receita do mês, de 0 a 1.',
  pedidos COMMENT 'Pedidos distintos no mês.',
  ticket_medio COMMENT 'Receita do mês dividida pelo número de pedidos distintos.'
)
COMMENT 'Responde: qual foi a receita, a margem e o volume de pedidos por mês, e quais meses são pico ou vale sazonal do setor?'
WITH SCHEMA COMPENSATION
AS WITH calendario_mes AS (
  SELECT DISTINCT ano, mes, nome_mes, mes_pico_setor
  FROM lakehouse_mecamecanica.gold.dim_calendario
)
SELECT
  f.ano, f.mes, c.nome_mes, c.mes_pico_setor,
  (f.mes IN (12, 1)) AS mes_vale_setor,
  SUM(f.receita) AS receita,
  SUM(f.margem) AS margem,
  SUM(f.margem) / NULLIF(SUM(f.receita), 0) AS margem_pct,
  COUNT(DISTINCT f.pedido_id) AS pedidos,
  SUM(f.receita) / NULLIF(COUNT(DISTINCT f.pedido_id), 0) AS ticket_medio
FROM lakehouse_mecamecanica.gold.fato_vendas f
LEFT JOIN calendario_mes c ON c.ano = f.ano AND c.mes = f.mes
GROUP BY f.ano, f.mes, c.nome_mes, c.mes_pico_setor;

CREATE OR REPLACE VIEW lakehouse_mecamecanica.gold.margem_por_categoria (
  categoria COMMENT 'Categoria do produto.',
  receita COMMENT 'Receita da categoria, todo o histórico.',
  margem COMMENT 'Margem da categoria, todo o histórico.',
  margem_pct COMMENT 'Margem sobre receita, de 0 a 1 — onde a empresa ganha e onde perde margem.',
  margem_tabela_pct COMMENT 'Margem teórica de catálogo (preco_tabela menos custo_unitario, dividido por preco_tabela), antes de qualquer desconto comercial. A diferença para margem_pct é o efeito do desconto praticado.',
  pecas COMMENT 'Peças vendidas, em unidades absolutas (devolução já sem sinal).'
)
COMMENT 'Responde: onde a empresa ganha e onde perde margem? Qual categoria vende muito e ganha pouco?'
WITH SCHEMA COMPENSATION
AS SELECT
  f.categoria,
  SUM(f.receita) AS receita,
  SUM(f.margem) AS margem,
  SUM(f.margem) / NULLIF(SUM(f.receita), 0) AS margem_pct,
  AVG((p.preco_tabela - p.custo_unitario) / NULLIF(p.preco_tabela, 0)) AS margem_tabela_pct,
  SUM(ABS(f.quantidade)) AS pecas
FROM lakehouse_mecamecanica.gold.fato_vendas f
JOIN lakehouse_mecamecanica.gold.dim_produto p ON p.sku = f.sku
GROUP BY f.categoria;

CREATE OR REPLACE VIEW lakehouse_mecamecanica.gold.efeito_lancamento (
  sku COMMENT 'Código do produto (SKU).',
  descricao COMMENT 'Nome do produto.',
  marca COMMENT 'Marca do produto.',
  data_lancamento COMMENT 'Data em que o SKU entrou na linha.',
  receita_120_dias COMMENT 'Receita gerada nos primeiros 120 dias após o lançamento.',
  receita_depois COMMENT 'Receita gerada do 121º dia em diante.',
  receita_total COMMENT 'Receita total do SKU no período.',
  peso_do_lancamento COMMENT 'Fatia da receita do SKU que veio dos 120 primeiros dias, de 0 a 1.'
)
COMMENT 'Responde: o quanto o lançamento de um produto puxa a receita? Quanto do faturamento vem da janela de novidade?'
WITH SCHEMA COMPENSATION
AS SELECT
  p.sku, p.descricao, p.marca, p.data_lancamento,
  SUM(CASE WHEN DATEDIFF(f.data_pedido, p.data_lancamento) BETWEEN 0 AND 120
           THEN f.receita ELSE 0 END) AS receita_120_dias,
  SUM(CASE WHEN DATEDIFF(f.data_pedido, p.data_lancamento) > 120
           THEN f.receita ELSE 0 END) AS receita_depois,
  SUM(f.receita) AS receita_total,
  SUM(CASE WHEN DATEDIFF(f.data_pedido, p.data_lancamento) BETWEEN 0 AND 120
           THEN f.receita ELSE 0 END) / NULLIF(SUM(f.receita), 0) AS peso_do_lancamento
FROM lakehouse_mecamecanica.gold.fato_vendas f
JOIN lakehouse_mecamecanica.gold.dim_produto p ON p.sku = f.sku
WHERE p.data_lancamento IS NOT NULL
GROUP BY p.sku, p.descricao, p.marca, p.data_lancamento;

CREATE OR REPLACE VIEW lakehouse_mecamecanica.gold.ruptura_por_marca (
  marca COMMENT 'Marca do produto.',
  snapshots COMMENT 'Quantidade de leituras de estoque para a marca.',
  snapshots_em_ruptura COMMENT 'Quantas dessas leituras estavam com saldo zerado.',
  ruptura_pct COMMENT 'Fatia das leituras em ruptura, de 0 a 1.',
  saldo_medio COMMENT 'Saldo médio em unidades nas leituras.'
)
COMMENT 'Responde: quais marcas mais faltam no estoque? Peça em falta atrasa o atendimento da oficina e pode empurrar a venda para outro fornecedor.'
WITH SCHEMA COMPENSATION
AS SELECT
  p.marca,
  COUNT(*) AS snapshots,
  SUM(CASE WHEN e.ruptura THEN 1 ELSE 0 END) AS snapshots_em_ruptura,
  AVG(CASE WHEN e.ruptura THEN 1.0 ELSE 0.0 END) AS ruptura_pct,
  AVG(e.saldo) AS saldo_medio
FROM lakehouse_mecamecanica.silver.estoque e
JOIN lakehouse_mecamecanica.gold.dim_produto p ON p.sku = e.sku
GROUP BY p.marca;
