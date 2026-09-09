# Prompt 10 · O app — a fila dos 200 na tela

**Entrega:** o app `mecamecanica-direcao` no ar, com os quatro números da
semana, os 200 contatos filtráveis por vendedor e o Genie do prompt 9
embutido. **Deploy nº 10.**

> O primeiro `apps deploy` cria o compute do zero. O segundo é bem mais
> rápido — deploy de app não é deploy de bundle, tem ciclo próprio.

---

## Contexto desta entrega

Segunda entrega da trilha "app e genie". Diferente das entregas de ML, aqui
existe uma referência completa e funcional (`rotaperfume-direcao/`, o app
de exemplo do curso) — o trabalho foi adaptar esse código, não reconstruir
do zero.

**Bloqueio real encontrado:** Node.js/npm não estava instalado na máquina.
Instalado via `winget install OpenJS.NodeJS.LTS`, com aprovação explícita
antes de mexer no sistema.

## O prompt (resumo, adaptado)

```
databricks apps init --name mecamecanica-direcao \
  --features analytics,genie \
  --set analytics.sql-warehouse.id=<warehouse_id> \
  --set genie.genie-space.id=<id do space "mecamecanica · Direção"> \
  --set genie.genie-space.name="mecamecanica · Direção" \
  --run none --profile <perfil>

config/queries/*.sql (nunca SQL dentro do React):
  kpis_semana.sql   contatos, vendedores, receita esperada, referência da
                     fila (vem de gold.score_propensao — fila_semanal não
                     guarda a data de corte), acertos_top200/lift_top200/
                     taxa_base da ÚLTIMA versão de modelo_metricas, e a
                     contagem de retorno_ligacao
  vendedores.sql    vendedor -> contatos, para o filtro
  fila.sql          os 200, parâmetro @param vendedor STRING = Todos

Duas telas: "A semana" (KPIs + Select de vendedor + tabela) e "Perguntar"
(GenieChat + /api/quem-sou lendo x-forwarded-email).

Formate em português: R$ com toLocaleString('pt-BR'), score como
porcentagem inteira. O warehouse devolve número como STRING no JSON — passe
por Number() antes de formatar ou somar.

Depois do primeiro deploy, leia o service principal do app
(databricks apps get ... service_principal_client_id) e conceda:
  GRANT USE CATALOG ON CATALOG lakehouse_mecamecanica TO `<sp>`
  GRANT USE SCHEMA  ON SCHEMA  lakehouse_mecamecanica.gold TO `<sp>`
  GRANT SELECT      ON SCHEMA  lakehouse_mecamecanica.gold TO `<sp>`

databricks apps validate --profile <perfil>
databricks apps deploy -t default --profile <perfil>
```

## Se der errado (aconteceu ao vivo)

| Sintoma | Causa | Saída |
|---|---|---|
| Toda tela vazia, sem erro | SP sem GRANT | os 3 GRANTs — `CAN_USE` no warehouse não dá acesso ao dado |
| Build remoto falha com `INSUFFICIENT_PERMISSIONS: User does not have USE CATALOG` | mesmo motivo, mas na hora do build (typegen roda como o SP) | aplicar os GRANTs antes do 2º deploy |
| `npm: command not found` | Node.js não instalado | `winget install OpenJS.NodeJS.LTS`, depois `export PATH="/c/Program Files/nodejs:$PATH"` em cada comando desta sessão |
| typegen mostra `OFFLINE` sem explicação | warehouse parado, ou o CLI degrada silenciosamente | rodar com `--wait` para ver o erro real em vez de "OFFLINE" |

## Como verificar a feature

```bash
databricks apps get mecamecanica-direcao --profile <perfil> -o json
# app_status RUNNING · compute_status ACTIVE
```

```sql
SELECT COUNT(*) contatos, COUNT(DISTINCT vendedor) vendedores,
       ROUND(SUM(score*ticket_medio),2) receita_esperada
FROM lakehouse_mecamecanica.gold.fila_semanal;
-- 200 · 35 · 505779.45 (na 1ª verificação, modelo v6)
```

Número confere com o cartão "Receita esperada" da tela.
