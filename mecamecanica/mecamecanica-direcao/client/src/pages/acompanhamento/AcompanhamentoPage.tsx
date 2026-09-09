import { useState } from 'react';
import {
  useAnalyticsQuery,
  Alert,
  AlertDescription,
  Button,
  Card,
  CardContent,
  CardHeader,
  CardTitle,
  Empty,
  EmptyDescription,
  EmptyTitle,
  Progress,
  Skeleton,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@databricks/appkit-ui/react';
import { RefreshCw } from 'lucide-react';
import { num } from '../../lib/dados';

/**
 * A tela é remontada pela `key` do pai a cada "Atualizar". Remontar refaz a
 * consulta — é o jeito React de recarregar, sem parâmetro inventado no SQL só
 * para furar cache (que quebra a tela de quem está com o JS antigo aberto).
 */
function Conteudo({ onAtualizar }: { onAtualizar: () => void }) {
  const { data, loading, error } = useAnalyticsQuery('acompanhamento');
  // A conversão prevista pelo modelo (acertos_top200 / contatos), a mesma
  // conta que "A semana" já faz — sem cravar o número no código, que fica
  // desatualizado a cada novo treino.
  const kpis = useAnalyticsQuery('kpis_semana');
  const k = kpis.data?.[0];
  const conversaoPrevista = k ? (num(k.acertos_top200) / num(k.contatos)) * 100 : null;

  const total = data?.reduce(
    (acc, l) => ({
      na_fila: acc.na_fila + num(l.na_fila),
      trabalhados: acc.trabalhados + num(l.trabalhados),
      vendeu: acc.vendeu + num(l.vendeu),
    }),
    { na_fila: 0, trabalhados: 0, vendeu: 0 },
  );

  // Só quem já tem retorno registrado: 35 linhas zeradas escondem as três
  // que importam.
  const trabalharam = (data ?? [])
    .map((l) => ({
      vendedor: l.vendedor,
      na_fila: num(l.na_fila),
      trabalhados: num(l.trabalhados),
      vendeu: num(l.vendeu),
    }))
    .filter((l) => l.trabalhados > 0);

  const cobertura = total?.na_fila ? (total.trabalhados / total.na_fila) * 100 : 0;
  const conversaoReal = total?.trabalhados ? (total.vendeu / total.trabalhados) * 100 : 0;
  const semRetorno = (total?.trabalhados ?? 0) === 0;

  return (
    <div className="space-y-6 w-full max-w-7xl mx-auto">
      <div className="flex items-start justify-between gap-4">
        <div>
          {/* O título diz a conclusão, não o rótulo da tela. */}
          <h2 className="text-2xl font-bold text-foreground">
            {semRetorno
              ? 'A semana ainda não começou a ser trabalhada'
              : `${total?.trabalhados} de ${total?.na_fila} contatos trabalhados · ${total?.vendeu} viraram pedido`}
          </h2>
          <p className="text-sm text-muted-foreground mt-1">
            O que a fila desta semana virou, vendedor por vendedor
          </p>
        </div>
        <Button variant="outline" size="sm" onClick={onAtualizar}>
          <RefreshCw className="h-4 w-4 mr-2" />
          Atualizar
        </Button>
      </div>

      {error && (
        <Alert variant="destructive">
          <AlertDescription>Não consegui ler o acompanhamento: {error}</AlertDescription>
        </Alert>
      )}

      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Cobertura da fila
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-2">
            {loading ? (
              <Skeleton className="h-8 w-24" />
            ) : (
              <div className="text-3xl font-bold text-foreground">{cobertura.toFixed(0)}%</div>
            )}
            <Progress value={cobertura} />
            <p className="text-xs text-muted-foreground">
              {total?.trabalhados ?? 0} de {total?.na_fila ?? 0} contatos
            </p>
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Conversão real
            </CardTitle>
          </CardHeader>
          <CardContent>
            {loading ? (
              <Skeleton className="h-8 w-24" />
            ) : (
              <div className="text-3xl font-bold text-foreground">
                {semRetorno ? '—' : `${conversaoReal.toFixed(0)}%`}
              </div>
            )}
            <p className="text-xs text-muted-foreground mt-1">
              {conversaoPrevista === null
                ? 'carregando previsão do modelo'
                : `o modelo previu ${conversaoPrevista.toFixed(0)}% para os 200`}
            </p>
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Pedidos fechados
            </CardTitle>
          </CardHeader>
          <CardContent>
            {loading ? (
              <Skeleton className="h-8 w-24" />
            ) : (
              <div className="text-3xl font-bold text-foreground">{total?.vendeu ?? 0}</div>
            )}
            <p className="text-xs text-muted-foreground mt-1">
              vira rótulo de treino da próxima semana
            </p>
          </CardContent>
        </Card>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>
            {semRetorno ? 'Contatos trabalhados por vendedor' : 'Quem já trabalhou a carteira'}
          </CardTitle>
        </CardHeader>
        <CardContent>
          {loading && <Skeleton className="h-64 w-full" />}
          {!loading && !error && semRetorno && (
            <Empty>
              <EmptyTitle>Nenhuma ligação registrada ainda</EmptyTitle>
              <EmptyDescription>
                Assim que o time marcar o retorno na aba &ldquo;A semana&rdquo;, o número aparece aqui — e vira
                dado de treino para a fila da semana que vem.
              </EmptyDescription>
            </Empty>
          )}
          {!loading && !error && !semRetorno && (
            <div className="space-y-4">
              {trabalharam.map((l) => (
                <div key={l.vendedor} className="space-y-1.5">
                  <div className="flex items-baseline justify-between gap-4 text-sm">
                    <span className="font-medium">{l.vendedor}</span>
                    <span className="text-muted-foreground">
                      {l.trabalhados} de {l.na_fila} contatos ·{' '}
                      <span className="text-foreground font-medium">{l.vendeu} vendeu</span>
                    </span>
                  </div>
                  {/* Duas barras sobrepostas: o quanto da carteira foi
                      trabalhado, e quanto disso virou pedido. */}
                  <div className="relative h-2.5 w-full rounded-full bg-muted overflow-hidden">
                    <div
                      className="absolute inset-y-0 left-0 bg-muted-foreground/40"
                      style={{ width: `${(l.trabalhados / l.na_fila) * 100}%` }}
                    />
                    <div
                      className="absolute inset-y-0 left-0 bg-primary"
                      style={{ width: `${(l.vendeu / l.na_fila) * 100}%` }}
                    />
                  </div>
                </div>
              ))}
              <p className="text-xs text-muted-foreground pt-2">
                A barra clara é o que foi trabalhado da carteira; a escura, o que virou pedido.
                Quem ainda não ligou não aparece aqui — está na tabela abaixo.
              </p>
            </div>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Desfecho, linha por linha</CardTitle>
        </CardHeader>
        <CardContent>
          {loading && <Skeleton className="h-40 w-full" />}
          {!loading && !error && (
            <div className="overflow-x-auto">
              <Table className="table-fixed w-full min-w-[52rem]">
                <TableHeader>
                  <TableRow>
                    <TableHead className="w-[14rem]">Vendedor</TableHead>
                    <TableHead className="w-[6rem] text-right">Na fila</TableHead>
                    <TableHead className="w-[7rem] text-right">Trabalhados</TableHead>
                    <TableHead className="w-[6rem] text-right">Vendeu</TableHead>
                    <TableHead className="w-[7rem] text-right">Vai pensar</TableHead>
                    <TableHead className="w-[8rem] text-right">Sem interesse</TableHead>
                    <TableHead className="w-[8rem] text-right">Não atendeu</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {data?.map((l) => {
                    const trabalhou = num(l.trabalhados) > 0;
                    return (
                      <TableRow key={l.vendedor} className={trabalhou ? '' : 'text-muted-foreground'}>
                        <TableCell className="font-medium">{l.vendedor}</TableCell>
                        <TableCell className="text-right">{l.na_fila}</TableCell>
                        <TableCell className="text-right font-medium">{l.trabalhados}</TableCell>
                        <TableCell className="text-right font-medium">{l.vendeu}</TableCell>
                        <TableCell className="text-right">{l.vai_pensar}</TableCell>
                        <TableCell className="text-right">{l.sem_interesse}</TableCell>
                        <TableCell className="text-right">{l.nao_atendeu}</TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

export function AcompanhamentoPage() {
  // Trocar a key remonta a tela inteira, e a consulta roda de novo.
  const [visita, setVisita] = useState(0);
  return <Conteudo key={visita} onAtualizar={() => setVisita((n) => n + 1)} />;
}
