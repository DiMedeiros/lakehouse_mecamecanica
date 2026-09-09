-- O que a semana virou. Sem retorno registrado, tudo aqui volta zerado —
-- e isso é a resposta certa, não um bug.
WITH base AS (
  SELECT f.vendedor,
         f.cliente_id,
         r.status
  FROM   lakehouse_mecamecanica.gold.fila_semanal f
  LEFT JOIN (
    SELECT cliente_id, status
    FROM   lakehouse_mecamecanica.gold.retorno_ligacao
    QUALIFY ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY registrado_em DESC) = 1
  ) r ON r.cliente_id = f.cliente_id
)
SELECT   vendedor,
         COUNT(*)                              AS na_fila,
         COUNT_IF(status IS NOT NULL)          AS trabalhados,
         COUNT_IF(status = 'vendeu')           AS vendeu,
         COUNT_IF(status = 'vai_pensar')       AS vai_pensar,
         COUNT_IF(status = 'sem_interesse')    AS sem_interesse,
         COUNT_IF(status = 'nao_atendeu')      AS nao_atendeu
FROM     base
GROUP BY vendedor
ORDER BY trabalhados DESC, na_fila DESC, vendedor
