# Prompt 12 · Agentes de IA — o mesmo dado, outra porta

**Entrega:** views com nome de negócio, auditoria de metadado, o Genie
comercial configurado e as instruções do agente. **Fecha o arco da
aula-02** (era o prompt 6 dela — renumerado aqui para 12 porque as trilhas
de ciência de dados e app já ocupavam 6-11).

> O que faz o agente funcionar não é o modelo — é o dado. O mesmo Genie, o
> mesmo LLM, a mesma pergunta. O que muda está embaixo dele.

---

## Contexto desta entrega

Esta era a última das seis entregas originais da aula-02 (engenharia de
dados), e nunca tinha sido implementada neste projeto — o `.llm/` foi
direto do `prompt_05` (dashboard) para a reconstrução da trilha de ciência
de dados depois do incidente do antivírus. Ao recuperar o catálogo real na
época, descobri que 3 das 6 views desta entrega **já existiam**
(`clientes_em_risco`, `ranking_marcas`, `receita_mensal`, criadas como
pré-requisito do Genie da direção — prompt 9) — sinal de que uma sessão
anterior já tinha começado este prompt sem terminar. Esta entrega completou
as 3 views que faltavam e as 3 que estavam parciais.

## O prompt (adaptado)

```
1. src/gold/09-metricas-negocio.sql — completar as 3 views existentes e
   criar 3 novas, todas com COMMENT dizendo QUAL PERGUNTA respondem:
     receita_mensal        + mes_vale_setor, ticket_medio, margem_pct
     ranking_marcas        + skus, pedidos
     clientes_em_risco     + ultimo_pedido, total_pedidos, receita_acumulada
     margem_por_categoria  categoria → receita, margem, margem_pct,
                           margem_tabela_pct (preco_tabela vs custo_unitario)
     efeito_lancamento     receita dos SKUs nos 120 dias após o lançamento
                           contra o resto do período
     ruptura_por_marca     % de snapshots em ruptura por marca

2. src/gold/11-auditoria-metadado.sql — consulte information_schema e
   QUEBRE com raise_error() se alguma tabela/view da gold estiver sem
   COMMENT, ou alguma coluna de fato_vendas ou das 6 views estiver sem
   COMMENT. Ao final, um relatório de cobertura por objeto, sem quebrar.

3. Genie space "mecamecanica · Comercial", de propósito geral (12 fontes:
   as 6 views + fato_vendas + 4 dimensões + fila_semanal + score_propensao)
   — diferente do Genie da direção (7 fontes, uma decisão só). Instruções:
   contexto do negócio (distribuidora de autopeças), glossário (ruptura,
   carteira, oportunidade, devolução, segmento, aplicação, curva ABC,
   churn), a regra de sazonalidade invertida, como calcular cada métrica.
   5 sample_questions + 6 example_question_sqls, ids gerados por md5
   determinístico do conteúdo (nunca aleatório).

4. Acrescente auditoria_de_metadado ao pipeline, depois de
   gold_metricas_negocio.
```

## O que a auditoria encontrou de verdade

Rodada pela primeira vez, a auditoria **quebrou o job de verdade** —
`fato_vendas._processado_em` nunca teve `COMMENT`, desde a Entrega 4.
Corrigido em `src/gold/06-fato-vendas.sql` e aplicado direto na tabela
(`COMMENT ON COLUMN`), sem precisar reprocessar o fato inteiro.

Testada também quebrando de propósito (`CREATE VIEW gold._sem_comentario AS
SELECT 1`, sem COMMENT nenhum) — a tarefa falhou como esperado — e depois
de limpar (`DROP VIEW`), voltou a passar.

## Armadilha medida

O deploy do Genie Space falhou na primeira tentativa:
`Table 'lakehouse_mecamecanica.gold.efeito_lancamento' does not exist` — a
API do Genie valida que as fontes existem **no momento da criação**. As 3
views novas precisaram ser criadas primeiro (rodando a tarefa
`gold_metricas_negocio`), só depois o Genie Space pôde ser criado.

## Como verificar a feature

```sql
-- as views não podem inventar número
SELECT
  (SELECT ROUND(SUM(receita),2) FROM lakehouse_mecamecanica.gold.fato_vendas)    AS fato,
  (SELECT ROUND(SUM(receita),2) FROM lakehouse_mecamecanica.gold.receita_mensal) AS view_mensal,
  (SELECT ROUND(SUM(receita),2) FROM lakehouse_mecamecanica.gold.ranking_marcas) AS view_marcas;
-- as três colunas: R$ 102.303.828,05
```

Testado via Conversation API, sem navegador:

| Pergunta | Resposta do Genie |
|---|---|
| "Dezembro foi um mês ruim?" | Reconheceu vale esperado do setor, citou receita real de dez/2024-2026, nunca chamou de queda |
| "Quais clientes pararam de comprar, e quanta receita a gente perdeu com isso?" | Listou 50 clientes de `clientes_em_risco`, ordenados por receita média mensal perdida |

Ambas usaram exatamente o SQL curado em `example_question_sqls`.
