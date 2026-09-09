import { useMemo, useState } from 'react';
import {
  useAnalyticsQuery,
  Alert,
  AlertDescription,
  Badge,
  Button,
  Card,
  CardContent,
  CardHeader,
  CardTitle,
  Empty,
  EmptyDescription,
  EmptyTitle,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Skeleton,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@databricks/appkit-ui/react';
import { sql } from '@databricks/appkit-ui/js';
import { num, reais, pct, STATUS, rotuloStatus } from '../../lib/dados';

const TODOS = 'Todos';

function Kpi({
  titulo,
  valor,
  apoio,
  carregando,
}: {
  titulo: string;
  valor: string;
  apoio: string;
  carregando: boolean;
}) {
  return (
    <Card>
      <CardHeader className="pb-2">
        <CardTitle className="text-sm font-medium text-muted-foreground">{titulo}</CardTitle>
      </CardHeader>
      <CardContent>
        {carregando ? (
          <Skeleton className="h-8 w-24" />
        ) : (
          <div className="text-3xl font-bold text-foreground">{valor}</div>
        )}
        <p className="text-xs text-muted-foreground mt-1">{apoio}</p>
      </CardContent>
    </Card>
  );
}

/**
 * O conteúdo é remontado pela `key` do pai depois de cada retorno gravado —
 * remontar refaz as consultas. É o jeito React de recarregar, sem parâmetro
 * inventado no SQL só para furar cache (que quebra a tela de quem está com o
 * JS antigo aberto).
 *
 * O filtro de vendedor e os comentários digitados ficam no PAI, senão a
 * remontagem apagaria os dois.
 */
function Conteudo({
  vendedor,
  setVendedor,
  comentarios,
  setComentarios,
  aoGravar,
}: {
  vendedor: string;
  setVendedor: (v: string) => void;
  comentarios: Record<number, string>;
  setComentarios: React.Dispatch<React.SetStateAction<Record<number, string>>>;
  aoGravar: () => void;
}) {
  const [gravando, setGravando] = useState<number | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);

  const kpis = useAnalyticsQuery('kpis_semana');
  const vendedores = useAnalyticsQuery('vendedores');
  const parametrosFila = useMemo(() => ({ vendedor: sql.string(vendedor) }), [vendedor]);
  const fila = useAnalyticsQuery('fila', parametrosFila);

  const k = kpis.data?.[0];
  const conversaoPrevista = k ? (num(k.acertos_top200) / num(k.contatos)) * 100 : 0;

  async function registrar(idBruto: number | string, nomeVendedor: string, status: string) {
    // Number() uma vez, no ponto de entrada: o tipo gerado diz number, mas o
    // JSON do warehouse entrega "2137" — e daqui para baixo tudo é número.
    const clienteId = num(idBruto);
    setGravando(clienteId);
    setAviso(null);
    try {
      const resposta = await fetch('/api/retorno', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          cliente_id: clienteId,
          vendedor: nomeVendedor,
          status,
          comentario: comentarios[clienteId] ?? '',
          referencia: k?.referencia ?? '2026-08-31',
        }),
      });
      if (!resposta.ok) throw new Error(await resposta.text());
      aoGravar();
    } catch {
      setAviso('Não consegui gravar esse retorno. Tente de novo.');
    } finally {
      setGravando(null);
    }
  }

  return (
    <div className="space-y-6 w-full max-w-7xl mx-auto">
      <div>
        <h2 className="text-2xl font-bold text-foreground">A semana</h2>
        <p className="text-sm text-muted-foreground mt-1">
          Os 200 clientes com maior chance de comprar nos próximos 7 dias
          {k ? ` · fila de ${k.referencia} · modelo versão ${k.versao}` : ''}
        </p>
      </div>

      {kpis.error && (
        <Alert variant="destructive">
          <AlertDescription>Não consegui ler os números da semana: {kpis.error}</AlertDescription>
        </Alert>
      )}
      {aviso && (
        <Alert variant="destructive">
          <AlertDescription>{aviso}</AlertDescription>
        </Alert>
      )}

      <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
        <Kpi
          titulo="Contatos da semana"
          valor={k ? String(k.contatos) : '—'}
          apoio={k ? `${k.vendedores} vendedores` : 'carregando'}
          carregando={kpis.loading}
        />
        <Kpi
          titulo="Receita esperada"
          valor={k ? reais(k.receita_esperada) : '—'}
          apoio="soma de score × ticket médio"
          carregando={kpis.loading}
        />
        <Kpi
          titulo="Conversão prevista"
          valor={k ? `${conversaoPrevista.toFixed(0)}%` : '—'}
          apoio={k ? `contra ${pct(k.taxa_base, 1)} ligando às cegas` : 'carregando'}
          carregando={kpis.loading}
        />
        <Kpi
          titulo="Já trabalhados"
          valor={k ? `${k.ligacoes_registradas}` : '—'}
          apoio={k ? `${k.vendas} viraram pedido` : 'carregando'}
          carregando={kpis.loading}
        />
      </div>

      <Card>
        <CardHeader className="flex flex-row items-center justify-between gap-4">
          <CardTitle>Quem ligar primeiro</CardTitle>
          <Select value={vendedor} onValueChange={setVendedor}>
            <SelectTrigger className="w-64">
              <SelectValue placeholder="Todos os vendedores" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value={TODOS}>Todos os vendedores</SelectItem>
              {vendedores.data?.map((v) => (
                <SelectItem key={v.vendedor} value={v.vendedor}>
                  {v.vendedor} ({v.contatos})
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </CardHeader>
        <CardContent>
          {fila.loading && (
            <div className="space-y-2">
              <Skeleton className="h-10 w-full" />
              <Skeleton className="h-10 w-full" />
              <Skeleton className="h-10 w-full" />
            </div>
          )}
          {fila.error && (
            <Alert variant="destructive">
              <AlertDescription>Não consegui ler a fila: {fila.error}</AlertDescription>
            </Alert>
          )}
          {!fila.loading && !fila.error && fila.data?.length === 0 && (
            <Empty>
              <EmptyTitle>Nenhum cliente nesta carteira</EmptyTitle>
              <EmptyDescription>
                A fila é global: quem tem carteira mais fria recebe menos contatos nesta semana.
              </EmptyDescription>
            </Empty>
          )}
          {!fila.loading && !fila.error && (fila.data?.length ?? 0) > 0 && (
            <div className="overflow-x-auto">
              {/* table-fixed + largura por coluna: sem isso o texto de motivo e
                  sugestão transborda e uma célula escreve por cima da outra. */}
              <Table className="table-fixed w-full min-w-[64rem]">
                <TableHeader>
                  <TableRow>
                    <TableHead className="w-[3rem]">#</TableHead>
                    <TableHead className="w-[15rem]">Cliente</TableHead>
                    <TableHead className="w-[9rem]">Vendedor</TableHead>
                    <TableHead className="w-[5rem] text-right">Chance</TableHead>
                    <TableHead className="w-[16rem]">Por que ligar</TableHead>
                    <TableHead className="w-[14rem]">O que oferecer</TableHead>
                    <TableHead className="w-[13rem]">Como foi a ligação</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {fila.data?.map((linha, i) => {
                    // Uma conversão por linha: daqui para baixo o id é número,
                    // e as comparações de estado funcionam.
                    const id = num(linha.cliente_id);
                    return (
                      <TableRow key={id} className="align-top">
                        {/* Com "Todos", a posição é a da fila global; filtrado
                            por vendedor, é a ordem de ligação daquele vendedor. */}
                        <TableCell className="text-muted-foreground">
                          {vendedor === TODOS ? i + 1 : linha.ordem}
                        </TableCell>
                        <TableCell className="whitespace-normal break-words">
                          <div className="font-medium">{linha.razao_social}</div>
                          <div className="text-xs text-muted-foreground">
                            {linha.cidade}/{linha.uf} · ticket {reais(linha.ticket_medio)}
                          </div>
                        </TableCell>
                        <TableCell className="text-sm whitespace-normal break-words">
                          {linha.vendedor}
                        </TableCell>
                        <TableCell className="text-right font-medium">{pct(linha.score)}</TableCell>
                        <TableCell className="text-sm whitespace-normal break-words">
                          {linha.motivo}
                        </TableCell>
                        <TableCell className="text-sm whitespace-normal break-words">
                          {linha.sugestao}
                        </TableCell>
                        <TableCell className="whitespace-normal">
                          {linha.retorno_status ? (
                            <div className="space-y-1">
                              <Badge variant={linha.retorno_status === 'vendeu' ? 'default' : 'secondary'}>
                                {rotuloStatus(linha.retorno_status)}
                              </Badge>
                              {linha.retorno_comentario && (
                                <p className="text-xs text-muted-foreground">{linha.retorno_comentario}</p>
                              )}
                            </div>
                          ) : (
                            <div className="space-y-2">
                              <Input
                                placeholder="o que o cliente disse"
                                value={comentarios[id] ?? ''}
                                onChange={(e) =>
                                  setComentarios((c) => ({ ...c, [id]: e.target.value }))
                                }
                              />
                              <div className="grid grid-cols-2 gap-1">
                                {STATUS.map((s) => (
                                  <Button
                                    key={s.valor}
                                    size="sm"
                                    className="w-full px-1 text-xs"
                                    variant={s.valor === 'vendeu' ? 'default' : 'outline'}
                                    disabled={gravando === id}
                                    onClick={() => void registrar(id, linha.vendedor, s.valor)}
                                  >
                                    {s.rotulo}
                                  </Button>
                                ))}
                              </div>
                            </div>
                          )}
                        </TableCell>
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

export function SemanaPage() {
  // Estado que precisa sobreviver à remontagem mora aqui.
  const [vendedor, setVendedor] = useState<string>(TODOS);
  const [comentarios, setComentarios] = useState<Record<number, string>>({});
  const [visita, setVisita] = useState(0);

  return (
    <Conteudo
      key={visita}
      vendedor={vendedor}
      setVendedor={setVendedor}
      comentarios={comentarios}
      setComentarios={setComentarios}
      aoGravar={() => setVisita((n) => n + 1)}
    />
  );
}
