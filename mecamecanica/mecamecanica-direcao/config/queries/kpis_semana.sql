-- Os quatro números que o diretor olha antes de qualquer tabela.
-- A fila da semana, a métrica do modelo que a gerou e o retorno já registrado.
WITH fila AS (
  SELECT COUNT(*)                        AS contatos,
         COUNT(DISTINCT vendedor)        AS vendedores,
         SUM(score * ticket_medio)       AS receita_esperada
  FROM   lakehouse_mecamecanica.gold.fila_semanal
),
-- fila_semanal não guarda a data de corte; ela vem de score_propensao, a
-- tabela que a originou.
referencia AS (
  SELECT MAX(_referencia) AS referencia
  FROM   lakehouse_mecamecanica.gold.score_propensao
),
modelo AS (
  SELECT acertos_top200, lift_top200, taxa_base, versao
  FROM   lakehouse_mecamecanica.gold.modelo_metricas
  QUALIFY ROW_NUMBER() OVER (ORDER BY versao DESC) = 1
),
retorno AS (
  SELECT COUNT(*)                     AS ligacoes_registradas,
         COUNT_IF(status = 'vendeu')  AS vendas
  FROM   lakehouse_mecamecanica.gold.retorno_ligacao
)
SELECT fila.contatos,
       fila.vendedores,
       fila.receita_esperada,
       referencia.referencia,
       modelo.acertos_top200,
       modelo.lift_top200,
       modelo.taxa_base,
       modelo.versao,
       retorno.ligacoes_registradas,
       retorno.vendas
FROM fila, referencia, modelo, retorno
