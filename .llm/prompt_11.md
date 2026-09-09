# Prompt 11 · O retorno — o ciclo se fecha

**Entrega:** os quatro botões que gravam, a aba *Acompanhamento* e a
primeira linha de `gold.retorno_ligacao` escrita ao vivo. **Deploy nº 11 —
o último da trilha "app e genie".**

> Clique em Vendeu, rode um `SELECT`, mostre a linha. O dado saiu do
> pipeline, foi para a tela, e voltou.

---

## Contexto desta entrega

Terceira e última entrega da trilha "app e genie", fechando o ciclo:
pipeline → score → fila → ligação → retorno → (rótulo de treino da semana
seguinte, ainda não implementado — ver `ideia-feature-retorno-ligacao` na
memória do projeto).

## O prompt (resumo, adaptado)

```
POST /api/retorno em server/server.ts, dentro de onPluginsReady, corpo
validado por Zod ANTES de tocar no banco:
  cliente_id  z.coerce.number().int()   (o warehouse devolve id como STRING)
  vendedor    string não vazia
  status      enum: vendeu | vai_pensar | sem_interesse | nao_atendeu
  comentario  string, máximo 500, opcional
  referencia  aaaa-mm-dd

Corpo inválido devolve 400 sem consultar o warehouse. INSERT via
getExecutionContext().client.statementExecution.executeStatement, TODO
valor como parameters, nunca concatenado. registrado_por do header
x-forwarded-email (com valor local de dev como reserva).

Coluna "Como foi a ligação" na tabela de "A semana": Input + 4 Button para
quem não tem retorno (desabilita durante a gravação); Badge + comentário
para quem já tem. Alert se a gravação falhar.

cache: { enabled: false } no createApp + estado (vendedor, comentários) no
componente PAI + key que muda a cada gravação, para remontar o filho sem
parâmetro falso no SQL.

Aba "Acompanhamento" (acompanhamento.sql): frase-resumo, barras por
vendedor (trabalhados x vendeu), tabela de desfecho. Empty quando ninguém
registrou ainda — zero não é erro.

GRANT MODIFY ON TABLE lakehouse_mecamecanica.gold.retorno_ligacao TO
`<sp>` — em TABLE, não em SCHEMA: o app não pode alterar mais nada da gold.
```

## Como verificar a feature

Sem navegador conectado nesta sessão — testado via `curl` com um token
OAuth do próprio profile CLI (`databricks auth token`), direto contra o
app publicado:

```bash
TOKEN=$(databricks auth token --profile <perfil> | jq -r .access_token)

# 1. contrato recusa corpo inválido, sem tocar no banco
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"cliente_id":2137,"vendedor":"...","status":"talvez","referencia":"2026-08-31"}' \
  https://<url-do-app>/api/retorno
# 400, com os 4 valores aceitos na resposta

# 2. retorno válido
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"cliente_id":2481,"vendedor":"Henrique Alves","status":"vendeu",...}' \
  https://<url-do-app>/api/retorno
# 201
```

```sql
SELECT cliente_id, vendedor, status, comentario, registrado_por, registrado_em
FROM lakehouse_mecamecanica.gold.retorno_ligacao;
```

A linha apareceu com o e-mail de quem chamou o endpoint em
`registrado_por` — o header `x-forwarded-email` do Databricks Apps
funcionou mesmo fora do navegador. KPI "Já trabalhados" foi de 0 para 1.
Perguntando de novo ao Genie "Direção" a mesma pergunta de antes
("Quantas ligações já foram registradas e quantas viraram pedido?"), a
resposta mudou de "ninguém registrou" para **"1 ligação, 1 virou
pedido"** — nenhuma linha de código do Genie mudou, só o dado embaixo.

Registro de teste removido depois (`DELETE FROM gold.retorno_ligacao WHERE
cliente_id = 2481`), deixando a tabela zerada para o primeiro uso real do
time.
