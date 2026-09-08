-- @param vendedor STRING = Todos
-- Os 200 contatos da semana, com o texto pronto para leitura humana.
-- 'Todos' devolve os 200; qualquer outro valor filtra por vendedor.
SELECT   vendedor,
         ordem,
         cliente_id,
         razao_social,
         cidade,
         uf,
         score,
         faixa,
         ticket_medio,
         motivo,
         sugestao
FROM     lakehouse_mecamecanica.gold.fila_semanal
WHERE    :vendedor = 'Todos' OR vendedor = :vendedor
ORDER BY score DESC
