# Lakehouse Mecamecanica

Lakehouse de ponta a ponta sobre Databricks (Unity Catalog + Declarative Automation Bundles) simulando a operação comercial de uma rede de autopeças: ingestão de ERP/CRM, camadas bronze/silver/gold, dashboard de BI, Genie spaces para perguntas em linguagem natural e um modelo de ML que prioriza a fila semanal de ligações dos vendedores.

## Estrutura do repositório

Monorepo com dados brutos na raiz e o projeto Databricks em um subdiretório:

- **`dados/`** — CSVs de origem (ERP e CRM) que simulam a extração dos sistemas legados. Não são gerados pelo pipeline; são o ponto de partida que sobe para o Volume `bronze.raw` no Unity Catalog.
  - `dados/erp/`: `produtos`, `pedidos`, `itens_pedido`, `pagamentos`, `estoque`
  - `dados/crm/`: `clientes`, `vendedores`, `carteira`, `oportunidades`, `visitas`
- **`mecamecanica/`** — o Databricks Asset Bundle (DAB) propriamente dito. Todo o trabalho de engenharia (catálogo, schemas, volumes, jobs, dashboard, Genie spaces, modelo de ML) vive aqui. Veja `mecamecanica/README.md` e `mecamecanica/AGENTS.md` para detalhes de desenvolvimento local.
- **`.llm/`** — material de referência/roteiro do curso (prompts didáticos descrevendo as entregas planejadas incremento a incremento).

## Arquitetura de dados (medalhão)

Sobre o catálogo `lakehouse_mecamecanica` no Unity Catalog:

| Camada | Conteúdo |
|---|---|
| **raw** | Os CSVs sobem exatamente como vieram do ERP/CRM para o Volume gerenciado `bronze.raw`. |
| **bronze** | Tabelas cruas (tudo `STRING`) + tabela de controle que confere se os 10 arquivos esperados chegaram e não vieram vazios. |
| **silver** | Dados limpos, tipados e com contrato — clientes, pedidos, itens/produtos, CRM/financeiro. |
| **gold** | Dimensões conformadas, `fato_vendas`, marts de negócio, métricas (`clientes_em_risco`, `ranking_marcas`, `receita_mensal`, `margem_por_categoria`, `efeito_lancamento`, `ruptura_por_marca`), a fila semanal de contatos e a auditoria de metadado (comentários obrigatórios em tabela/view/coluna). |

Schemas, volume e job são definidos como código em `mecamecanica/resources/*.yml` — infraestrutura versionada e reproduzível via `databricks bundle deploy`, não criada manualmente na UI.

## Pipeline (`mecamecanica_pipeline`)

Job orquestrado via DAB, nesta ordem de dependência:

1. `raw_conferencia` — confere a chegada dos CSVs no Volume `bronze.raw`.
2. `bronze_ingestao` — grava as 10 tabelas Delta da bronze.
3. `silver_*` (4 tarefas em paralelo) — limpeza, tipagem e contrato das tabelas silver.
4. `gold_dimensoes` → `gold_fato_vendas` → `gold_marts` → `testes` (9 testes de qualidade que derrubam o job se falharem).
5. `gold_metricas_negocio`, `gold_retorno_ligacao` — views de negócio e a tabela de callback preenchida pelo app.
6. `ml_features` → `ml_modelo` → `ml_fila` — camada de ML (veja abaixo).
7. `auditoria_de_metadado` — quebra o job se faltar `COMMENT` em tabela/view/coluna da gold; é o que sustenta a confiabilidade do Genie.

Agendado diariamente às 06:00 (`America/Sao_Paulo`).

## Dashboard comercial

AI/BI Dashboard (Lakeview) definido como código em `mecamecanica/resources/dashboard-comercial.lvdash.json`, publicado junto com o bundle. Mostra KPIs (receita, margem, pedidos, ticket médio), tendência mensal de receita, receita por marca/canal, margem por categoria e o top 20 de clientes — com filtros de ano, segmento e cidade.

## Genie spaces

Três espaços Genie (perguntas em linguagem natural sobre a gold), por audiência:

- **`genie_comercial`** — propósito geral, qualquer pergunta de negócio sobre a gold inteira.
- **`genie_direcao`** — para a direção comercial: valor da fila da semana, saúde do modelo (`lift_top200`, nunca AUC), conversão de ligações e clientes em risco.
- **`genie_fila_semanal`** — para o vendedor: quem ligar essa semana, por quê e o que oferecer (consulta `gold.fila_semanal`, `gold.score_propensao` e as funções `priorizar_carteira`, `contexto_cliente`, `sugerir_produtos`, `checar_disponibilidade`).

## Fila de ligações (ML)

A priorização da fila semanal combina ML e regra de negócio:

- **Modelo**: `HistGradientBoostingClassifier` (gradient boosting, scikit-learn) treinado para prever `comprou_em_7d`, registrado via MLflow/Unity Catalog (`gold.propensao_compra`, alias `@prod`). Precisa superar baselines heurísticos e atingir `lift_top200 >= 2.5x` para ser aceito.
- **Fila final**: `gold.fila_semanal` ordena por `valor_esperado = score * ticket_medio * margem_percentual` (SQL), não só pelo score do modelo — os 200 primeiros da fila.
- **Sugestão de produto/recompra**: 100% regra em SQL (histórico de compra + estoque + categoria/aplicação), sem ML.

## Comandos comuns (dentro de `mecamecanica/`)

```bash
uv sync --dev                                              # instalar dependências
uv run pytest                                              # rodar testes locais
databricks bundle validate --target dev --profile <nome>   # validar o bundle
databricks bundle deploy   --target dev --profile <nome>   # deploy (dev é o target default)
databricks bundle deploy   --target prod --profile <nome>  # deploy de produção
databricks bundle run <job_ou_pipeline> --target dev --profile <nome>
```

Há dois profiles configurados em `.databrickscfg`: `DEFAULT` e `mecamecanica` — sempre passe `--profile <nome>` explicitamente.

## Armadilhas conhecidas

- **Não usar `mode: development`** no target `dev`: prefixa nomes de recursos (inclusive schemas do Unity Catalog) com `[dev usuario]`, quebrando qualquer SQL que referencie schemas por nome fixo. Agendamentos são pausados explicitamente via `presets.trigger_pause_status: PAUSED`.
- **Default Storage habilitado** (comum em contas gratuitas/trial): a API do Unity Catalog recusa criar catálogo via bundle (exige managed location). Nesse caso, o catálogo é criado via SQL fora do bundle antes do deploy (`scripts/criar-catalogo.sh`).
