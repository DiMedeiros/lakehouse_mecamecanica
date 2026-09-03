-- Gold — 9 testes de qualidade. Cada um: um SELECT de diagnóstico (nome,
-- valor calculado, valor esperado, passou) seguido de um SELECT-guarda que
-- levanta raise_error() quando falha, derrubando a task e o job.
--
-- Ordem: do teste mais crítico para o menos crítico. Um sql_task de arquivo
-- roda os statements em sequência numa mesma sessão e para no primeiro erro
-- — por isso o teste mais importante (conformidade de receita) vai primeiro.
--
-- Se um teste falhar, a correção é na transformação (05/06/07), NUNCA no
-- teste.

-- Teste 1 — a receita da gold é EXATAMENTE a receita da silver (tolerância 0,01)
SELECT
  'teste_1_receita_conformada' AS teste,
  (SELECT ROUND(SUM(receita), 2) FROM lakehouse_mecamecanica.gold.fato_vendas) AS valor_calculado,
  (SELECT ROUND(SUM(valor_liquido), 2) FROM lakehouse_mecamecanica.silver.pedidos) AS valor_esperado,
  abs(
    (SELECT SUM(receita) FROM lakehouse_mecamecanica.gold.fato_vendas)
    - (SELECT SUM(valor_liquido) FROM lakehouse_mecamecanica.silver.pedidos)
  ) <= 0.01 AS passou;

SELECT CASE WHEN (
    abs(
      (SELECT SUM(receita) FROM lakehouse_mecamecanica.gold.fato_vendas)
      - (SELECT SUM(valor_liquido) FROM lakehouse_mecamecanica.silver.pedidos)
    ) <= 0.01
  ) THEN 'PASSOU'
  ELSE raise_error('teste_1_receita_conformada falhou: SUM(gold.fato_vendas.receita) diverge de SUM(silver.pedidos.valor_liquido) além da tolerância de 0.01')
  END;

-- Teste 2 — CNPJ único na silver.clientes (0 duplicados)
SELECT
  'teste_2_cnpj_unico' AS teste,
  (SELECT COUNT(*) - COUNT(DISTINCT cnpj) FROM lakehouse_mecamecanica.silver.clientes) AS valor_calculado,
  0 AS valor_esperado,
  (SELECT COUNT(*) - COUNT(DISTINCT cnpj) FROM lakehouse_mecamecanica.silver.clientes) = 0 AS passou;

SELECT CASE WHEN (
    (SELECT COUNT(*) - COUNT(DISTINCT cnpj) FROM lakehouse_mecamecanica.silver.clientes) = 0
  ) THEN 'PASSOU'
  ELSE raise_error('teste_2_cnpj_unico falhou: existe CNPJ duplicado em silver.clientes')
  END;

-- Teste 3 — nenhuma data_pedido nula na silver.pedidos
SELECT
  'teste_3_data_pedido_nao_nula' AS teste,
  (SELECT COUNT(*) FROM lakehouse_mecamecanica.silver.pedidos WHERE data_pedido IS NULL) AS valor_calculado,
  0 AS valor_esperado,
  (SELECT COUNT(*) FROM lakehouse_mecamecanica.silver.pedidos WHERE data_pedido IS NULL) = 0 AS passou;

SELECT CASE WHEN (
    (SELECT COUNT(*) FROM lakehouse_mecamecanica.silver.pedidos WHERE data_pedido IS NULL) = 0
  ) THEN 'PASSOU'
  ELSE raise_error('teste_3_data_pedido_nao_nula falhou: existe data_pedido nula em silver.pedidos')
  END;

-- Teste 4 — receita negativa só onde devolucao = true, em gold.fato_vendas
SELECT
  'teste_4_negativo_so_em_devolucao' AS teste,
  (SELECT COUNT(*) FROM lakehouse_mecamecanica.gold.fato_vendas WHERE receita < 0 AND NOT devolucao) AS valor_calculado,
  0 AS valor_esperado,
  (SELECT COUNT(*) FROM lakehouse_mecamecanica.gold.fato_vendas WHERE receita < 0 AND NOT devolucao) = 0 AS passou;

SELECT CASE WHEN (
    (SELECT COUNT(*) FROM lakehouse_mecamecanica.gold.fato_vendas WHERE receita < 0 AND NOT devolucao) = 0
  ) THEN 'PASSOU'
  ELSE raise_error('teste_4_negativo_so_em_devolucao falhou: existe receita negativa em linha sem a flag devolucao')
  END;

-- Teste 5 — volume da gold.fato_vendas entre 140.000 e 250.000 linhas
SELECT
  'teste_5_volume_fato' AS teste,
  (SELECT COUNT(*) FROM lakehouse_mecamecanica.gold.fato_vendas) AS valor_calculado,
  '[140000, 250000]' AS valor_esperado,
  (SELECT COUNT(*) FROM lakehouse_mecamecanica.gold.fato_vendas) BETWEEN 140000 AND 250000 AS passou;

SELECT CASE WHEN (
    (SELECT COUNT(*) FROM lakehouse_mecamecanica.gold.fato_vendas) BETWEEN 140000 AND 250000
  ) THEN 'PASSOU'
  ELSE raise_error('teste_5_volume_fato falhou: COUNT(gold.fato_vendas) fora da faixa [140000, 250000]')
  END;

-- Teste 6 — nenhum pedido_id na gold que não exista na silver.pedidos
SELECT
  'teste_6_pedido_id_existe' AS teste,
  (SELECT COUNT(DISTINCT f.pedido_id) FROM lakehouse_mecamecanica.gold.fato_vendas f
     WHERE NOT EXISTS (SELECT 1 FROM lakehouse_mecamecanica.silver.pedidos p WHERE p.pedido_id = f.pedido_id)) AS valor_calculado,
  0 AS valor_esperado,
  (SELECT COUNT(DISTINCT f.pedido_id) FROM lakehouse_mecamecanica.gold.fato_vendas f
     WHERE NOT EXISTS (SELECT 1 FROM lakehouse_mecamecanica.silver.pedidos p WHERE p.pedido_id = f.pedido_id)) = 0 AS passou;

SELECT CASE WHEN (
    (SELECT COUNT(DISTINCT f.pedido_id) FROM lakehouse_mecamecanica.gold.fato_vendas f
       WHERE NOT EXISTS (SELECT 1 FROM lakehouse_mecamecanica.silver.pedidos p WHERE p.pedido_id = f.pedido_id)) = 0
  ) THEN 'PASSOU'
  ELSE raise_error('teste_6_pedido_id_existe falhou: existe pedido_id em gold.fato_vendas ausente de silver.pedidos')
  END;

-- Teste 7 — nenhum cliente_id na gold que não exista na silver.clientes
-- (valida o remapeamento de cliente_id descartado na dedup — ver 05/06)
SELECT
  'teste_7_cliente_id_existe' AS teste,
  (SELECT COUNT(DISTINCT f.cliente_id) FROM lakehouse_mecamecanica.gold.fato_vendas f
     WHERE NOT EXISTS (SELECT 1 FROM lakehouse_mecamecanica.silver.clientes c WHERE c.cliente_id = f.cliente_id)) AS valor_calculado,
  0 AS valor_esperado,
  (SELECT COUNT(DISTINCT f.cliente_id) FROM lakehouse_mecamecanica.gold.fato_vendas f
     WHERE NOT EXISTS (SELECT 1 FROM lakehouse_mecamecanica.silver.clientes c WHERE c.cliente_id = f.cliente_id)) = 0 AS passou;

SELECT CASE WHEN (
    (SELECT COUNT(DISTINCT f.cliente_id) FROM lakehouse_mecamecanica.gold.fato_vendas f
       WHERE NOT EXISTS (SELECT 1 FROM lakehouse_mecamecanica.silver.clientes c WHERE c.cliente_id = f.cliente_id)) = 0
  ) THEN 'PASSOU'
  ELSE raise_error('teste_7_cliente_id_existe falhou: existe cliente_id em gold.fato_vendas ausente de silver.clientes')
  END;

-- Teste 8 — mart_produto_performance soma o mesmo que fato_vendas
SELECT
  'teste_8_mart_produto_conformado' AS teste,
  (SELECT ROUND(SUM(receita), 2) FROM lakehouse_mecamecanica.gold.mart_produto_performance) AS valor_calculado,
  (SELECT ROUND(SUM(receita), 2) FROM lakehouse_mecamecanica.gold.fato_vendas) AS valor_esperado,
  abs(
    (SELECT SUM(receita) FROM lakehouse_mecamecanica.gold.mart_produto_performance)
    - (SELECT SUM(receita) FROM lakehouse_mecamecanica.gold.fato_vendas)
  ) <= 0.01 AS passou;

SELECT CASE WHEN (
    abs(
      (SELECT SUM(receita) FROM lakehouse_mecamecanica.gold.mart_produto_performance)
      - (SELECT SUM(receita) FROM lakehouse_mecamecanica.gold.fato_vendas)
    ) <= 0.01
  ) THEN 'PASSOU'
  ELSE raise_error('teste_8_mart_produto_conformado falhou: SUM(mart_produto_performance.receita) diverge de SUM(fato_vendas.receita)')
  END;

-- Teste 9 — todo CNPJ com exatamente 14 dígitos (redundante com a constraint
-- da Entrega 3, checagem explicitamente pedida)
SELECT
  'teste_9_cnpj_14_digitos' AS teste,
  (SELECT COUNT(*) FROM lakehouse_mecamecanica.silver.clientes WHERE length(cnpj) <> 14) AS valor_calculado,
  0 AS valor_esperado,
  (SELECT COUNT(*) FROM lakehouse_mecamecanica.silver.clientes WHERE length(cnpj) <> 14) = 0 AS passou;

SELECT CASE WHEN (
    (SELECT COUNT(*) FROM lakehouse_mecamecanica.silver.clientes WHERE length(cnpj) <> 14) = 0
  ) THEN 'PASSOU'
  ELSE raise_error('teste_9_cnpj_14_digitos falhou: existe CNPJ com número de dígitos diferente de 14 em silver.clientes')
  END;
