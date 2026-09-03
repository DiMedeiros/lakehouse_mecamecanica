-- Silver — clientes
--
-- Decisão de escopo válida para as 10 tabelas silver (não repetida nos outros
-- 3 arquivos): toda coluna *_id e sku permanece STRING. Nenhuma vira BIGINT.
--
-- cnpj nunca é convertido para número: 309 CNPJs têm zero à esquerda, e CAST
-- para INT/BIGINT apagaria esse dígito para sempre.

CREATE OR REPLACE TABLE lakehouse_mecamecanica.silver.clientes
COMMENT 'Clientes deduplicados por CNPJ normalizado (14 dígitos). Quando o mesmo CNPJ tem mais de um cadastro na origem, mantém o mais antigo e guarda os demais em cliente_ids_duplicados.'
AS
WITH origem AS (
  SELECT COUNT(*) AS n FROM lakehouse_mecamecanica.bronze.clientes
),
normalizado AS (
  SELECT
    cliente_id,
    lpad(regexp_replace(trim(cnpj), '[^0-9]', ''), 14, '0') AS cnpj,
    regexp_replace(initcap(trim(razao_social)), ' +', ' ') AS razao_social,
    segmento,
    cidade,
    uf,
    bairro,
    coalesce(
      try_to_date(data_cadastro, 'yyyy-MM-dd'),
      try_to_date(data_cadastro, 'dd/MM/yyyy')
    ) AS data_cadastro,
    ativo = 'S' AS ativo
  FROM lakehouse_mecamecanica.bronze.clientes
),
ordenado AS (
  SELECT
    *,
    row_number() OVER (PARTITION BY cnpj ORDER BY data_cadastro ASC, cliente_id ASC) AS rn
  FROM normalizado
),
duplicados AS (
  SELECT cnpj, collect_list(cliente_id) AS todos_ids
  FROM normalizado
  GROUP BY cnpj
  HAVING COUNT(*) > 1
)
SELECT
  o.cliente_id,
  o.cnpj,
  o.razao_social,
  o.segmento,
  o.cidade,
  o.uf,
  o.bairro,
  o.data_cadastro,
  o.ativo,
  COALESCE(filter(d.todos_ids, id -> id != o.cliente_id), array()) AS cliente_ids_duplicados,
  current_timestamp() AS _processado_em,
  origem.n AS _linhas_origem
FROM ordenado o
LEFT JOIN duplicados d ON d.cnpj = o.cnpj
CROSS JOIN origem
WHERE o.rn = 1;

COMMENT ON COLUMN lakehouse_mecamecanica.silver.clientes.cnpj IS
  'Normalizado para 14 dígitos numéricos (trim + regexp_replace + lpad); nunca convertido para número. A constraint garante exatamente 14 dígitos, mas não detecta truncamento por excesso de dígitos na origem — lpad corta silenciosamente acima de 14.';

COMMENT ON COLUMN lakehouse_mecamecanica.silver.clientes.razao_social IS
  'Padronizada com initcap e espaço duplo colapsado; a origem tinha caixa e espaçamento inconsistentes.';

COMMENT ON COLUMN lakehouse_mecamecanica.silver.clientes.cliente_ids_duplicados IS
  'IDs de cadastros duplicados (mesmo CNPJ) descartados na deduplicação, mantendo sempre array vazio quando não há duplicata. Pedidos antigos podem referenciar esses ids descartados.';

ALTER TABLE lakehouse_mecamecanica.silver.clientes
  ADD CONSTRAINT cnpj_14_digitos CHECK (cnpj IS NOT NULL AND length(cnpj) = 14);

ALTER TABLE lakehouse_mecamecanica.silver.clientes
  ADD CONSTRAINT data_cadastro_nao_nula CHECK (data_cadastro IS NOT NULL);
