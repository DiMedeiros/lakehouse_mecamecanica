import { useEffect, useState } from 'react';
import { Alert, AlertDescription, Badge, GenieChat } from '@databricks/appkit-ui/react';

export function GeniePage() {
  const [email, setEmail] = useState<string>('');

  useEffect(() => {
    fetch('/api/quem-sou')
      .then((r) => r.json() as Promise<{ email: string }>)
      .then((d) => setEmail(d.email))
      .catch(() => setEmail(''));
  }, []);

  return (
    <div className="space-y-4 w-full max-w-4xl mx-auto">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="text-2xl font-bold text-foreground">Perguntar</h2>
          <p className="text-sm text-muted-foreground mt-1">
            As mesmas tabelas da tela anterior, em português. Pergunte &ldquo;quantos clientes na
            fila desta semana?&rdquo; ou &ldquo;quem são os cinco maiores scores?&rdquo;.
          </p>
        </div>
        {email && <Badge variant="secondary">{email}</Badge>}
      </div>

      <Alert>
        <AlertDescription>
          As respostas são geradas por IA a partir da gold da mecamecanica. Toda resposta traz o
          SQL que a produziu — confira antes de levar o número para a reunião.
        </AlertDescription>
      </Alert>

      <div className="h-[min(600px,70vh)] border rounded-lg overflow-hidden">
        <GenieChat alias="default" />
      </div>
    </div>
  );
}
