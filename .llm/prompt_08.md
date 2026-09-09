# Prompt 8 · A fila e o agente

**Entrega:** `gold.fila_semanal` — os 200 contatos da semana, mais as
quatro ferramentas que o agente consulta. **Deploy nº 8.**

> Score não é decisão. `0,9740` não é uma ação. Este prompt é o último
> metro: o que separa o modelo que roda do modelo que alguém usa.

---

## Contexto desta entrega

Terceira e última entrega da trilha de ciência de dados. As 4 funções SQL
(corpo exato) e o schema da tabela foram recuperados sem perda do catálogo
real (`DESCRIBE FUNCTION EXTENDED`); a query que monta `motivo`/`sugestao`
foi reconstruída por aproximação, já que `CREATE OR REPLACE TABLE` não
preserva a query-fonte.

**Duas melhorias implementadas nesta sessão, fora do roteiro original do
curso:**

1. **Fila priorizada por valor esperado, não só por score.**
   `valor_esperado = score × margem_percentual × ticket_medio`. Medido
   contra o catálogo antes de aplicar: troca 29 dos 200 clientes e sobe o
   valor esperado total de R$ 203.066,74 para **R$ 209.344,50 (+3,1%)**,
   com o mesmo esforço de ligação.
2. **Sugestão nunca oferece SKU em ruptura.** Eram 34 das 200 sugestões
   antigas com saldo zero (17% da fila). `sugerir_produtos` +
   `checar_disponibilidade` agora são combinados com filtro de ruptura
   antes de compor a coluna; quando todo o histórico do cliente está em
   ruptura, cai para uma alternativa com estoque na marca que ele mais
   compra (3 dos 200 clientes usaram esse caminho, na primeira execução).

## O prompt (adaptado, incluindo as duas melhorias)

```
Crie src/ml/11-fila.sql.

Elegibilidade: silver.carteira.vigente = true (já implica vendedor ativo).

candidatos: junte elegiveis + score_propensao + features_cliente, calcule
  valor_esperado = score * margem_percentual * ticket_medio
top200: os 200 candidatos de maior valor_esperado (não score puro).
ordem: ROW_NUMBER() PARTITION BY vendedor ORDER BY valor_esperado DESC.

motivo: CASE explicando em português (comprou lançamento recente > cliente
  grande > atrasado no ciclo > oportunidade aberta > ELSE score alto).

sugestao: LEFT JOIN LATERAL em sugerir_produtos(cliente_id) + checar_
  disponibilidade(sku), filtrando WHERE NOT ruptura, top 1 por
  quantidade_total. Se todo o histórico estiver em ruptura, LEFT JOIN
  LATERAL numa segunda etapa: marca preferida do cliente (maior receita em
  fato_vendas) + dim_produto não descontinuado + checar_disponibilidade,
  top 1 por saldo. Texto final diferencia "Oferecer X" de "Item de costume
  sem estoque. Alternativa da marca Y".

As quatro funções (checar_disponibilidade, sugerir_produtos,
contexto_cliente, priorizar_carteira) vêm primeiro no arquivo (não
dependem da tabela); priorizar_carteira vem por último (consulta
fila_semanal) e também expõe valor_esperado.

COMMENT em toda coluna, incluindo a nova valor_esperado.
```

## Como verificar a feature

```sql
SELECT COUNT(*) total, COUNT(DISTINCT vendedor) vendedores,
       ROUND(SUM(valor_esperado),2) total_valor_esperado
FROM lakehouse_mecamecanica.gold.fila_semanal;
-- 200 · 35 · 209344.50

SELECT COUNT(*) FROM lakehouse_mecamecanica.gold.fila_semanal
WHERE sugestao LIKE '%Saldo atual: 0 un%';
-- 0 (eram 34 antes da correção)

SELECT COUNT(*) FROM lakehouse_mecamecanica.gold.fila_semanal
WHERE sugestao LIKE 'Item de costume sem estoque%';
-- 3 (o caminho raro, testado e confirmado funcionando)
```

Rodado ponta a ponta no workspace, com o modelo v7.
