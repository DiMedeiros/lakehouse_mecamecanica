-- @param vendedor STRING = Todos
-- A fila da semana com o último retorno já registrado de cada cliente.
-- 'Todos' devolve os 200; qualquer outro valor filtra por vendedor.
WITH ultimo_retorno AS (
  SELECT cliente_id, status, comentario, registrado_em
  FROM   lakehouse_mecamecanica.gold.retorno_ligacao
  QUALIFY ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY registrado_em DESC) = 1
)
SELECT   f.vendedor,
         f.ordem,
         f.cliente_id,
         f.razao_social,
         f.cidade,
         f.uf,
         f.score,
         f.faixa,
         f.ticket_medio,
         f.valor_esperado,
         f.motivo,
         f.sugestao,
         r.status      AS retorno_status,
         r.comentario  AS retorno_comentario
FROM     lakehouse_mecamecanica.gold.fila_semanal f
LEFT JOIN ultimo_retorno r ON r.cliente_id = f.cliente_id
WHERE    :vendedor = 'Todos' OR f.vendedor = :vendedor
-- a fila é priorizada por valor_esperado (score x margem x ticket), não só
-- por score — a ordem de exibição precisa bater com a de gold.fila_semanal.
ORDER BY f.valor_esperado DESC
