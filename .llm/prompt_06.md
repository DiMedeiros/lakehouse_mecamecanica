# Prompt 6 · Features — o que descreve um cliente

**Entrega:** `gold.features_treino` e `gold.features_cliente`, geradas pela
mesma função com datas diferentes. **Deploy nº 6.**

> A tentação é começar pelo modelo. Comece pelas features: o modelo é o
> mesmo `.fit()` para todo mundo, e é aqui que sai a diferença entre o
> projeto que funciona e o que impressiona no notebook e morre em produção.

---

## Contexto desta entrega

Esta é a primeira das três entregas da trilha de ciência de dados (aula-03
do curso), adaptada de `rotaperfume`/`lakehouse_rotaperfume` para
`mecamecanica`/`lakehouse_mecamecanica`. Um incidente de antivírus apagou o
código-fonte local desta camada antes de ser commitado; o notebook abaixo
foi reconstruído comparando o schema real já implantado no catálogo
(`DESCRIBE TABLE EXTENDED`) com o roteiro oficial do curso — as 20 colunas
batem 1:1 com o que já estava em produção.

## O prompt

```
Crie src/ml/09-features.py — um notebook Python para serverless.

Defina UMA função montar_features(referencia) que devolve uma linha por
cliente com tudo que se sabia dele ATÉ essa data. Cada fonte é filtrada pela
data dela na primeira linha da leitura, sem exceção:

  gold.fato_vendas        data_pedido   < referencia
  silver.oportunidades    data_abertura < referencia
  silver.visitas          data_visita   < referencia

NÃO leia gold.dim_cliente: dias_sem_comprar, receita_acumulada e
total_pedidos agregam a base INTEIRA, sem corte — usar qualquer uma é
vazamento.

Vinte features, em quatro grupos, tudo saindo de gold.fato_vendas (já traz
razao_social, canal, categoria e marca — sem join):

  RFM: recencia_dias, frequencia_pedidos, valor_total, ticket_medio,
       margem_total, margem_percentual
  Ritmo: intervalo_medio_dias, desvio_intervalo_dias, atraso_relativo
       (recencia_dias / intervalo_medio_dias, NULLIF no denominador, teto
       em 10), pedidos_ultimos_90d
  CRM: oportunidades_abertas, oportunidades_ganhas, taxa_ganho,
       visitas_90d, conversao_visita
  Mix: skus_distintos, categorias_distintas, marcas_distintas,
       concentracao_marca_top, comprou_lancamento

Grave duas tabelas, chamando a MESMA função duas vezes:
  gold.features_treino   referencia = 2026-08-01, mais o alvo comprou_em_7d
                          = 1 se fez pedido entre 2026-08-01 e 2026-08-07
  gold.features_cliente  referencia = 2026-08-31, sem alvo

Cast para double em todas as features numéricas (a gold usa DECIMAL, e o
registro do modelo quebra depois com "Object of type Decimal is not JSON
serializable"). Cliente sem oportunidade/visita fica com 0, não NULL — só
as features de ritmo continuam NULL para quem tem um pedido só.

silver.visitas não tem uma coluna booleana de conversão: derive
gerou_pedido de resultado = 'Pedido realizado'.

COMMENT em português na tabela — as duas.
```

## Armadilhas medidas

- `F.least()` ignora nulo e devolve o outro valor: no teto do
  `atraso_relativo`, clientes de um pedido só (intervalo `NULL`) receberiam
  o teto e iriam para o topo da fila. Corrigido com
  `when(intervalo_medio_dias IS NOT NULL AND > 0)` por fora.
- `silver.visitas` não tem uma coluna de conversão pronta — o resultado da
  visita é categórico (`'Sem pedido'`, `'Pedido realizado'`, `'Cliente
  ausente'`, `'Reagendada'`, `'Apenas relacionamento'`); `gerou_pedido` é
  derivado comparando com `'Pedido realizado'`.

## Como verificar a feature

```sql
SELECT '_treino' AS tabela, COUNT(*) AS clientes, MIN(_referencia) AS corte
FROM lakehouse_mecamecanica.gold.features_treino
UNION ALL
SELECT '_cliente', COUNT(*), MIN(_referencia)
FROM lakehouse_mecamecanica.gold.features_cliente;
```

**2.815 e 2.816 clientes**, com `2026-08-01` e `2026-08-31` declarados na
própria linha.

```sql
-- a prova de que não há vazamento: recência negativa é a assinatura dele
SELECT MIN(recencia_dias) AS menor_recencia
FROM lakehouse_mecamecanica.gold.features_treino;
```

Confirmado positivo — nenhuma fonte escapou do filtro de data.
