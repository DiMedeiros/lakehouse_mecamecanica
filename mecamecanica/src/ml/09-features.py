# Databricks notebook source
# MAGIC %md
# MAGIC # ML · features
# MAGIC
# MAGIC `gold.fato_vendas` tem uma linha por item de pedido. Modelo não come tabela
# MAGIC fato: come uma linha por cliente, com tudo que se sabia dele até uma data.
# MAGIC
# MAGIC `montar_features(referencia)` é chamada duas vezes — para treino (com
# MAGIC rótulo) e para score (sem rótulo) — e por isso as duas nunca podem
# MAGIC divergir nas mesmas colunas (training/serving skew).
# MAGIC
# MAGIC `gold.dim_cliente` tem `dias_sem_comprar`, `receita_acumulada` e
# MAGIC `total_pedidos`, mas nenhuma entra aqui: são calculadas sobre a base
# MAGIC inteira, sem corte, e usá-las é vazamento — o modelo veria o futuro sem dar
# MAGIC erro nenhum, só um AUC alto demais.

# COMMAND ----------

dbutils.widgets.text("catalog", "lakehouse_mecamecanica")
catalog = dbutils.widgets.get("catalog")

# O "hoje" deste dataset é 2026-08-31 (fixo, sem current_date()): a janela do
# rótulo é de 7 dias porque a fila de ligação é semanal — o rótulo tem que ter
# o mesmo horizonte da decisão.
CORTE_TREINO = "2026-08-01"
FIM_DA_BASE = "2026-08-31"
JANELA_DIAS = 7

from pyspark.sql import functions as F, Window

# COMMAND ----------


def montar_features(referencia):
    """Uma linha por cliente, com tudo que se sabia dele ATÉ `referencia`."""

    # cada fonte é filtrada pela data dela na primeira linha da leitura —
    # é isso que garante que nenhuma feature "veja" o futuro
    fato = (spark.table(f"{catalog}.gold.fato_vendas")
                 .filter(F.col("data_pedido") < F.lit(referencia)))

    oport = (spark.table(f"{catalog}.silver.oportunidades")
                  .filter(F.col("data_abertura") < F.lit(referencia)))

    visitas = (spark.table(f"{catalog}.silver.visitas")
                    .filter(F.col("data_visita") < F.lit(referencia)))

    ref = F.lit(referencia).cast("date")

    # ── RFM ───────────────────────────────────────────────────────────
    # devolução já entra negativa em receita/margem (gold.fato_vendas), então
    # SUM() aqui já é líquido
    rfm = fato.groupBy("cliente_id").agg(
        F.datediff(ref, F.max("data_pedido")).cast("double").alias("recencia_dias"),
        F.countDistinct("pedido_id").cast("double").alias("frequencia_pedidos"),
        F.sum("receita").cast("double").alias("valor_total"),
        F.sum("margem").cast("double").alias("margem_total"),
    ).withColumn(
        "ticket_medio",
        (F.col("valor_total") / F.nullif(F.col("frequencia_pedidos"), F.lit(0))).cast("double")
    ).withColumn(
        "margem_percentual",
        (F.col("margem_total") / F.nullif(F.col("valor_total"), F.lit(0))).cast("double")
    )

    # ── ritmo ─────────────────────────────────────────────────────────
    # o intervalo entre pedidos é o que separa "sumiu há 28 dias, atrasado"
    # de "sumiu há 28 dias, mas só compra a cada 139" — a mesma recência
    # significa coisas opostas para clientes diferentes
    datas = fato.select("cliente_id", "data_pedido").distinct()
    janela = Window.partitionBy("cliente_id").orderBy("data_pedido")
    gaps = (datas
            .withColumn("_anterior", F.lag("data_pedido").over(janela))
            .filter(F.col("_anterior").isNotNull())
            .withColumn("_gap", F.datediff("data_pedido", "_anterior").cast("double")))

    ritmo = gaps.groupBy("cliente_id").agg(
        F.avg("_gap").cast("double").alias("intervalo_medio_dias"),
        F.stddev("_gap").cast("double").alias("desvio_intervalo_dias"),
    )

    recentes = (fato
        .filter(F.col("data_pedido") >= F.date_sub(ref, 90))
        .groupBy("cliente_id")
        .agg(F.countDistinct("pedido_id").cast("double").alias("pedidos_ultimos_90d")))

    # ── CRM ───────────────────────────────────────────────────────────
    crm_op = oport.groupBy("cliente_id").agg(
        F.sum(F.when(~F.col("ganha") & ~F.col("perdida"), 1).otherwise(0))
         .cast("double").alias("oportunidades_abertas"),
        F.sum(F.col("ganha").cast("int")).cast("double").alias("oportunidades_ganhas"),
        F.count("*").cast("double").alias("_oportunidades"),
    ).withColumn(
        "taxa_ganho",
        (F.col("oportunidades_ganhas") / F.nullif(F.col("_oportunidades"), F.lit(0))).cast("double")
    ).drop("_oportunidades")

    # silver.visitas não tem uma coluna booleana de conversão — o resultado
    # da visita é categórico, e 'Pedido realizado' é o valor que sinaliza venda
    crm_vis = (visitas
        .filter(F.col("data_visita") >= F.date_sub(ref, 90))
        .withColumn("_gerou_pedido", (F.col("resultado") == "Pedido realizado").cast("int"))
        .groupBy("cliente_id")
        .agg(F.count("*").cast("double").alias("visitas_90d"),
             F.sum("_gerou_pedido").cast("double").alias("_com_pedido"))
        .withColumn("conversao_visita",
                    (F.col("_com_pedido") / F.nullif(F.col("visitas_90d"), F.lit(0))).cast("double"))
        .drop("_com_pedido"))

    # ── mix ───────────────────────────────────────────────────────────
    # categoria e marca já vêm desnormalizadas no fato — sem join
    mix = fato.groupBy("cliente_id").agg(
        F.countDistinct("sku").cast("double").alias("skus_distintos"),
        F.countDistinct("categoria").cast("double").alias("categorias_distintas"),
        F.countDistinct("marca").cast("double").alias("marcas_distintas"),
    )

    por_marca = fato.groupBy("cliente_id", "marca").agg(F.sum("receita").alias("_receita"))
    concentracao = (por_marca.groupBy("cliente_id")
        .agg(F.max("_receita").cast("double").alias("_top"),
             F.sum("_receita").cast("double").alias("_total"))
        .withColumn("concentracao_marca_top",
                    (F.col("_top") / F.nullif(F.col("_total"), F.lit(0))).cast("double"))
        .select("cliente_id", "concentracao_marca_top"))

    # único join necessário: data_lancamento não está no fato
    lancamentos = (spark.table(f"{catalog}.gold.dim_produto")
                        .filter(F.col("data_lancamento") >= F.date_sub(ref, 120))
                        .select("sku"))
    comprou_lanc = (fato.join(lancamentos, "sku")
                        .groupBy("cliente_id")
                        .agg(F.lit(1.0).alias("comprou_lancamento")))

    # ── uma linha por cliente ─────────────────────────────────────────
    df = rfm
    for parte in (ritmo, recentes, crm_op, crm_vis, mix, concentracao, comprou_lanc):
        df = df.join(parte, "cliente_id", "left")

    # cliente sem oportunidade/visita/lançamento recebe ZERO, não NULL — a
    # ausência é informação. Ritmo continua NULL para quem tem um pedido só:
    # aí não se sabe mesmo, e a árvore trata NaN nativamente.
    df = df.fillna(0.0, subset=[
        "oportunidades_abertas", "oportunidades_ganhas", "taxa_ganho",
        "visitas_90d", "conversao_visita", "pedidos_ultimos_90d",
        "comprou_lancamento",
    ])

    # atraso_relativo: recência dividida pelo intervalo médio DO PRÓPRIO
    # cliente, teto em 10. F.least() ignora nulo e devolve o outro valor — sem
    # o when() por fora, cliente de um pedido só (intervalo NULL) receberia o
    # teto e iria para o TOPO da fila.
    df = df.withColumn(
        "atraso_relativo",
        F.when(
            F.col("intervalo_medio_dias").isNotNull() & (F.col("intervalo_medio_dias") > 0),
            F.least(
                F.col("recencia_dias") / F.col("intervalo_medio_dias"),
                F.lit(10.0),
            ),
        ).cast("double"),
    )

    return df.withColumn("_referencia", ref)


# COMMAND ----------

# MAGIC %md
# MAGIC ## Treino: features de 01/08, rótulo da semana seguinte
# MAGIC
# MAGIC O rótulo olha para a frente a partir do corte; as features, só para trás.

# COMMAND ----------

fim_janela = F.date_add(F.lit(CORTE_TREINO).cast("date"), JANELA_DIAS - 1)

comprou = (spark.table(f"{catalog}.gold.fato_vendas")
    .filter((F.col("data_pedido") >= F.lit(CORTE_TREINO)) & (F.col("data_pedido") <= fim_janela))
    .select("cliente_id").distinct()
    .withColumn("comprou_em_7d", F.lit(1)))

treino = (montar_features(CORTE_TREINO)
          .join(comprou, "cliente_id", "left")
          .fillna(0, subset=["comprou_em_7d"]))

(treino.write.mode("overwrite").option("overwriteSchema", "true")
       .saveAsTable(f"{catalog}.gold.features_treino"))

# saveAsTable não grava COMMENT de tabela — precisa vir num COMMENT ON à parte
spark.sql(f"""
COMMENT ON TABLE {catalog}.gold.features_treino IS
'Uma linha por cliente com o comportamento dele ATÉ 2026-08-01, mais o rótulo
 comprou_em_7d (fez pedido entre 01/08 e 07/08). Tabela de treino do modelo de
 propensão de compra. Gerada por montar_features(), a mesma função que gera
 features_cliente.'
""")

print(f"features_treino: {treino.count()} clientes × {len(treino.columns)} colunas")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Score: as mesmas colunas, no fim da base, sem resposta

# COMMAND ----------

atual = montar_features(FIM_DA_BASE)

(atual.write.mode("overwrite").option("overwriteSchema", "true")
      .saveAsTable(f"{catalog}.gold.features_cliente"))

spark.sql(f"""
COMMENT ON TABLE {catalog}.gold.features_cliente IS
'Uma linha por cliente com o comportamento dele ATÉ 2026-08-31, sem rótulo. É a
 tabela que o modelo pontua para montar a fila da semana. Mesmas colunas de
 features_treino, geradas pela mesma função.'
""")

print(f"features_cliente: {atual.count()} clientes × {len(atual.columns)} colunas")

# COMMAND ----------

# MAGIC %md
# MAGIC ## A conferência que importa
# MAGIC
# MAGIC Recência negativa é a assinatura do vazamento: significa que a última
# MAGIC compra é posterior ao corte, ou seja, que uma fonte escapou do filtro.

# COMMAND ----------

conferencia = spark.sql(f"""
SELECT '_treino'  AS tabela, COUNT(*) AS clientes, MIN(_referencia) AS corte,
       MIN(recencia_dias) AS menor_recencia,
       ROUND(100 * AVG(comprou_em_7d), 2) AS taxa_base_pct
FROM {catalog}.gold.features_treino
UNION ALL
SELECT '_cliente', COUNT(*), MIN(_referencia), MIN(recencia_dias), NULL
FROM {catalog}.gold.features_cliente
""")
conferencia.show(truncate=False)

menor = treino.agg(F.min("recencia_dias")).collect()[0][0]
assert menor is not None and menor > 0, (
    f"recencia_dias mínima veio {menor}: alguma fonte escapou do filtro de data. "
    "Isto é vazamento, e o modelo treinado assim leria a resposta."
)
print("sem recência negativa — o corte foi respeitado em todas as fontes")
