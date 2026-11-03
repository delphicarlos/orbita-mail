# Validação — 03/11/2026

## Local

- Repositório canônico: `/Volumes/nvme/projects/intellitouch/orbita-mail`; branch `main`, repositório novo sem commits.
- Build debug e release executados na raiz canônica. Swift 6.4 / Xcode 27.0, destino macOS 14+, arquitetura arm64.
- Versão 0.2.0: 37 testes XCTest, zero falhas (`evidence/tests-import.log`): domínio, OAuth/PKCE/state, MIME, isolamento, armazenamento transacional, importação, identidade esperada e conectores com HTTP simulado. Nenhum teste de provedor acessa a rede real.
- Pacote `build/Órbita.app` e arquivo `build/Orbita-Mac-arm64.zip`; assinatura ad hoc local verificada. Sem Developer ID, notarização ou validação de distribuição.

## Conferência no aplicativo

- Primeiro uso sem contas reais e entrada explícita na demonstração.
- Leitura de email fictício, origem visível e filtro individual: 6 mensagens conjuntas, 2 da conta Atlas.
- Agenda com três contas/calendários/listas e tarefas sem data separadas.
- Aceite de convite fictício Lume: estado passou de Sem resposta para Aceito, com aviso de que nenhum convite real foi respondido.
- Conclusão e reabertura de tarefa fictícia Lume; contagem passou de 3 para 2 e voltou a 3 ao incluir/reabrir concluída.
- Editor preenchido com destinatário `example.test`, assunto e corpo fictícios; Simular envio encerrou o editor com aviso de que nenhum email foi enviado.
- Ajustes após conferência: contraste adaptado ao modo escuro, identificação textual de contas nos filtros de fontes, horário inicial da grade e limpeza de seleção ao trocar de módulo.

Na conferência inicial, o pacote foi reaberto: visões semana, mês, dia e lista conferidas; seleção de compromisso foi limpa ao trocar para Tarefas. O ambiente real ainda estava vazio nessa etapa. Depois foi executada a validação real abaixo.

Capturas e logs estão em `evidence/`. Capturas de demonstração usam exclusivamente dados fictícios.

## Integrações reais

**Executadas em 03/11/2026**, com o par autorizado `carlos.cabral@intellitouch.com.br` ↔ `carlos.cabral@2safe.com`. Contas conectadas por OAuth próprio do Órbita; segredo Google salvo no Keychain após autorização expressa. O aplicativo já apresentou as contas conectadas após os consentimentos concluídos no navegador; não se atribui ao agente o clique final dos consentimentos que não foi observado.

| Fluxo | Ação e confirmação |
| --- | --- |
| Microsoft → Google | Email `ORB-20261103-A1` composto e enviado pela interface do Órbita, com remetente Intellitouch. Após sincronizar, mensagem encontrada na Caixa de entrada 2safe com origem e identificador corretos. |
| Google → Microsoft | Email `ORB-20261103-A2` enviado pela interface do Órbita com remetente 2safe; encontrado na Caixa de entrada Intellitouch. Ambos os recebimentos foram conferidos no aplicativo e nos registros de inbox do cache recém-sincronizado. |
| Convite Google → organizador Microsoft | Convite controlado já estava Aceito na primeira conferência. Para exercitar o fluxo, Talvez e depois Aceitar foram acionados pelo Órbita na conta 2safe. O app confirmou o estado remoto; o conector Outlook consultou o organizador e retornou `tentativelyAccepted` e depois `accepted`. As duas notificações também chegaram à caixa Intellitouch. |
| Convite Microsoft → organizador Google | Segundo convite `ORB-20261103-C2` criado pela interface Google Calendar da conta 2safe, para Intellitouch, em 03/11/2026, 17h15–17h25, Livre e sem notificações próprias. O Google adicionou automaticamente um link Meet. No Órbita Microsoft, estado inicial Sem resposta; Aceitar acionado e confirmado no provedor. No site Google do organizador, o evento passou a exibir “2 convidados” e “2: sim”. Nenhuma resposta de participante foi alterada pelo site Google. |
| Tarefa Google | `ORB-20261103-TG` criada no Google Tasks 2safe, agendada para hoje; apareceu na agenda do Órbita. Concluída pelo Órbita; após recarregar o site Google, apareceu em Concluídas com checkbox 1. Reaberta pelo Órbita; após recarregar o site, checkbox 0 e tarefa ativa. |
| Tarefa Microsoft | `ORB-20261103-TM` criada no Microsoft To Do Intellitouch, vencimento hoje. Sincronizada, concluída e reaberta pelo Órbita, com estado remoto confirmado. Site To Do recarregado mostrou checkbox 1 e depois 0. |
| Agenda unificada | Duas contas, quatro calendários, nove listas de tarefas. Convite controlado visível em ambas as origens e duas tarefas de teste no dia, com fonte preservada. |
| Persistência | Órbita encerrado e reaberto. Ambas as contas continuaram conectadas e todas as fontes consultadas exibiram atualização bem-sucedida às 15:19, America/Fortaleza. Não foi forçada expiração nem revogação de tokens. |

Conferência final do cache: 80 mensagens recentes (40 por conta), 10 eventos no intervalo consultado (incluindo feriados e as duas cópias de cada convite controlado), 22 tarefas (21 Microsoft e 1 Google), 13 fontes (4 calendários e 9 listas). Essas contagens não representam todo o histórico de emails. Tarefas de negócio existentes não foram modificadas pelos testes; apenas as duas tarefas controladas foram concluídas/reabertas.

Evidências privadas em `evidence/oauth/`: `emails-recebidos-duas-contas.png`, `convite-aceito-orbita.png`, `convite-inverso-confirmado-organizador-google.png`, capturas de conclusão/reabertura nos provedores, `agenda-unificada-real-final.png`, `sincronizacao-real-final.txt` e `real-validation.json`. Os dois convites e as tarefas controladas foram preservados para conferência: convites aceitos, tarefas reabertas. Os emails de teste também permanecem nas contas.

Limites: não houve teste de recusa, anexos, respostas/encaminhamento de email, CC/CCO, expiração/revogação, outras organizações ou uso prolongado. Google continua em Testando: refresh token destes escopos expira após sete dias ([documentação oficial](https://developers.google.com/identity/protocols/oauth2#expiration)). Não foi publicado para produção nem submetido à verificação Google.

## Importação e preparação OAuth — versão 0.2.0

- Tela de Contas do Outlook conferida: Intellitouch (Microsoft 365), 2safe (Google) e Artit (Microsoft 365).
- JSON privado preparado com esses nomes, endereços e provedores visíveis. Importação pelo seletor de arquivos conferida, com prévia e seleção. Inicialmente três contas pendentes; depois Intellitouch e 2safe foram conectadas. Artit permanece sem autorização. Isso valida a importação por arquivo, não a leitura automática do Outlook.
- Leitura direta de contas e assinaturas implementada por NSAppleScript fixo sobre a interface pública do Outlook. Não exercitada; depende da permissão de Automação e do suporte da versão instalada. A pasta privada do Outlook negou acesso pelo macOS e não foi contornada.
- Assinaturas/modelos importáveis em texto simples e menu de inserção implementados. Nenhuma assinatura real foi importada nesta execução.
- Projeto Google Cloud isolado `orbita-mail-intellitouch` criado, sem alteração dos projetos existentes. Após autorização explícita do usuário, a configuração OAuth externa em teste e o cliente desktop “Órbita Mail Mac” foram criados. Conta `carlos.cabral@2safe.com` salva como usuária de teste. Segredo salvo no Keychain após confirmação, sem inclusão no código ou relatórios.
- Gmail API, Google Tasks API e Calendar API ativadas, com status Ativado conferido no portal. As políticas e os termos adicionais da Calendar API foram aceitos após autorização do usuário. Ativar APIs não concede acesso às contas.
- Registro Microsoft concluído no tenant Intellitouch: cliente público desktop `4888d959-7d5f-4eb1-8dfe-a104c5cc8f69`, contas organizacionais/pessoais, retorno `http://localhost/oauth/callback`. ID salvo no Órbita.
- Primeira tentativa real encontrou falha local do NWListener (EINVAL): o handler de novas conexões era definido depois de iniciar a escuta. Corrigido para definir antes de `start`; reprodução local passou de erro para ready com porta temporária. Novo pacote compilado, assinatura verificada e 37 testes aprovados (`evidence/tests-oauth.log`). O fluxo iniciado pelo aplicativo chegou à tela Microsoft de permissões da conta correta.
- Consentimento individual Microsoft autorizado expressamente; ambas as contas apresentadas conectadas pelo aplicativo após os fluxos de navegador. Não foi acionado consentimento administrativo para toda a organização pelo agente.
- Criado pelo conector Outlook Calendar um convite controlado Intellitouch → 2safe em 03/11/2026, 17h–17h10, America/Fortaleza, assunto “Órbita — validação controlada de convite — 03/11/2026”, Livre e sem lembrete. Aceite posterior pelo Órbita validado conforme tabela acima. Identificadores privados em `evidence/oauth/real-validation.json`.
- Capturas privadas dos portais e contas em `evidence/oauth/`, excluído do Git. O manifesto público não contém segredos OAuth.

Próximas validações para ampliar cobertura: recusa, expiração/revogação, anexos e demais recursos ainda não exercitados. O objetivo atual de conexão, envio e aceite em ambas as direções, agenda e tarefas controladas foi validado neste Mac.

## Revisão do desenho

Os três revisores exigidos pela skill multi-agent-brainstorming foram invocados sequencialmente. Todas as objeções materiais foram aceitas, com resoluções registradas em REVIEW.md. O árbitro declarou **APPROVED** antes do código. Isso é revisão do desenho, não auditoria de segurança ou certificação do produto.

## Versionamento e escopo

Sem commit, push ou implantação do aplicativo. Foi criado apenas o projeto Google Cloud isolado para o OAuth; nenhum recurso pago foi contratado. Não foram modificados projetos existentes. Código, builds e pacote ficam no repositório canônico; não há worktree ou clone auxiliar.

A skill Impeccable foi atualizada a pedido do usuário para 4.8.0 em `~/.agents/skills/impeccable`; o caminho legado `~/.codex/skills/impeccable` aponta para essa instalação. Backup da 3.9.1 em `~/.codex/backups/impeccable-3.9.1-before-2026-11-03`.

## Provedores padrão e Exchange próprio — versão 0.3.0

- Build final release concluído sem warnings/erros em `evidence/build-release.log`; pacote arm64 `build/Órbita.app`, versão 0.3.0, build 3, assinatura ad hoc verificada. A única biblioteca de transporte vinculada é `/usr/lib/libcurl.4.dylib` do macOS. Sem pacote de rede externo.
- **57 testes XCTest, zero falhas**, em `evidence/tests-providers.log`. A suíte anterior Microsoft/Google permanece aprovada. Novos cenários: metadados sem senhas, URLs/usuários inválidos, conta OAuth legada, MIME/charsets/anexos, truncamento, literal com falso término IMAP, UIDVALIDITY, PEEK, CCO fora do conteúdo SMTP, falha após envio sem reenvio automático, UIDL/posição POP3, fallback TOP → RETR, XML sem entidades, EWS com ChangeKey/NeverOverwrite, endereços completos para respostas, aceite EWS com uma escrita e leitura de confirmação, ETag/participantes CalDAV, tarefas VTODO e limites de recorrência/duração.
- **14 verificações de transporte aprovadas** (`evidence/mail-wire.json`, `evidence/mail-wire.log`), executadas por `python3 scripts/check-mail-wire.py`: servidores descartáveis em loopback, credenciais fictícias, certificados temporários, TLS e STARTTLS, LIST/STATUS/SEARCH/FETCH/APPEND IMAP, rejeição de UIDVALIDITY divergente, UIDL/TOP/RETR POP3, autenticação/NOOP SMTP e submissão SMTP. Rejeição de certificado não confiável também exercitada. Não foi alterada a confiança do sistema.
- O teste de transporte encontrou truncamento do conteúdo FETCH pela CLI curl 8.7.1. Corrigido usando libcurl do sistema para conectar/autenticar e leitor de respostas que respeita o tamanho dos literais. A ponte C foi exercitada contra TLS/STARTTLS locais, e o enquadramento Swift por testes de dados parciais/literais; o teste não equivale a conexão com servidor de cliente.
- Conferência nativa: botão **Outro provedor…** presente; formulário IMAP/SMTP com TLS, SMTP separado, pastas e CalDAV; POP3 selecionável com porta 995 e limitações visíveis; EWS com URL HTTPS e NTLM/senha. Um endereço de servidor contendo `https://` foi recusado localmente, antes de salvar credenciais ou conectar. A conta fictícia de interface não foi salva.
- Após abrir o pacote final, as duas contas OAuth reais continuaram conectadas e atualizaram as fontes às 16h09 locais. Painel mostrou ambas as Entradas atualizadas, quatro calendários e nove listas de tarefas, sem erro de fonte. Este é um teste de regressão de sincronização; os envios/aceites reais documentados acima pertencem à validação da 0.2 e não foram repetidos nesta atualização.
- Capturas privadas em `evidence/providers/`, excluídas do Git: `contas-0.3.png`, `imap-0.3.png`, `exchange-0.3.png`, `pop3.png`, `imap-validacao-local.png`, `sincronizacao-0.3.png` e texto correspondente. Nenhuma senha preenchida. Manifesto com hashes em `evidence/manifest.json`.

**Pendente:** autenticar e testar envio, anexos, convite, agenda e tarefas contra servidores reais IMAP/POP3/EWS/CalDAV informados pela TI. Não recebemos servidor/conta adicional para essa etapa. Compatibilidade universal e liberação para todos os funcionários não estão comprovadas. Distribuição assinada/notarizada, outros Macs e versões do macOS, publicação Google e aprovações de cada organização permanecem pendentes. Configuração e matriz de limites em [PROVEDORES.md](PROVEDORES.md).

Todas as alterações foram feitas no checkout canônico `/Volumes/nvme/projects/intellitouch/orbita-mail`, branch `main`; testes e empacotamento executados nessa raiz. Sem checkout auxiliar, commit, push, publicação ou alteração de infraestrutura. Contas e dados reais existentes foram preservados.

## Organização de email — versão 0.4.0

- Aplicativo atualizado para 0.4.0, build 4. Build release sem warnings/erros; assinatura ad hoc verificada. Pacote final aberto novamente pelo controle nativo. Binário/pacote na raiz canônica `build/`. O ZIP da 0.3 foi preservado como `build/Orbita-Mac-arm64-0.3.0.zip`.
- **74 testes XCTest, zero falhas**, registrados em `evidence/tests-organization.log`. Incluem as 57 verificações anteriores e cenários de consentimento opcional, bloqueio antes de pedir configuração sem escopo, contagem Google acima de uma página, pasta personalizada, isolamento de movimentação/cache, critérios e ações de regras, manutenção das regras Outlook, conflito/reconciliação de ausência e assinatura no MIME/JSON de envio.
- **16 verificações locais de transporte aprovadas**, `evidence/mail-wire-organization.log` e `evidence/mail-wire.json`: os 14 cenários anteriores mais STATUS UNSEEN/MESSAGES e CREATE IMAP. São servidores descartáveis em loopback, sem contas de clientes nem alteração de confiança do sistema.
- **Não lidos reais:** na primeira conferência, Entrada Microsoft 149.127 e Google 11.675, total 160.802, enquanto a lista tinha apenas 80 mensagens carregadas. Depois houve novo recebimento e o total passou a 160.803. No pacote final, filtrar Google mostrou 40 carregadas e 11.676 não lidos; o botão Todas as contas manteve 160.803. As contagens são pontuais e os marcadores Gmail podem se sobrepor.
- **Pastas reais:** pelo Órbita, criadas pastas/marcadores `Órbita - Validação 0.4` nas duas contas. O servidor confirmou a criação e os itens apareceram na lista. Consultas posteriores retornaram 48 pastas Microsoft e 9 marcadores/pastas Google. A pasta Google criada foi aberta pela lateral: zero mensagens, zero não lidos, origem Google preservada. Não foram movidas mensagens reais para validar esse fluxo.
- **Demonstração isolada:** criada pasta `Clientes - Demonstração 0.4` para Atlas; regra `Clientes - Contratos` salva com remetente `cliente@example.test`, destinatário `ana@atlas.example`, assunto `Contrato` e a pasta como destino. A regra foi listada após salvar. Não há execução de regras fictícias sobre recebimentos.
- **Ausência fictícia:** mensagem de demonstração, ativação e período de 03/11 a 04/11 salvos no armazenamento da demonstração. Nenhuma configuração de ausência real foi alterada. Após a conferência, os rótulos de demonstração foram ajustados para não sugerirem execução no servidor.
- **Assinaturas:** assinatura fictícia Atlas cadastrada e definida como padrão para novos emails e respostas. Novo editor abriu com a assinatura separada do corpo, e a troca do remetente para Lume retirou a assinatura Atlas. Não foi enviada mensagem real com essa assinatura; a inclusão única no conteúdo de envio foi exercitada nos testes automatizados. Editor e cadastro usam texto simples.
- **Regressão real final:** duas contas preservadas, quatro calendários e nove listas. Em 16h48/16h49, painel de fontes mostrou Entradas, pastas/não lidos, calendários e tarefas atualizados, sem erro de fonte. Retornado ao ambiente real e à caixa conjunta, com pastas personalizadas recolhidas para manter as contas visíveis.
- **Permissões pendentes:** regras e ausência Microsoft/Google requerem novo consentimento individual (`MailboxSettings.ReadWrite` e `gmail.settings.basic`). O pedido foi apresentado ao usuário, mas não foi respondido durante esta entrega. O painel mostra o botão de autorização. Não foram criadas regras reais, ativadas ausências reais, concedidas permissões adicionais ou alteradas políticas corporativas. EWS/IMAP continuam sem servidor real adicional para validar essas operações.

Capturas/estados privados em `evidence/organization/`, excluídos do Git e com permissões restritas: criação das pastas reais, contadores, navegação Google, regra/ausência fictícias, assinatura no editor e fontes finais. O manifesto público contém os hashes dos artefatos. Consulte [ORGANIZACAO.md](ORGANIZACAO.md) para uso e diferenças por provedor.

Alterações existentes preservadas no checkout canônico `/Volumes/nvme/projects/intellitouch/orbita-mail`, branch `main`. Builds, testes, execução do aplicativo e empacotamento feitos nessa raiz. Sem stash, worktree, clone auxiliar, commit, push ou publicação. Não há código nem processo do projeto em checkout alternativo.
