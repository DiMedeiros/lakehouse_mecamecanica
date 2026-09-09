# Prompt 7 · O modelo e o MLflow

**Entrega:** o modelo registrado no Unity Catalog e `gold.score_propensao`
— os clientes com nota. **Deploy nº 7.**

> Segure o baseline até aqui. Ele é a única coisa da aula que a sala não
> espera.

---

## Contexto desta entrega

Segunda entrega da trilha de ciência de dados. Igual à anterior, o
notebook original foi perdido no incidente do antivírus. A primeira
reconstrução (de boa-fé, sem o roteiro original em mãos) tinha **bugs
reais** que só foram encontrados numa sessão seguinte, ao localizar e ler
`prompt-02-modelo.md` linha a linha:

1. `gold.score_propensao` gravava com `.mode("append")` em vez de
   `overwrite` — viraria histórico acumulado em vez de foto da semana.
2. Baseline de `recencia_dias` sem inverter o sinal, e sem preencher `NaN`
   de `atraso_relativo` antes do `roc_auc_score` (quebraria com exceção na
   primeira execução real).
3. `lift_top200`/`acertos_top200` calculados só no holdout (~700 linhas,
   28% da amostra) em vez de out-of-fold sobre a base inteira — metodologia
   errada, número otimista.
4. Faltavam os três testes de guarda (`assert`).
5. O alias `@prod` do modelo nunca era atualizado.

Todos corrigidos e **validados rodando contra o workspace real**: os três
testes passaram, e as métricas resultantes bateram **exatamente** com o
histórico já registrado (`auc=0.8497875`, `lift_top200=4.1978`,
`acertos_top200=85`) — confirmando que a correção reproduz a metodologia
original.

## O prompt

```
Crie src/ml/10-modelo.py. Nesta ordem:

1. BASELINE, antes de treinar qualquer coisa. Separe 25% de
   gold.features_treino como holdout (random_state=42, estratificado). No
   holdout, calcule roc_auc_score do alvo contra cada regra simples:
     a) -recencia_dias      ("ligue para quem comprou recentemente")
     b)  valor_total        ("ligue para quem compra mais")
     c)  atraso_relativo    ("ligue para quem está atrasado")
   Preencha NaN com a mediana antes do roc_auc_score. Guarde o melhor: é a
   régua do teste 1.

2. TREINO. HistGradientBoostingClassifier do scikit-learn, random_state=42.
   NÃO impute NULL (a árvore trata NaN nativamente). NÃO use XGBoost (falha
   ao carregar de volta no serverless, conflito com scikit-learn 1.6.1).

3. AS DUAS MÉTRICAS.
   auc          — no holdout
   lift_top200  — pontue TODOS os clientes de features_treino por validação
                  cruzada out-of-fold (StratifiedKFold 5 folds, shuffle,
                  random_state=42), ordene por score, pegue os 200
                  primeiros e divida a taxa de compra deles pela taxa base.

4. IMPORTÂNCIA POR PERMUTAÇÃO, no holdout, n_repeats=5.

5. MLFLOW. Crie a pasta pai com WorkspaceClient().workspace.mkdirs(...)
   antes de mlflow.set_experiment. MLflow 2.22: log_model(...,
   artifact_path="modelo"), nunca name=. Registre em
   lakehouse_mecamecanica.gold.propensao_compra e aponte o alias @prod para
   a versão recém-criada (mlflow.MlflowClient().set_registered_model_alias).

6. TRÊS TESTES QUE INTERROMPEM A TAREFA:
   - auc > melhor_baseline + 0.05
   - auc < 0.99 (bom demais é vazamento)
   - lift_top200 >= 2.5

7. SCORE. Carregue com mlflow.sklearn.load_model("models:/...@prod") e use
   predict_proba (NÃO pyfunc.predict, que devolve a classe). NÃO use
   mlflow.pyfunc.spark_udf (não roda no serverless). Pontue com as colunas
   de carregado.feature_names_in_, não confiando na ordem da tabela.
   Grave gold.score_propensao com OVERWRITE (é uma foto da semana, não
   histórico): cliente_id, score, faixa (NTILE(4)/qcut sobre o score:
   Fria, Morna, Quente, Muito quente), _referencia, versao (a que veio do
   registro no UC).

8. AS MÉTRICAS TAMBÉM VIRAM TABELA:
   gold.modelo_metricas     uma linha por treino (append), nunca sobrescrita
   gold.calibragem_holdout  faixa, clientes, compraram, taxa_de_compra,
                            score_medio, calculados no holdout

COMMENT em português nas três tabelas que este prompt cria.
```

## Como verificar a feature

```sql
SELECT faixa, clientes, compraram, ROUND(taxa_de_compra,4) taxa_de_compra
FROM lakehouse_mecamecanica.gold.calibragem_holdout
ORDER BY score_medio;
```

Taxa de compra sobe monotonicamente: **Fria 0% → Morna 1,7% → Quente 10,8%
→ Muito quente 27,8%**. O score ordena.

```sql
SELECT versao, auc, lift_top200, acertos_top200, taxa_base
FROM lakehouse_mecamecanica.gold.modelo_metricas
ORDER BY _treinado_em DESC LIMIT 1;
```

`auc=0,8498`, `lift_top200=4,20` (86 acertos esperados contra 20 às cegas),
`taxa_base≈10,1%`.

```bash
databricks model-versions get-by-alias \
  lakehouse_mecamecanica.gold.propensao_compra prod --profile <perfil>
```

Confirma que `@prod` aponta para a versão que acabou de ser registrada —
`list`/`get` não mostram o alias, só `get-by-alias` prova que ele está lá.
