# Databricks notebook source
# MAGIC %md
# MAGIC # Ingestão bronze — dez tabelas, uma função
# MAGIC
# MAGIC Lê os 10 CSVs do Volume raw e grava cada um como tabela Delta em
# MAGIC `bronze`. Nenhuma limpeza, nenhuma conversão de tipo: tudo entra como
# MAGIC `STRING`, exatamente como o ERP/CRM mandou. Converter é trabalho da
# MAGIC silver, feito sabendo o que se faz.

# COMMAND ----------

from pyspark.sql import functions as F

dbutils.widgets.text("catalog", "lakehouse_mecamecanica")
catalog = dbutils.widgets.get("catalog")

TABELAS = {
    "erp": ["produtos", "pedidos", "itens_pedido", "pagamentos", "estoque"],
    "crm": ["clientes", "vendedores", "carteira", "oportunidades", "visitas"],
}

# COMMAND ----------


def ingerir(sistema: str, tabela: str) -> tuple[str, int]:
    caminho_raw = f"/Volumes/{catalog}/bronze/raw/{sistema}/{tabela}.csv"
    nome_tabela = f"`{catalog}`.bronze.{tabela}"

    df = (
        spark.read.format("csv")
        .option("header", "true")
        .option("inferSchema", "false")
        .load(caminho_raw)
    )
    if "_rescued_data" in df.columns:
        df = df.drop("_rescued_data")

    df = df.withColumn("_ingerido_em", F.current_timestamp()).withColumn(
        "_arquivo_origem", F.lit(f"{tabela}.csv")
    )

    df.write.format("delta").mode("overwrite").option("overwriteSchema", "true").saveAsTable(
        nome_tabela
    )
    spark.sql(
        f"COMMENT ON TABLE {nome_tabela} IS "
        f"'Ingestão bruta do sistema {sistema.upper()}, tabela {tabela}. "
        f"Colunas de negócio em STRING, sem limpeza ou conversão de tipo.'"
    )

    linhas_gravadas = spark.table(nome_tabela).count()
    return tabela, linhas_gravadas


# COMMAND ----------

gravadas = dict(
    ingerir(sistema, tabela) for sistema, tabelas in TABELAS.items() for tabela in tabelas
)

# COMMAND ----------

esperado_df = spark.sql(f"""
    SELECT arquivo, linhas
    FROM (
        SELECT arquivo, linhas,
               ROW_NUMBER() OVER (PARTITION BY arquivo ORDER BY conferido_em DESC) AS rn
        FROM `{catalog}`.bronze._raw_arquivos
    )
    WHERE rn = 1
""")
esperado = {row.arquivo.removesuffix(".csv"): row.linhas for row in esperado_df.collect()}

comparacao = spark.createDataFrame(
    [
        (tabela, gravadas[tabela], esperado.get(tabela), gravadas[tabela] == esperado.get(tabela))
        for tabela in gravadas
    ],
    ["tabela", "linhas_na_bronze", "linhas_esperadas", "bate"],
)
comparacao.orderBy("tabela").show(truncate=False)

divergentes = comparacao.filter(~F.col("bate")).collect()
if divergentes:
    detalhe = "\n".join(
        f"{r.tabela}: gravado={r.linhas_na_bronze} esperado={r.linhas_esperadas}"
        for r in divergentes
    )
    raise Exception(f"Contagem divergente entre bronze e _raw_arquivos:\n{detalhe}")
