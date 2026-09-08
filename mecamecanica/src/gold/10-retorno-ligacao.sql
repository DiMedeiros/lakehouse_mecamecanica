-- Gold — retorno_ligacao: o que aconteceu depois de cada ligação da fila
-- semanal. Escrita pelo app (fora deste pipeline) e lida de volta como rótulo
-- de treino da semana seguinte — por isso CREATE TABLE IF NOT EXISTS, nunca
-- CREATE OR REPLACE: rodar este script de novo não pode apagar retorno já
-- registrado por um vendedor.

CREATE TABLE IF NOT EXISTS lakehouse_mecamecanica.gold.retorno_ligacao (
  cliente_id     INT       COMMENT 'Cliente que recebeu a ligação (gold.fila_semanal.cliente_id).',
  vendedor       STRING    COMMENT 'Vendedor que fez a ligação (gold.fila_semanal.vendedor).',
  status         STRING    COMMENT 'Resultado da ligação: vendeu, vai_pensar, sem_interesse ou nao_atendeu.',
  comentario     STRING    COMMENT 'Texto livre do vendedor sobre a ligação.',
  registrado_em  TIMESTAMP COMMENT 'Quando o retorno foi registrado.',
  registrado_por STRING    COMMENT 'E-mail de quem estava logado ao registrar o retorno.',
  _referencia    DATE      COMMENT 'Semana da fila a que este retorno se refere (mesma data de gold.fila_semanal, via gold.score_propensao._referencia).'
)
COMMENT 'O que aconteceu depois de cada ligação da fila semanal. Começa vazia — se a contagem vier zero, é porque ninguém registrou retorno ainda, não é erro.';
