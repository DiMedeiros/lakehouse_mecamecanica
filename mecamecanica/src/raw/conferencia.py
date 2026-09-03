# Databricks notebook source
# MAGIC %md
# MAGIC # Conferência de chegada — camada raw
# MAGIC
# MAGIC Confere que os 10 arquivos esperados chegaram ao Volume `bronze.raw` e
# MAGIC não vieram vazios. Arquivo ausente ou vazio interrompe o job — sem essa
# MAGIC conferência, o erro não apareceria: só um número menor lá na frente.

# COMMAND ----------

from datetime import datetime

dbutils.widgets.text("catalog", "lakehouse_mecamecanica")
catalog = dbutils.widgets.get("catalog")

ARQUIVOS_ESPERADOS = {
    "erp": ["produtos", "pedidos", "itens_pedido", "pagamentos", "estoque"],
    "crm": ["clientes", "vendedores", "carteira", "oportunidades", "visitas"],
}

# COMMAND ----------

resultados = []
erros = []
agora = datetime.now()

for sistema, arquivos in ARQUIVOS_ESPERADOS.items():
    for nome in arquivos:
        caminho = f"/Volumes/{catalog}/bronze/raw/{sistema}/{nome}.csv"
        try:
            info = dbutils.fs.ls(caminho)[0]
        except Exception:
            erros.append(f"arquivo ausente: {caminho}")
            continue

        linhas = spark.read.option("header", True).csv(caminho).count()
        if linhas == 0:
            erros.append(f"arquivo vazio: {caminho}")

        resultados.append((sistema, f"{nome}.csv", info.size, linhas, agora))

if erros:
    raise Exception("Conferência de chegada falhou:\n" + "\n".join(erros))

# COMMAND ----------

spark.sql(f"""
    CREATE TABLE IF NOT EXISTS `{catalog}`.bronze._raw_arquivos (
      sistema STRING,
      arquivo STRING,
      bytes BIGINT,
      linhas BIGINT,
      conferido_em TIMESTAMP
    )
    COMMENT 'Registro de conferência de chegada dos arquivos raw: prova de que os arquivos esperados chegaram completos em cada execução do pipeline.'
""")

df_resultado = spark.createDataFrame(
    resultados, ["sistema", "arquivo", "bytes", "linhas", "conferido_em"]
)
df_resultado.write.mode("append").saveAsTable(f"`{catalog}`.bronze._raw_arquivos")

# COMMAND ----------

df_resultado.orderBy("sistema", "arquivo").show(truncate=False)
