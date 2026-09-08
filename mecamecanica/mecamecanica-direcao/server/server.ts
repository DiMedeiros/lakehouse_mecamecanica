import { createApp, analytics, genie, server } from '@databricks/appkit';

await createApp({
  plugins: [analytics({}), genie(), server()],

  // Sem cache de leitura: a fila e as métricas do modelo mudam a cada
  // execução do pipeline, e são só 200 linhas — o warehouse aguenta.
  cache: { enabled: false },

  onPluginsReady(appkit) {
    appkit.server.extend((app) => {
      // Quem está logado. O app roda como service principal, mas quem abre a
      // tela é uma pessoa — expõe o e-mail para a aba Perguntar mostrar.
      app.get('/api/quem-sou', (req, res) => {
        res.json({
          email: req.header('x-forwarded-email') ?? 'local@mecamecanica',
          usuario: req.header('x-forwarded-user') ?? 'desenvolvimento',
        });
      });
    });
  },
});
