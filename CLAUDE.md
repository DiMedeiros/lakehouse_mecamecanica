# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Antes de qualquer ação com Databricks

Leia a skill `databricks-core` antes de rodar CLI, escolher profile ou tocar em bundles. Ela cobre autenticação, seleção de profile e o fluxo de deploy — sem ela os resultados tendem a ser mais lentos e menos precisos.

Há dois profiles configurados em `.databrickscfg`: `DEFAULT` e `mecamecanica`. **Nunca selecione um profile automaticamente** — sempre passe `--profile <nome>` explicitamente e deixe o usuário escolher/confirmar qual usar.

## Estrutura do repositório

Este é um monorepo com dados brutos na raiz e o projeto Databricks em um subdiretório:

- **`dados/`** — os CSVs de origem (ERP e CRM) que simulam a extração dos sistemas legados. Não são gerados pelo pipeline; são o ponto de partida que sobe para o Volume `bronze.raw` no Unity Catalog.
  - `dados/erp/`: `produtos`, `pedidos`, `itens_pedido`, `pagamentos`, `estoque`
  - `dados/crm/`: `clientes`, `vendedores`, `carteira`, `oportunidades`, `visitas`
- **`mecamecanica/`** — o Databricks Asset Bundle (DAB) propriamente dito. Todo trabalho de engenharia (catálogo, schemas, volumes, jobs, pipelines, notebooks) acontece aqui. Veja `mecamecanica/AGENTS.md` (importado por `mecamecanica/CLAUDE.md`) para as instruções específicas do bundle.
- **`.llm/`** — material de referência/roteiro do curso (prompts didáticos descrevendo entregas planejadas). Trata-se de contexto de planejamento, não de código já implementado — confira o estado real dos arquivos antes de assumir que algo descrito ali já existe.

O bundle (`mecamecanica/`) está em estágio inicial de scaffold: `resources/` e `src/` ainda estão vazios (gerados pelo template `default-python`, ainda não populados).

## Comandos comuns (dentro de `mecamecanica/`)

```bash
uv sync --dev                                              # instalar dependências
uv run pytest                                              # rodar testes locais
databricks bundle validate --target dev --profile <nome>   # validar o bundle
databricks bundle deploy   --target dev --profile <nome>   # deploy (dev é o target default)
databricks bundle deploy   --target prod --profile <nome>  # deploy de produção
databricks bundle run <job_ou_pipeline> --target dev --profile <nome>
```

Para rodar um único teste: `uv run pytest tests/caminho_do_teste.py::test_nome`.

## Arquitetura de dados (camadas)

O projeto segue o padrão medalhão sobre Unity Catalog, com o catálogo `lakehouse_mecamecanica`:

- **Raw** (arquivo, não tabela): os CSVs sobem exatamente como vieram do ERP/CRM para o Volume gerenciado `bronze.raw` (via `databricks fs cp`, que exige o esquema `dbfs:` mesmo apontando para um Volume do UC).
- **bronze**: tabelas cruas + tabela de controle de conferência de chegada (garante que os 10 arquivos esperados chegaram e não vieram vazios — a ausência de um arquivo não gera erro visível, gera número menor no dashboard).
- **silver / gold**: camadas de transformação e consumo, construídas nos incrementos seguintes do bundle.

Schemas, volumes e o catálogo são definidos como código em `resources/*.yml` (incluído via `include:` em `databricks.yml`), não criados manualmente na UI — isso é o ponto central do projeto: infraestrutura de dados versionada e reproduzível via `bundle deploy`.

**Armadilha conhecida:** não usar `mode: development` no target `dev` do bundle — isso prefixa nomes de recursos (inclusive schemas do Unity Catalog) com `[dev usuario]`, quebrando qualquer SQL que referencie os schemas por nome fixo. Pausar agendamentos explicitamente via `presets: { trigger_pause_status: PAUSED }` em vez disso.

**Limitação de ambiente:** se o workspace usa Default Storage habilitado (comum em contas gratuitas/trial), a API do Unity Catalog recusa criar catálogo via bundle (exige managed location). Nesse caso, criar o catálogo via SQL fora do bundle antes do deploy.
