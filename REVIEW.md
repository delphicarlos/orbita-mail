# Revisão do desenho

Entendimento e abordagem confirmados pelo usuário em 03/11/2026; implementação autorizada.

## Concretização
SwiftUI macOS14+, SQLite do sistema, Keychain, conectores URLSession Microsoft Graph v1 e Google Gmail/Calendar/Tasks. Sem dependências externas. OAuth PKCE no navegador do sistema, callback temporário apenas loopback com state e timeout. IDs OAuth configuráveis pelo usuário.

## Cético — objeções aceitas
1. Todas as fontes precisam de paginação e falhas individuais visíveis.
2. Snapshot de eventos deve substituir apenas fonte/intervalo concluído; expandir recorrências e respeitar cancelamentos.
3. RSVP opera na identidade completa, com reconciliação antes de repetir; preservar participantes e ETag Google.
4. Configuração OAuth e consentimento são pré-requisitos reais, distintos de compilação e fixtures.
5. Fixtures não validam envio/aceite real; testes reais permanecem identificados separadamente.
6. Primeira fatia não é paridade completa: manter matriz explícita de recursos.

Resolução: todos incorporados ao plano. Nenhuma nova função ou mudança no objetivo.

## Guardião de restrições — objeções aceitas
- HTML de email sem JavaScript, remotos, formulários, arquivos ou ponte privilegiada; links externos somente por gesto explícito.
- Cache SQLite não criptografado, diretório 0700 e arquivos 0600; tokens só no Keychain; sem conteúdo privado nos logs.
- Endpoints de OAuth/API fixos, PKCE/state e listener loopback com cancelamento e timeout.
- I/O fora do caminho de renderização, concorrência limitada, paginação progressiva de email e Retry-After respeitado; anexos/corpos sob demanda.
- Persistência serializada/transacional e identidade por conta/fonte/item.
- Build local separado de assinatura/notarização e E2E autenticado.

Resolução: todos aceitos; sem ampliação do objetivo.

## Representante do usuário — objeções aceitas
- Cobertura e estado de cada fonte na agenda; não confundir agenda vazia com falha de acesso.
- RSVP identifica conta e comunicação ao organizador; estado Confirmando resposta e bloqueio de repetição.
- Nome Agenda unificada/Todas as contas evita interpretação de publicação para terceiros.
- Tarefas com data sem hora em seção diária e pendências sem data separadas; ação de concluir identifica conta/lista.
- Modo demonstração persistente e armazenamento separado; resultados fictícios identificados.
- Configuração OAuth separada de conexão e instruções por provedor.

Resolução: todos aceitos e incorporados. Não há objeções abertas.

## Arbitragem final

**APPROVED** — todas as objeções foram aceitas e receberam resolução concreta. Nenhuma objeção rejeitada ou materialmente aberta. Implementação autorizada com SwiftUI, SQLite, Keychain e conectores oficiais, distinguindo build local, fixtures e validação real. A primeira entrega é uma implementação inicial, sem alegação de paridade completa com Outlook.
