# Databricks notebook source
# MAGIC %md
# MAGIC # ML · o modelo
# MAGIC
# MAGIC A ordem deste notebook é a ordem que importa, e ela começa antes do
# MAGIC `.fit()`:
# MAGIC
# MAGIC 1. **o baseline** — quanto valem as regras que a empresa já usa de graça
# MAGIC 2. o treino, que são três linhas
# MAGIC 3. as duas métricas: `auc` para quem treina, `lift_top200` para a reunião
# MAGIC 4. o MLflow e o Unity Catalog
# MAGIC 5. **três testes que interrompem a tarefa**
# MAGIC 6. o score, que é o que a fila semanal consome
# MAGIC
# MAGIC Sem o passo 1, "AUC 0,85" não quer dizer nada. Com ele, vira "ganha da
# MAGIC melhor regra simples por tanto" — que é uma frase que se leva para uma
# MAGIC reunião.

# COMMAND ----------

dbutils.widgets.text("catalog", "lakehouse_mecamecanica")
catalog = dbutils.widgets.get("catalog")

MODELO = f"{catalog}.gold.propensao_compra"
ALVO = "comprou_em_7d"
SEMENTE = 42

# Quantas ligações o time faz por semana. É o tamanho da fila, e é o que torna
# lift_top200 a métrica desta operação e não de outra.
TOP_N = 200

import mlflow
import numpy as np
import pandas as pd
from databricks.sdk import WorkspaceClient
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.inspection import permutation_importance
from sklearn.metrics import roc_auc_score
from sklearn.model_selection import StratifiedKFold, train_test_split

mlflow.set_registry_uri("databricks-uc")

dados = spark.table(f"{catalog}.gold.features_treino").toPandas()
FEATURES = [c for c in dados.columns if c not in ("cliente_id", ALVO, "_referencia")]

X = dados[FEATURES].astype(float)
y = dados[ALVO].astype(int)

X_tr, X_te, y_tr, y_te = train_test_split(
    X, y, test_size=0.25, stratify=y, random_state=SEMENTE
)

taxa_base = float(y.mean())
print(f"{len(dados)} clientes × {len(FEATURES)} features")
print(f"taxa base: {100 * taxa_base:.2f}%  —  de {TOP_N} ligações às cegas, "
      f"{round(TOP_N * taxa_base)} viram pedido")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1 · O baseline, antes de treinar qualquer coisa
# MAGIC
# MAGIC As três regras que qualquer gerente comercial defenderia numa reunião,
# MAGIC medidas na mesma régua. É o momento que não precisa de modelo nenhum para
# MAGIC acontecer — e é a régua do teste 1.

# COMMAND ----------


def auc_da_regra(coluna, sinal=1):
    """AUC usando uma coluna crua como se fosse o score."""
    # roc_auc_score não aceita NaN, e atraso_relativo é nulo de propósito para
    # quem tem um pedido só. Preencher com a mediana mantém a comparação justa.
    valores = X_te[coluna].fillna(X_te[coluna].median())
    return roc_auc_score(y_te, sinal * valores)


baselines = {
    "ligue para quem comprou recentemente": auc_da_regra("recencia_dias", -1),
    "jogar uma moeda": 0.5,
    "ligue para quem compra mais": auc_da_regra("valor_total"),
    "ligue para quem está atrasado": auc_da_regra("atraso_relativo"),
}

print("A intuição comercial, na régua do AUC\n")
for regra, valor in sorted(baselines.items(), key=lambda kv: kv[1]):
    marca = "  ← pior que a moeda" if valor < 0.5 else ""
    print(f"  {valor:.4f}   {regra}{marca}")

# a régua do teste 1: o modelo tem que ganhar da MELHOR delas.
melhor_baseline = max(v for k, v in baselines.items() if k != "jogar uma moeda")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 2 · O treino — a parte que todo mundo acha que é o trabalho
# MAGIC
# MAGIC `HistGradientBoostingClassifier`, e não XGBoost: no serverless o XGBoost
# MAGIC treina, registra e **falha ao carregar de volta** (`__sklearn_tags__`,
# MAGIC conflito com scikit-learn 1.6.1). O pior tipo de erro — aparece uma
# MAGIC tarefa depois.
# MAGIC
# MAGIC Nada de imputar nulo: esta árvore trata `NaN` nativamente, e as features
# MAGIC de ritmo são nulas de propósito para quem comprou uma vez só.

# COMMAND ----------

modelo = HistGradientBoostingClassifier(random_state=SEMENTE)
modelo.fit(X_tr, y_tr)

auc = float(roc_auc_score(y_te, modelo.predict_proba(X_te)[:, 1]))
print(f"AUC do modelo: {auc:.4f}   (melhor baseline: {melhor_baseline:.4f})")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 3 · `lift_top200` — a métrica que responde o diretor
# MAGIC
# MAGIC AUC é métrica de quem treina. A pergunta que paga o projeto é *"dos 200
# MAGIC que eu ligar, quantos compram?"*.
# MAGIC
# MAGIC O score sai por **validação cruzada out-of-fold** sobre a base inteira, e
# MAGIC não só no holdout: a fila real são 200 entre milhares. No holdout de 25%,
# MAGIC os 200 primeiros seriam uma fatia grande demais da amostra e o número
# MAGIC sairia otimista.

# COMMAND ----------

oof = np.zeros(len(y), dtype=float)
for treino_idx, teste_idx in StratifiedKFold(5, shuffle=True, random_state=SEMENTE).split(X, y):
    m = HistGradientBoostingClassifier(random_state=SEMENTE)
    m.fit(X.iloc[treino_idx], y.iloc[treino_idx])
    oof[teste_idx] = m.predict_proba(X.iloc[teste_idx])[:, 1]

topo = np.argsort(-oof)[:TOP_N]
acertos_top200 = int(y.iloc[topo].sum())
lift_top200 = float(y.iloc[topo].mean() / taxa_base)

print(f"Dos {TOP_N} de maior score, {acertos_top200} compraram na semana seguinte.")
print(f"Às cegas seriam {round(TOP_N * taxa_base)}.  Lift: {lift_top200:.2f}×")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 4 · O que o modelo realmente olhou
# MAGIC
# MAGIC Importância por **permutação**, medida no holdout: embaralha uma coluna
# MAGIC por vez e mede quanto o AUC piora. É medida, não é o
# MAGIC `feature_importances_` que a biblioteca chuta.

# COMMAND ----------

perm = permutation_importance(
    modelo, X_te, y_te, scoring="roc_auc", n_repeats=5, random_state=SEMENTE
)
importancia = (pd.DataFrame({"feature": FEATURES, "peso": perm.importances_mean})
                 .sort_values("peso", ascending=False)
                 .reset_index(drop=True))
print(importancia.head(10).to_string(index=False))

feature_top = importancia.iloc[0]["feature"]

# COMMAND ----------

# MAGIC %md
# MAGIC ## 5 · MLflow e Unity Catalog — o modelo vira objeto de catálogo
# MAGIC
# MAGIC `set_experiment` **não cria a pasta pai**, e o erro não menciona pasta
# MAGIC nenhuma: `BAD_REQUEST: For input string: "None"`. Por isso o `mkdirs`
# MAGIC vem antes.
# MAGIC
# MAGIC O serverless traz **MLflow 2.22**: é `log_model(..., artifact_path=...)`,
# MAGIC nunca o `name=` do MLflow 3.

# COMMAND ----------

usuario = WorkspaceClient().current_user.me().user_name
PASTA = f"/Users/{usuario}/mecamecanica"
WorkspaceClient().workspace.mkdirs(PASTA)

mlflow.set_experiment(f"{PASTA}/propensao_compra")

# tabelas de metadado só ganham COMMENT na primeira execução — saveAsTable não
# grava comment de tabela, e não faz sentido repetir o COMMENT ON a cada dia
primeira_execucao = not spark.catalog.tableExists(f"{catalog}.gold.modelo_metricas")

with mlflow.start_run(run_name="propensao_compra") as run:
    mlflow.log_params({
        "algoritmo": "HistGradientBoostingClassifier",
        "random_state": SEMENTE,
        "corte_treino": str(dados["_referencia"].iloc[0]),
        "janela_dias": 7,
        "features": len(FEATURES),
        "linhas_treino": len(X_tr),
    })
    mlflow.log_metrics({
        "auc": auc,
        "lift_top200": lift_top200,
        "acertos_top200": acertos_top200,
        "taxa_base": taxa_base,
        "baseline_recencia": baselines["ligue para quem comprou recentemente"],
        "baseline_valor_total": baselines["ligue para quem compra mais"],
        "baseline_atraso": baselines["ligue para quem está atrasado"],
    })
    info = mlflow.sklearn.log_model(
        modelo, artifact_path="modelo", registered_model_name=MODELO,
        input_example=X_tr.head(3),
    )

versao = int(info.registered_model_version)
mlflow.MlflowClient().set_registered_model_alias(MODELO, "prod", versao)
print(f"{MODELO} versão {versao} registrada, com o alias @prod")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 6 · Os três testes que interrompem a tarefa
# MAGIC
# MAGIC Um dado errado quebra. Um modelo ruim **funciona** — devolve nota para
# MAGIC todo mundo, na faixa certa, sem erro nenhum. Por isso ele entra nos
# MAGIC mesmos testes que o dado.

# COMMAND ----------

assert auc > melhor_baseline + 0.05, (
    f"o modelo ({auc:.4f}) não ganha da melhor regra simples ({melhor_baseline:.4f}) "
    "por uma margem que justifique existir. Sem isso, o projeto não se paga."
)
assert auc < 0.99, (
    f"AUC de {auc:.4f} é bom DEMAIS. Em propensão de compra isso não é "
    "competência, é vazamento: alguma feature enxergou o que houve depois do corte."
)
assert lift_top200 >= 2.5, (
    f"lift de {lift_top200:.2f}× é baixo demais para justificar a fila. "
    "O vendedor faria quase o mesmo ligando no chute."
)
print("os três testes passaram")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 7 · O score — todos os clientes elegíveis, com nota
# MAGIC
# MAGIC `mlflow.pyfunc.spark_udf` **não roda no serverless**
# MAGIC (`InvalidVersion: '18.x-aarch64-photon-scala2'`) e é o caminho que toda a
# MAGIC documentação recomenda. A saída é `load_model` + pandas — e para poucos
# MAGIC milhares de clientes isso é a escolha certa de qualquer forma.
# MAGIC
# MAGIC Recarregar pelo alias `@prod` (em vez de reusar o `modelo` em memória)
# MAGIC prova que o alias funciona e garante que quem pontua é sempre a versão em
# MAGIC produção. E é `predict_proba`, nunca `predict`: `predict` devolve a
# MAGIC **classe**, e a coluna inteira viraria zero e um.

# COMMAND ----------

carregado = mlflow.sklearn.load_model(f"models:/{MODELO}@prod")

atual = spark.table(f"{catalog}.gold.features_cliente").toPandas()
# as colunas do treino, na ordem do treino — não confiar na ordem da tabela
X_atual = atual[list(carregado.feature_names_in_)].astype(float)

score = pd.DataFrame({
    "cliente_id": atual["cliente_id"].astype("int32"),
    "score": carregado.predict_proba(X_atual)[:, 1],
    "_referencia": atual["_referencia"],
})
score["faixa"] = pd.qcut(
    score["score"].rank(method="first"), 4,
    labels=["Fria", "Morna", "Quente", "Muito quente"],
).astype(str)
score["versao"] = versao

# é uma foto da semana, não um histórico — overwrite, nunca append
(spark.createDataFrame(score)
      .write.mode("overwrite").option("overwriteSchema", "true")
      .saveAsTable(f"{catalog}.gold.score_propensao"))

if primeira_execucao:
    spark.sql(f"""
    COMMENT ON TABLE {catalog}.gold.score_propensao IS
    'Propensão de compra na semana seguinte, por cliente, com a faixa em quartis e
     a versão do modelo que gerou a nota. É desta tabela que sai a fila do dia.'
    """)

print(f"score_propensao: {len(score)} clientes · "
      f"{(score.faixa == 'Muito quente').sum()} muito quentes")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 8 · As métricas também viram tabela
# MAGIC
# MAGIC O Genie não lê MLflow, e daqui a seis meses ninguém abre a interface de
# MAGIC experimento. O que precisa ser consultável tem que estar na gold.

# COMMAND ----------

from pyspark.sql import functions as F

metricas = (spark.createDataFrame(pd.DataFrame([{
        "versao": versao,
        "auc": auc,
        "lift_top200": lift_top200,
        "acertos_top200": acertos_top200,
        "taxa_base": taxa_base,
        "baseline_recencia": baselines["ligue para quem comprou recentemente"],
        "baseline_valor_total": baselines["ligue para quem compra mais"],
        "baseline_atraso": baselines["ligue para quem está atrasado"],
        "feature_mais_importante": feature_top,
    }]))
    .withColumn("_treinado_em", F.current_timestamp()))

(metricas.write.mode("append").option("mergeSchema", "true")
         .saveAsTable(f"{catalog}.gold.modelo_metricas"))

if primeira_execucao:
    spark.sql(f"""
    COMMENT ON TABLE {catalog}.gold.modelo_metricas IS
    'Uma linha por treino: AUC, lift_top200, acertos entre os 200 primeiros, taxa
     base e o AUC de cada regra simples. É o histórico que responde "o modelo está
     melhor ou pior que o treino anterior" sem abrir o MLflow.'
    """)

# a calibragem sai do HOLDOUT, que tem o rótulo — é a prova que o comercial
# confere sozinho, sem ouvir a palavra AUC uma única vez
holdout = pd.DataFrame({"score": modelo.predict_proba(X_te)[:, 1], "comprou": y_te.values})
holdout["faixa"] = pd.qcut(
    holdout["score"].rank(method="first"), 4,
    labels=["Fria", "Morna", "Quente", "Muito quente"],
).astype(str)

calibragem = (holdout.groupby("faixa", as_index=False)
              .agg(clientes=("comprou", "size"),
                   compraram=("comprou", "sum"),
                   taxa_de_compra=("comprou", "mean"),
                   score_medio=("score", "mean")))

(spark.createDataFrame(calibragem)
      .write.mode("overwrite").option("overwriteSchema", "true")
      .saveAsTable(f"{catalog}.gold.calibragem_holdout"))

if primeira_execucao:
    spark.sql(f"""
    COMMENT ON TABLE {catalog}.gold.calibragem_holdout IS
    'Taxa de compra por faixa de score, medida nos clientes que o modelo NÃO viu no
     treino. Se a taxa sobe de Fria para Muito quente, o score ordena — e isso se
     confere sem saber o que é curva ROC.'
    """)

print(calibragem.to_string(index=False))
