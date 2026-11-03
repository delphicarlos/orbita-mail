# Órbita Mail para Mac

Implementação **0.2.0** de um cliente nativo com email multicontas, respostas a convites, agenda unificada de compromissos e tarefas e importação de configurações. SwiftUI, SQLite do sistema, Keychain e APIs oficiais Microsoft/Google e protocolos de email via curl/libcurl do macOS, sem pacotes externos.

Nome provisório. Esta versão **ainda não substitui integralmente o Outlook**.

## Abrir

Abra `build/Órbita.app`. O pacote `build/Orbita-Mac-arm64.zip` contém o mesmo aplicativo. Build local para **Apple Silicon**, com destino macOS 14+. A execução foi conferida neste Mac, com macOS 27; compatibilidade no macOS 14 e em outros Macs não foi testada.

No primeiro uso, escolha **Explorar demonstração** para testar com três contas fictícias, sem comunicação com provedores. A faixa superior identifica permanentemente esse modo. A opção **Usar contas reais** retorna ao ambiente independente, inicialmente vazio.

## Organização de email — versão 0.4.0

Inclui contadores de não lidos consultados no provedor, criação/navegação de pastas e movimentação para pasta personalizada, regras de direcionamento, cadastro de assinaturas por conta e respostas automáticas. Abra a engrenagem **Configurações de email**. Veja [ORGANIZACAO.md](ORGANIZACAO.md) para uso e compatibilidade.

Regras e ausência são executadas no servidor Microsoft/Google/Exchange, com consentimento adicional individual nas contas OAuth. Essa autorização foi solicitada e ainda está pendente nesta entrega. Nenhuma regra ou ausência real foi ativada. IMAP/POP precisam do painel do provedor para essas configurações; assinaturas são locais e em texto simples.

## Outros provedores e uso interno

Desde a versão 0.3.0, há **Contas → Outro provedor…** com IMAP/SMTP, POP3/SMTP, Exchange próprio via EWS e CalDAV opcional para agenda/tarefas. Usuários e senhas são individuais, com credenciais no Keychain de cada usuário do Mac. Consulte [PROVEDORES.md](PROVEDORES.md) para configuração, compatibilidade, validação e limites da distribuição interna. Os novos conectores ainda não foram validados com servidores reais de clientes.

## Contas reais

1. Abra **Contas → Gerenciar contas** e expanda **Configuração do aplicativo OAuth**.
2. Informe os IDs dos aplicativos registrados em sua organização. Salve a configuração.
3. Clique em **Conectar Microsoft** ou **Conectar Google** e conclua o consentimento no navegador do sistema.
4. Confira **Fontes e sincronização** na barra superior. Uma conta conectada não comprova que todas as capacidades receberam permissão.

### Microsoft 365 / Outlook

Registre um aplicativo público móvel/desktop no Entra. Escolha tipos de conta compatíveis com as organizações/contas pessoais que serão conectadas. Cadastre `http://localhost/oauth/callback` como retorno desktop; o app utiliza uma porta loopback temporária. Não configure segredo de cliente para este fluxo público.

Permissões delegadas solicitadas: `User.Read`, `Mail.ReadWrite`, `Mail.Send`, `Calendars.ReadWrite`, `Tasks.ReadWrite` e `offline_access`. As organizações podem exigir consentimento administrativo. [Fluxo oficial de autorização](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow).

### Google

Habilite Gmail API, Calendar API e Tasks API no Google Cloud. Configure a tela de consentimento e crie credenciais **Desktop app**, informando Client ID e o segredo fornecido nesse tipo de credencial. O segredo fica no Keychain; em aplicativos desktop ele não constitui uma credencial confidencial de servidor. O retorno usa IP loopback e porta temporária.

Escopos: `gmail.modify`, `calendar.events`, `calendar.calendarlist.readonly` e `tasks`, com seus prefixos completos `https://www.googleapis.com/auth/`. Em modo de teste, cadastre as contas de teste. Verificações Google e políticas corporativas podem limitar o uso contínuo/distribuição. [OAuth Desktop](https://developers.google.com/identity/protocols/oauth2/native-app), [escopos Gmail](https://developers.google.com/workspace/gmail/api/auth/scopes).

**OAuth conectado e validado neste Mac:** cliente público Microsoft `4888d959-7d5f-4eb1-8dfe-a104c5cc8f69` e cliente desktop Google no projeto isolado `orbita-mail-intellitouch`. Gmail, Calendar e Tasks APIs ativadas. As contas Intellitouch e 2safe foram conectadas; segredo desktop e tokens ficam no Keychain. Não foram extraídos tokens internos do Outlook.

Foram enviados dois emails pelo Órbita e conferido o recebimento em ambas as direções, aceitos convites nas contas Google e Microsoft com confirmação no respectivo organizador, e concluídas/reabertas tarefas de teste Microsoft e Google, com conferência nos sites dos provedores. Após reiniciar o aplicativo, ambas as contas continuaram sincronizando. Consulte [VALIDACAO.md](VALIDACAO.md) para evidências e limites do teste.

O Google permanece em **Testando**, com a conta 2safe cadastrada. Nesse modo, o refresh token destes escopos expira em sete dias e será necessário autorizar novamente. A configuração para uso contínuo/distribuição ainda depende de tratar o status de publicação e os requisitos Google. [Regra oficial de expiração](https://developers.google.com/identity/protocols/oauth2#expiration).

### Importar do Outlook

Em **Contas → Importar do Outlook…**, escolha **Ler contas do Outlook** ou **Importar arquivo JSON…** e confira os itens antes de importar. Os endereços ficam pendentes: cada conta precisa autorizar o Órbita por OAuth ou configurar seus servidores. A identidade retornada deve corresponder ao endereço selecionado. Importar configurações não conecta uma conta nem copia mensagens, senhas ou sessões.

A leitura direta usa a automação pública do Outlook e pode solicitar permissão do macOS. Sua disponibilidade depende da versão instalada; esse caminho ainda não foi validado neste Mac. Não há acesso direto aos arquivos protegidos do Outlook. O caminho por JSON foi conferido na interface com três contas identificadas na tela de Contas do Outlook.

O formato está em [examples/outlook-settings.json](examples/outlook-settings.json), com dados fictícios. Aceita contas, assinaturas e modelos; assinaturas/modelos são selecionados explicitamente e inseridos em texto simples pelo menu do editor. A leitura direta pode trazer assinaturas que o Outlook disponibiliza; modelos em nuvem não são detectados automaticamente. IMAP/POP genérico abre a configuração de servidores; uma conta Exchange importada pode ser direcionada para Microsoft 365 ou EWS próprio.

## Fluxos implementados

- Email Microsoft/Google e conectores IMAP/SMTP, POP3/SMTP e EWS, várias contas, caixa conjunta e filtro por conta; pastas padrão, páginas de mensagens recentes e busca no conteúdo já carregado.
- Leitura de texto/HTML com JavaScript e recursos remotos bloqueados; anexos sob demanda, salvos por escolha do usuário e sem abertura automática.
- Contadores de não lidos por pasta/Entrada de conta, criação de pastas e navegação/movimentação em pastas personalizadas.
- Novo email, responder/responder a todos, encaminhar texto, CC/CCO, anexos pequenos, sinalização, lido/não lido, arquivo e lixeira recuperável.
- Rascunhos locais persistentes. Envios sem confirmação ficam bloqueados até conferência explícita da pasta Enviados. O retorno de envio aceito pelo provedor não prova entrega ao destinatário.
- Agenda por conta ou conjunta, nas visões dia/semana/mês/lista, com identidade da origem, filtros por calendário/lista, conflitos e detalhes.
- Calendários e listas enumerados com paginação. Eventos recorrentes são expandidos pelo provedor no intervalo consultado. Tarefas incluem listas autorizadas, sem data e concluídas conforme filtro.
- Aceitar/talvez/recusar na conta convidada, com consulta do estado remoto; preservação de participantes e controle de versão Google. Uma resposta incerta persiste para conferência, sem retry automático da escrita.
- Concluir/reabrir tarefas e conferir o resultado remoto.
- Atualização periódica a cada dois minutos enquanto o app está ativo; estados e falhas por fonte. Contas/fontes com falha não são apresentadas como vazias e sincronizadas.

## Limites desta versão

Veja [FEATURES.md](FEATURES.md) para a matriz completa da primeira entrega.

- Microsoft/Google requerem IDs OAuth e consentimento; os demais provedores requerem servidores e autenticação habilitados. Os testes automatizados usam fixtures; a validação real Microsoft/Google está descrita abaixo.
- Email usa snapshots de páginas recentes: atualizar retorna à primeira página; pesquisa remota completa e sincronização por delta ainda estão pendentes.
- Editor de texto simples; anexos somam até 2,5 MB. Encaminhamento não copia automaticamente anexos. Rascunhos escritos no app ficam neste Mac; não são sincronizados como rascunhos remotos.
- Tarefas Google têm data de agendamento, sem horário acessível pela API. São apresentadas na seção do dia; tarefas sem data ficam em pendências. [Limite oficial](https://developers.google.com/workspace/tasks/reference/rest/v1/tasks).
- Alguns fusos Microsoft personalizados/Windows fora do mapeamento inicial podem impedir a atualização de uma fonte com eventos de dia inteiro. A fonte é preservada em cache e o erro fica visível.
- Recusar um evento Microsoft pode removê-lo antes de ser possível consultar o estado. Se não houver confirmação remota verificável, o app mantém a resposta como pendente de conferência.
- Criação/edição de eventos, novas tarefas, contatos, editor rico de assinaturas, notificações/lembretes e demais recursos avançados do Outlook não estão incluídos nesta fatia.
- Sem serviço em nuvem para execução com o Mac desligado. Sem assinatura Developer ID/notarização. A assinatura do pacote é **ad hoc para uso local**, não distribuição validada.

## Dados e segurança

Ambientes independentes:

- Real: `~/Library/Application Support/OrbitaMail/contas/cache.sqlite`
- Demonstração: `~/Library/Application Support/OrbitaMail/demonstracao/cache.sqlite`

Tokens, senhas dos servidores e o segredo Desktop Google ficam no Keychain, associados ao serviço `br.com.intellitouch.orbita-mail`, sem sincronização do Keychain. SQLite **não possui criptografia própria**; diretórios são privados ao usuário (0700) e arquivos usam permissões restritas (0600/umask 077). A proteção de disco depende do macOS/FileVault da máquina. Não são registrados tokens, códigos OAuth ou corpos de email nos logs de aplicação.

O navegador de leitura é efêmero, sem JavaScript, sem ponte para APIs nativas, com CSP e bloqueio de recursos remotos. Links externos só abrem por ação explícita. Anexos recebem a marca de quarentena ao serem salvos. Não existe exclusão permanente/limpeza de lixeira nesta versão.

## Desenvolvimento e verificação

Execute tudo a partir da raiz deste repositório:

```sh
swift build
swift test
python3 scripts/check-mail-wire.py
bash scripts/package.sh
```

Xcode/Swift usados nesta máquina: Xcode 27.0, Swift 6.4, modo de linguagem Swift 5. Não há instalação npm, bancos externos ou serviço remoto necessário para build/testes.

Os 74 testes exercitam PKCE/state, endpoints permitidos, prevenção de injeção em cabeçalhos, MIME, datas/fusos, conflitos, cache transacional, isolamento de contas, paginação, ETag, limite de chamadas, aceite, reconciliação após timeout, importação e correspondência da identidade OAuth, MIME recebido, literais/UIDVALIDITY IMAP, CCO SMTP, sequência POP3, versões EWS e ETag/participantes CalDAV. O script de transporte usa apenas loopback com credenciais fictícias. Evidências em `evidence/`; veja [VALIDACAO.md](VALIDACAO.md).

Repositório canônico: `/Volumes/nvme/projects/intellitouch/orbita-mail`, branch `main`. Sem commit, push ou publicação nesta entrega. Sem checkout auxiliar.
