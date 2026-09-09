# Prompt 9 · O Genie da direção

**Entrega:** o space `mecamecanica · Direção` como código no bundle, mais
`gold.retorno_ligacao` e a tarefa que a cria. **Deploy nº 9.**

> O Genie comercial (prompt 6) tem doze fontes e serve para perguntar
> qualquer coisa. Este tem sete e serve para responder **uma decisão**. A
> diferença não é técnica — é de audiência.

---

## Contexto desta entrega

Primeira entrega da trilha "app e genie" (aula-04). Recuperada por caminhos
**sem perda**: `gold.retorno_ligacao` veio de `DESCRIBE TABLE EXTENDED` na
tabela real, e o Genie Space veio do comando oficial
`databricks bundle generate genie-space --existing-id <space_id>`, que
baixa o `serialized_space` completo direto da API. Conferência linha a
linha contra o `prompt-01-genie.md` original não encontrou nenhuma
divergência — diferente do caso do modelo, aqui não houve reconstrução
aproximada.

## O prompt

```
1. src/gold/10-retorno-ligacao.sql — CREATE TABLE IF NOT EXISTS (nunca
   REPLACE: é a única tabela do projeto cujo dado não vem do pipeline, vem
   do time — um redeploy não pode apagar o que o vendedor respondeu):
     cliente_id, vendedor, status (vendeu|vai_pensar|sem_interesse|
     nao_atendeu), comentario, registrado_em, registrado_por, _referencia
   COMMENT em toda coluna e na tabela.

2. Genie space "mecamecanica · Direção", só com estas 7 fontes:
     gold.fila_semanal, gold.score_propensao, gold.modelo_metricas,
     gold.retorno_ligacao, gold.clientes_em_risco, gold.ranking_marcas,
     gold.receita_mensal
   Instruções cobrindo: score/faixa/ordem/motivo, fila GLOBAL (não cota por
   vendedor), receita esperada = SUM(score*ticket_medio) como ESTIMATIVA,
   retorno_ligacao começa vazia (dizer que ninguém registrou, nunca
   inventar número), retorno mais recente por registrado_em quando há mais
   de um por cliente, sazonalidade invertida, métrica é lift_top200 —
   NUNCA cite AUC, nunca use o schema bronze.
   5 sample_questions + 5 example_question_sqls, incluindo "Quem eu ligo
   essa semana?", "Quanto vale a fila desta semana?" e "Quantas ligações
   já foram registradas e quantas viraram pedido?".

3. Acrescente gold_retorno_ligacao ao pipeline, depois de gold_marts.
```

## Como verificar a feature

Testado via Conversation API (`databricks genie start-conversation` /
`get-message`), sem navegador:

| Pergunta | Resposta do Genie |
|---|---|
| "Quanto vale a fila desta semana?" | **R$ 505.779,45**, citando "estimativa e não receita confirmada" |
| "Quantas ligações já foram registradas?" | **0**, "ninguém registrou retorno de ligação" |
| "O modelo é bom?" | **lift_top200 de 4,20**, **85 acertos** — sem citar AUC nenhuma vez |

Todas batendo com a query SQL correspondente.
