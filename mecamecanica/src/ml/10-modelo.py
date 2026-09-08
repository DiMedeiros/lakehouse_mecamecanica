# Databricks notebook source
# MAGIC %md
# MAGIC # ML · modelo de propensão de compra
# MAGIC
# MAGIC Treina em `gold.features_treino`, mede num holdout que o modelo nunca viu, e
# MAGIC só então pontua `gold.features_cliente` para a semana. Cada treino grava uma
# MAGIC linha nova em `gold.modelo_metricas` (nunca sobrescreve) e registra uma nova
# MAGIC versão do modelo no Unity Catalog — é assim que dá para responder "esse
# MAGIC treino ficou melhor ou pior que o anterior" sem abrir o MLflow.
# MAGIC
# MAGIC Restrições do Free Edition serverless, medidas contra o workspace:
# MAGIC - `HistGradientBoostingClassifier`, não XGBoost — XGBoost registra mas não
# MAGIC   recarrega aqui (`__sklearn_tags__`, conflito de versão do scikit-learn).
# MAGIC - Sem endpoint de modelo próprio: o consumo é batch, com
# MAGIC   `mlflow.sklearn.load_model` + pandas (`pyfunc.spark_udf` não roda no
# MAGIC   serverless).
# MAGIC - `predict_proba()`, não `predict()` — este último devolve a classe, não o
# MAGIC   score.

# COMMAND ----------

dbutils.widgets.text("catalog", "lakehouse_mecamecanica")
catalog = dbutils.widgets.get("catalog")

JANELA_DIAS = 7
SEED = 42

import mlflow
import mlflow.sklearn
import numpy as np
import pandas as pd
from databricks.sdk import WorkspaceClient
from pyspark.sql import functions as F, Window
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.inspection import permutation_importance
from sklearn.metrics import roc_auc_score
from sklearn.model_selection import train_test_split

mlflow.set_tracking_uri("databricks")
mlflow.set_registry_uri("databricks-uc")

# COMMAND ----------

FEATURES = [
    "recencia_dias", "frequencia_pedidos", "valor_total", "margem_total",
    "ticket_medio", "margem_percentual",
    "intervalo_medio_dias", "desvio_intervalo_dias", "pedidos_ultimos_90d",
    "oportunidades_abertas", "oportunidades_ganhas", "taxa_ganho",
    "visitas_90d", "conversao_visita",
    "skus_distintos", "categorias_distintas", "marcas_distintas",
    "concentracao_marca_top", "comprou_lancamento", "atraso_relativo",
]

treino_pd = spark.table(f"{catalog}.gold.features_treino").toPandas()
X_treino, X_holdout, y_treino, y_holdout = train_test_split(
    treino_pd[FEATURES], treino_pd["comprou_em_7d"],
    test_size=0.25, random_state=SEED, stratify=treino_pd["comprou_em_7d"],
)

# COMMAND ----------

# MAGIC %md
# MAGIC ## Treino e avaliação contra três regras simples
# MAGIC
# MAGIC AUC sozinho não convence ninguém do comercial. `lift_top200` sim: quantas
# MAGIC vezes mais acerto o modelo dá nos 200 primeiros da fila, comparado com
# MAGIC ligar às cegas (a `taxa_base`). As três regras — ordenar por recência, por
# MAGIC valor histórico, por atraso relativo — são o que a empresa faria sem
# MAGIC modelo nenhum: se o modelo não bater a melhor delas, ele não paga o
# MAGIC trabalho de manter.

# COMMAND ----------

modelo = HistGradientBoostingClassifier(random_state=SEED)
modelo.fit(X_treino, y_treino)

score_holdout = modelo.predict_proba(X_holdout)[:, 1]
auc = float(roc_auc_score(y_holdout, score_holdout))

# baseline: cada regra usada como score, sem inverter sinal — recência "crua"
# prevê mal de propósito (comprou há pouco != vai comprar essa semana), e é
# isso que o número tem que mostrar.
baseline_recencia = float(roc_auc_score(y_holdout, X_holdout["recencia_dias"]))
baseline_valor_total = float(roc_auc_score(y_holdout, X_holdout["valor_total"]))
baseline_atraso = float(roc_auc_score(y_holdout, X_holdout["atraso_relativo"]))

taxa_base = float(treino_pd["comprou_em_7d"].mean())

top200 = (
    pd.DataFrame({"y": y_holdout.to_numpy(), "score": score_holdout})
    .sort_values("score", ascending=False)
    .head(200)
)
acertos_top200 = int(top200["y"].sum())
lift_top200 = acertos_top200 / (200 * taxa_base)

importancia = permutation_importance(
    modelo, X_holdout, y_holdout, n_repeats=10, random_state=SEED, scoring="roc_auc"
)
feature_mais_importante = FEATURES[int(np.argmax(importancia.importances_mean))]

print(f"AUC holdout: {auc:.4f} | lift_top200: {lift_top200:.2f} | "
      f"baselines: recencia={baseline_recencia:.3f} valor_total={baseline_valor_total:.3f} "
      f"atraso_relativo={baseline_atraso:.3f} | feature top: {feature_mais_importante}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Registro no MLflow/Unity Catalog
# MAGIC
# MAGIC `mlflow.set_experiment` não cria a pasta pai — sem o `mkdirs` antes, quebra
# MAGIC com `BAD_REQUEST: For input string: "None"`. E este workspace traz MLflow
# MAGIC 2.22: `log_model(..., artifact_path=...)`, nunca o `name=` do MLflow 3.

# COMMAND ----------

usuario = spark.sql("SELECT current_user()").collect()[0][0]
experimento = f"/Users/{usuario}/mecamecanica_propensao_compra"

WorkspaceClient().workspace.mkdirs(f"/Users/{usuario}")
mlflow.set_experiment(experimento)

model_name = f"{catalog}.gold.propensao_compra"

with mlflow.start_run(run_name=f"propensao_compra_{pd.Timestamp.utcnow():%Y%m%d_%H%M%S}") as run:
    mlflow.log_param("modelo", "HistGradientBoostingClassifier")
    mlflow.log_param("random_state", SEED)
    mlflow.log_param("janela_dias", JANELA_DIAS)
    mlflow.log_metric("auc_holdout", auc)
    mlflow.log_metric("lift_top200", lift_top200)
    mlflow.log_metric("baseline_recencia", baseline_recencia)
    mlflow.log_metric("baseline_valor_total", baseline_valor_total)
    mlflow.log_metric("baseline_atraso", baseline_atraso)

    mlflow.sklearn.log_model(
        modelo,
        artifact_path="modelo",
        registered_model_name=model_name,
        input_example=X_treino.head(5),
    )

versoes = mlflow.MlflowClient().search_model_versions(f"name='{model_name}'")
versao_uc = max(int(v.version) for v in versoes)

# COMMAND ----------

# MAGIC %md
# MAGIC ## Score de todos os clientes elegíveis e faixas em quartis
# MAGIC
# MAGIC `predict_proba()`, nunca `predict()`: a fila ordena por probabilidade
# MAGIC contínua, não por classe 0/1.

# COMMAND ----------

cliente_pd = spark.table(f"{catalog}.gold.features_cliente").toPandas()
score_cliente = modelo.predict_proba(cliente_pd[FEATURES])[:, 1]

referencia = cliente_pd["_referencia"].iloc[0]

versao = 1
if spark.catalog.tableExists(f"{catalog}.gold.modelo_metricas"):
    ultima = spark.sql(f"SELECT COALESCE(MAX(versao), 0) AS v FROM {catalog}.gold.modelo_metricas").collect()[0]["v"]
    versao = int(ultima) + 1

score_propensao = spark.createDataFrame(
    pd.DataFrame({
        "cliente_id": cliente_pd["cliente_id"].astype(int),
        "score": score_cliente,
        "_referencia": referencia,
        "versao": versao,
    })
).withColumn(
    # NTILE(4) por score: quartil 1 = menor score (Fria) .. quartil 4 = maior (Muito quente)
    "faixa",
    F.element_at(
        F.array(F.lit("Fria"), F.lit("Morna"), F.lit("Quente"), F.lit("Muito quente")),
        F.ntile(4).over(Window.orderBy("score")),
    ),
)

(score_propensao.write.mode("append").saveAsTable(f"{catalog}.gold.score_propensao"))

# COMMAND ----------

# MAGIC %md
# MAGIC ## Calibragem no holdout — a prova de que o score ordena
# MAGIC
# MAGIC Taxa de compra crescente de Fria para Muito quente, medida em clientes que
# MAGIC o modelo NÃO viu no treino. Não precisa saber o que é curva ROC para ler
# MAGIC esta tabela.

# COMMAND ----------

holdout_pd = pd.DataFrame({"y": y_holdout.to_numpy(), "score": score_holdout})
holdout_sdf = spark.createDataFrame(holdout_pd).withColumn(
    "faixa",
    F.element_at(
        F.array(F.lit("Fria"), F.lit("Morna"), F.lit("Quente"), F.lit("Muito quente")),
        F.ntile(4).over(Window.orderBy("score")),
    ),
)

calibragem = holdout_sdf.groupBy("faixa").agg(
    F.count("*").alias("clientes"),
    F.sum("y").alias("compraram"),
    (F.sum("y") / F.count("*")).alias("taxa_de_compra"),
    F.avg("score").alias("score_medio"),
)

(calibragem.write.mode("overwrite").option("overwriteSchema", "true")
           .saveAsTable(f"{catalog}.gold.calibragem_holdout"))

# COMMAND ----------

# MAGIC %md
# MAGIC ## Histórico de métricas — uma linha por treino, nunca sobrescrita

# COMMAND ----------

metricas = spark.createDataFrame([{
    "versao": versao,
    "auc": auc,
    "lift_top200": float(lift_top200),
    "acertos_top200": acertos_top200,
    "taxa_base": taxa_base,
    "baseline_recencia": baseline_recencia,
    "baseline_valor_total": baseline_valor_total,
    "baseline_atraso": baseline_atraso,
    "feature_mais_importante": feature_mais_importante,
}]).withColumn("_treinado_em", F.current_timestamp())

(metricas.write.mode("append").saveAsTable(f"{catalog}.gold.modelo_metricas"))

# saveAsTable não grava COMMENT de tabela, e só precisa rodar uma vez
if versao == 1:
    spark.sql(f"""
    COMMENT ON TABLE {catalog}.gold.modelo_metricas IS
    'Uma linha por treino: AUC, lift_top200, acertos entre os 200 primeiros, taxa
     base e o AUC de cada regra simples. É o histórico que responde "o modelo está
     melhor ou pior que o treino anterior" sem abrir o MLflow.'
    """)
    spark.sql(f"""
    COMMENT ON TABLE {catalog}.gold.score_propensao IS
    'Propensão de compra na semana seguinte, por cliente, com a faixa em quartis e
     a versão do modelo que gerou a nota. É desta tabela que sai a fila do dia.'
    """)
    spark.sql(f"""
    COMMENT ON TABLE {catalog}.gold.calibragem_holdout IS
    'Taxa de compra por faixa de score, medida nos clientes que o modelo NÃO viu no
     treino. Se a taxa sobe de Fria para Muito quente, o score ordena — e isso se
     confere sem saber o que é curva ROC.'
    """)

print(f"versão {versao} · modelo UC v{versao_uc} · AUC {auc:.4f} · lift_top200 {lift_top200:.2f} "
      f"· feature top: {feature_mais_importante}")
