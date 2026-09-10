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
2. **Sugestão nunca oferece SKU em ruptura, e nomeia a substituição de
   forma consciente.** Eram 34 das 200 sugestões antigas com saldo zero
   (17% da fila). Numa primeira versão, o substituto era escolhido só por
   marca preferida do cliente (sem exigir a mesma categoria — podia
   sugerir qualquer peça da marca certa no lugar da que faltou) e o texto
   só avisava genericamente que havia uma troca, sem nomear o produto
   original. Corrigido depois de uma conversa sobre o que "similar"
   significa para autopeças: a compatibilidade real é **categoria +
   aplicação** (uma pastilha de freio só substitui outra pastilha de freio,
   da mesma linha de veículo) — marca é preferência, não compatibilidade, e
   só desempata entre candidatos já compatíveis. A sugestão agora sempre
   identifica o produto preferido do cliente e, quando ele falta, nomeia
   **os dois**: "Cliente costuma levar X, sem estoque. Oferecer substituto:
   Y." Na versão final, 40 dos 200 contatos caem em substituição.

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

sugestao: identifique o produto PREFERIDO do cliente (top 1 de
  sugerir_produtos por quantidade_total, independente de estoque) e
  verifique disponibilidade com checar_disponibilidade. Se disponível,
  "Oferecer X". Se em ruptura, procure substituto da MESMA categoria +
  aplicação (nunca só mesma marca): primeiro no próprio histórico do
  cliente (sugerir_produtos filtrado por categoria/aplicação do preferido),
  depois no catálogo inteiro priorizando a marca que o cliente mais compra,
  por fim qualquer marca com estoque. Texto nomeia os dois produtos:
  "Cliente costuma levar X, sem estoque. Oferecer substituto: Y." Sem
  substituto em nenhum caminho, diz isso explicitamente.

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
WHERE sugestao LIKE 'Cliente costuma levar%sem estoque%';
-- 40 (substituição explícita, nomeando os dois produtos)
```

Rodado ponta a ponta no workspace, com o modelo v7. A busca por candidato
similar usa LATERAL correlacionado a duas colunas de fora ao mesmo tempo
(`t.cliente_id` e `preferido.categoria`/`aplicacao`) — descoberto durante o
teste que Databricks SQL não aceita referenciar uma coluna de um LATERAL
anterior dentro do `ORDER BY` de outro LATERAL (`UNSUPPORTED_SUBQUERY_
EXPRESSION_CATEGORY`); a correção foi mover essa comparação para o `WHERE`,
dividindo a busca por marca preferida e a busca geral em dois LATERALs
sequenciais em vez de um só com `ORDER BY CASE`.
