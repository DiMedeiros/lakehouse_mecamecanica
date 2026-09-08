-- Quem tem cliente na fila desta semana. Alimenta o filtro da tela.
SELECT   vendedor, COUNT(*) AS contatos
FROM     lakehouse_mecamecanica.gold.fila_semanal
GROUP BY vendedor
ORDER BY contatos DESC, vendedor
