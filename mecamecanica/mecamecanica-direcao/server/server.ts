import { createApp, analytics, genie, server, getExecutionContext } from '@databricks/appkit';
import { z } from 'zod';

// Os quatro desfechos possíveis de uma ligação. Qualquer outra coisa é recusada
// antes de chegar ao banco: o retorno de hoje é o rótulo de treino da semana que vem.
const RetornoSchema = z.object({
  cliente_id: z.coerce.number().int(), // o warehouse devolve id como string
  vendedor: z.string().min(1),
  status: z.enum(['vendeu', 'vai_pensar', 'sem_interesse', 'nao_atendeu']),
  comentario: z.string().max(500).default(''),
  referencia: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
});

await createApp({
  plugins: [analytics({}), genie(), server()],

  // Sem cache de leitura. Toda tela daqui lê a fila da semana e o retorno que
  // o time acabou de registrar: servir resposta guardada é mostrar número
  // velho para quem acabou de clicar. São 200 linhas — o warehouse aguenta.
  cache: { enabled: false },

  onPluginsReady(appkit) {
    appkit.server.extend((app) => {
      // Quem está logado. O app roda como service principal, mas o retorno é
      // gravado com o e-mail de quem clicou — senão ninguém sabe quem disse
      // que vendeu.
      app.get('/api/quem-sou', (req, res) => {
        res.json({
          email: req.header('x-forwarded-email') ?? 'local@mecamecanica',
          usuario: req.header('x-forwarded-user') ?? 'desenvolvimento',
        });
      });

      // O único endpoint que ESCREVE. Leitura é sempre config/queries/*.sql.
      app.post('/api/retorno', async (req, res) => {
        const parsed = RetornoSchema.safeParse(req.body);
        if (!parsed.success) {
          res.status(400).json({ erro: 'Retorno inválido', detalhe: parsed.error.issues });
          return;
        }
        const { cliente_id, vendedor, status, comentario, referencia } = parsed.data;
        const email = req.header('x-forwarded-email') ?? 'local@mecamecanica';

        try {
          const contexto = getExecutionContext();
          const warehouseId = (await contexto.warehouseId) ?? process.env.DATABRICKS_WAREHOUSE_ID!;
          await contexto.client.statementExecution.executeStatement({
            warehouse_id: warehouseId,
            wait_timeout: '30s',
            statement: `
              INSERT INTO lakehouse_mecamecanica.gold.retorno_ligacao
                (cliente_id, vendedor, status, comentario, registrado_em, registrado_por, _referencia)
              VALUES (:cliente_id, :vendedor, :status, :comentario, current_timestamp(), :email, :referencia)
            `,
            parameters: [
              { name: 'cliente_id', value: String(cliente_id), type: 'INT' },
              { name: 'vendedor', value: vendedor, type: 'STRING' },
              { name: 'status', value: status, type: 'STRING' },
              { name: 'comentario', value: comentario, type: 'STRING' },
              { name: 'email', value: email, type: 'STRING' },
              { name: 'referencia', value: referencia, type: 'DATE' },
            ],
          });
          res.status(201).json({ ok: true });
        } catch (erro) {
          console.error('[retorno] falhou ao gravar', erro);
          res.status(500).json({ erro: 'Não consegui gravar o retorno' });
        }
      });
    });
  },
});
