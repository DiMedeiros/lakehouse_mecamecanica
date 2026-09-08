-- Gold — três views de métricas de negócio, para consumo direto por Genie
-- (genie_direcao) e dashboard. Views, não tabelas: sempre refletem o estado
-- mais recente de fato_vendas/dim_cliente/dim_calendario, sem reprocessar.

CREATE OR REPLACE VIEW lakehouse_mecamecanica.gold.clientes_em_risco (
  cliente_id COMMENT 'Identificador do cliente.',
  razao_social COMMENT 'Razão social do cliente.',
  segmento COMMENT 'Segmento do cliente.',
  cidade COMMENT 'Cidade do cliente.',
  uf COMMENT 'UF do cliente.',
  dias_sem_comprar COMMENT 'Dias desde o último pedido do cliente, até a última carga da gold.',
  receita_media_mensal COMMENT 'Receita média mensal do cliente, calculada sobre o período em que ele comprou (do primeiro ao último pedido) — quanto ele costumava comprar antes de sumir.'
)
COMMENT 'Responde: quais clientes pararam de comprar (mais de 90 dias sem pedido), e quanta receita a empresa está deixando de ganhar com isso?'
WITH SCHEMA COMPENSATION
AS SELECT
  d.cliente_id, d.razao_social, d.segmento, d.cidade, d.uf,
  d.dias_sem_comprar,
  d.receita_acumulada / GREATEST(MONTHS_BETWEEN(d.data_ultimo_pedido, d.data_primeiro_pedido) + 1, 1) AS receita_media_mensal
FROM lakehouse_mecamecanica.gold.dim_cliente d
WHERE d.dias_sem_comprar > 90;

CREATE OR REPLACE VIEW lakehouse_mecamecanica.gold.ranking_marcas (
  marca COMMENT 'Marca do produto.',
  receita COMMENT 'Receita total da marca, todo o histórico.',
  margem COMMENT 'Margem total da marca.',
  margem_pct COMMENT 'Margem dividida pela receita da marca (0 a 1).',
  participacao_pct COMMENT 'Participação da marca na receita total da empresa (0 a 1).'
)
COMMENT 'Responde: quais marcas mais vendem, com que margem, e qual a participação de cada uma na receita total da empresa?'
WITH SCHEMA COMPENSATION
AS WITH por_marca AS (
  SELECT marca, SUM(receita) AS receita, SUM(margem) AS margem
  FROM lakehouse_mecamecanica.gold.fato_vendas
  GROUP BY marca
),
total AS (
  SELECT SUM(receita) AS receita_total FROM lakehouse_mecamecanica.gold.fato_vendas
)
SELECT
  m.marca, m.receita, m.margem,
  m.margem / NULLIF(m.receita, 0) AS margem_pct,
  m.receita / NULLIF(t.receita_total, 0) AS participacao_pct
FROM por_marca m
CROSS JOIN total t;

CREATE OR REPLACE VIEW lakehouse_mecamecanica.gold.receita_mensal (
  ano COMMENT 'Ano do pedido.',
  mes COMMENT 'Mês do pedido (1 a 12).',
  nome_mes COMMENT 'Nome do mês, de gold.dim_calendario.',
  mes_pico_setor COMMENT 'true se este mês é pico sazonal do setor de autopeças. Sazonalidade INVERTIDA: o pico é o mês ANTERIOR à data comemorativa (ex.: abril antes do Dia das Mães), não o mês dela.',
  receita COMMENT 'Soma da receita líquida do mês (devolução já incluída, com sinal negativo).',
  margem COMMENT 'Soma da margem do mês.',
  pedidos COMMENT 'Pedidos distintos no mês.'
)
COMMENT 'Responde: qual foi a receita, a margem e o volume de pedidos por mês, e quais meses são pico sazonal do setor?'
WITH SCHEMA COMPENSATION
AS WITH calendario_mes AS (
  SELECT DISTINCT ano, mes, nome_mes, mes_pico_setor
  FROM lakehouse_mecamecanica.gold.dim_calendario
)
SELECT
  f.ano, f.mes, c.nome_mes, c.mes_pico_setor,
  SUM(f.receita) AS receita,
  SUM(f.margem) AS margem,
  COUNT(DISTINCT f.pedido_id) AS pedidos
FROM lakehouse_mecamecanica.gold.fato_vendas f
LEFT JOIN calendario_mes c ON c.ano = f.ano AND c.mes = f.mes
GROUP BY f.ano, f.mes, c.nome_mes, c.mes_pico_setor;
