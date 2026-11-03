# Organização de email — Órbita 0.4

Abra o botão **Configurações de email** (engrenagem na barra superior) ou **Contas → Configurações de email…**. Escolha a conta antes de alterar qualquer configuração.

## Não lidos na tela

A barra lateral mostra não lidos por pasta, por conta (Entrada) e no total das Entradas. O cabeçalho separa **mensagens carregadas** de **não lidos na pasta**. São conceitos diferentes: o total consultado no servidor não se limita às páginas de 40 emails exibidas.

- Microsoft: contagens das pastas do Graph.
- Google: `messagesUnread` de cada marcador. Marcadores podem se sobrepor, portanto seus totais não são somados para representar a conta. O total conjunto soma apenas as Entradas das contas.
- Exchange próprio: `UnreadCount` por pasta EWS.
- IMAP: `STATUS (UNSEEN MESSAGES)` por pasta, sem buscar o corpo nem marcar como lido.
- POP3: marcações locais entre mensagens já carregadas, identificadas como contagem parcial. POP3 não fornece estado de leitura compartilhado.

`—` significa indisponível, não zero. `+` identifica total parcial. Arquivo no Gmail é uma busca, sem marcador equivalente que forneça um total exato. A ajuda do contador mostra a última consulta; falhas ficam em **Fontes e sincronização**, preservando o último valor conhecido. A atualização periódica continua acontecendo enquanto o app está ativo.

## Criar e usar pastas

Na aba **Pastas**, escreva o nome e clique em **Criar pasta**. O destino é criado na conta selecionada: pasta Microsoft/Exchange, mailbox IMAP ou marcador Gmail. A lista e a barra lateral permitem abrir seu conteúdo. **Pastas personalizadas** pode ser expandido na lateral; as contas continuam visíveis quando a seção está recolhida.

No leitor de uma mensagem, use **… → Mover para pasta**. O destino precisa pertencer à mesma conta. No Gmail, a operação adiciona o marcador de destino e retira Entrada e o marcador personalizado de origem, preservando os demais. IMAP exige suporte a MOVE.

POP3 não oferece pastas remotas. Renomeação, exclusão e escolha de pasta pai não estão incluídas nesta versão. Criar uma pasta não move mensagens existentes automaticamente.

## Regras de direcionamento

Na aba **Regras**, informe nome, uma ou mais condições e uma pasta personalizada de destino. As condições disponíveis são remetente, destinatário, assunto e corpo. Todas as condições preenchidas precisam corresponder. No Gmail, os critérios seguem a sintaxe e o comportamento de busca do serviço; os provedores não garantem semântica idêntica de substring.

O botão **Criar regra e ativar** configura uma regra no servidor para **novos recebimentos**. Não reprocessa o histórico. As regras anteriores são preservadas e mantêm sua prioridade; regras existentes que interrompem o processamento podem impedir que uma regra nova seja alcançada. As novas regras Microsoft/EWS são acrescentadas ao fim e interrompem o processamento após sua própria movimentação. O Gmail não fornece uma ordem equivalente para seus filtros.

As regras criadas pelo Órbita podem ser removidas após confirmação. Regras externas são mostradas para consulta e continuam sendo gerenciadas no provedor. O Gmail não possui nome de filtro na API; o nome dado no Órbita é associado ao ID e armazenado neste Mac. Sem esse registro local, o filtro aparece como existente no provedor.

Não há encaminhamento de mensagens para terceiros nesta implementação: a ação disponível é direcionar para pasta da própria conta. Escritas não têm repetição automática. Em uma falha de confirmação, atualize e confira o servidor antes de criar novamente.

- Microsoft usa Inbox messageRules, com permissão delegada `MailboxSettings.ReadWrite`. [API oficial](https://learn.microsoft.com/en-us/graph/api/mailfolder-post-messagerules).
- Google usa filtros Gmail, com `gmail.settings.basic`. [Filtros oficiais](https://developers.google.com/workspace/gmail/api/guides/filter_settings).
- Exchange próprio usa EWS InboxRules. `RemoveOutlookRuleBlob` é sempre **false**: não apagamos as regras locais do Outlook para forçar uma alteração. Se o Exchange recusar essa preservação, a configuração deve ser feita no Outlook ou com a TI. [Comportamento EWS](https://learn.microsoft.com/en-us/exchange/client-developer/web-service-reference/updateinboxrules-operation).

IMAP e POP3 não têm comandos para configurar essas regras no servidor. Nesta versão, essas contas usam o painel do provedor para regras; não há motor local que dependa do app aberto, nem conector ManageSieve/API particular.

## Assinaturas

Na aba **Assinaturas**, cadastre nome e texto, e escolha se deve ser o padrão em novos emails e/ou respostas daquela conta. É possível editar ou remover assinaturas e associar assinaturas importadas. A edição de uma assinatura genérica importada cria uma versão para a conta selecionada, preservando a original para outras contas.

Novos rascunhos recebem uma cópia da assinatura padrão. Ela aparece abaixo do corpo no editor e é incluída uma vez no conteúdo enviado. Alterar a assinatura cadastrada depois não modifica silenciosamente rascunhos já escritos. Ao trocar a conta remetente de um novo email, o padrão da nova conta substitui a seleção anterior. **Sem assinatura** remove apenas a assinatura daquele rascunho. O menu **Assinaturas e modelos** permite escolher outra; **Gerenciar…** abre o cadastro sem fechar o rascunho.

Assinaturas ficam **neste Mac**, em texto simples. Não alteram o padrão de assinatura do Outlook/Gmail web. Imagens, logotipos e editor HTML não estão incluídos. Modelos de texto importados continuam disponíveis.

## Respostas automáticas de ausência

Na aba **Respostas automáticas**, carregue a configuração existente, escolha ativação e período e escreva a mensagem. Microsoft/Exchange permitem mensagens para a organização e para remetentes externos, com público externo: nenhum, contatos ou todos. Google permite assunto, mensagem e restrições a contatos e/ou ao domínio Workspace. Google também permite início sem término; Microsoft/Exchange exigem fim para um período.

O salvamento com ativação apresenta uma revisão explícita. O provedor controla destinatários elegíveis, frequência e envio, inclusive com o Órbita fechado. Não é um robô SMTP que responde a toda mensagem. Configurações alteradas em outro cliente entre a leitura e o salvamento são recusadas quando detectadas; após a escrita, o aplicativo consulta o servidor para confirmar o resultado. Isso reduz sobrescritas, mas não substitui uma operação atômica de concorrência que essas APIs não fornecem.

As mensagens são salvas em texto simples; conteúdo HTML existente é apresentado como texto. Microsoft usa `automaticRepliesSetting`, Google usa VacationSettings e Exchange próprio usa OOF EWS. [Microsoft](https://learn.microsoft.com/en-us/graph/api/user-update-mailboxsettings), [Google](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.settings/updateVacation), [EWS](https://learn.microsoft.com/en-us/exchange/client-developer/web-service-reference/setuseroofsettings-operation).

IMAP/POP3 não têm configuração de ausência padronizada nesses protocolos. Use o painel do provedor nessas contas.

## Consentimento adicional

A conexão normal para email, agenda e tarefas continua com os escopos anteriores. **Regras e respostas automáticas** solicitam configuração adicional somente pelo botão **Autorizar regras e respostas automáticas**:

- Microsoft: `https://graph.microsoft.com/MailboxSettings.ReadWrite`.
- Google: `https://www.googleapis.com/auth/gmail.settings.basic`.

O fluxo usa a conta selecionada e valida a identidade antes de substituir a credencial. O consentimento é individual, sujeito às políticas da organização. Não existe consentimento administrativo automático para todos os funcionários. Credenciais existentes não são lidas ou expostas na interface. Após autorizar, o painel consulta novamente a disponibilidade das funções.

Na entrega inicial da 0.4, essa ampliação de acesso foi solicitada ao usuário e permanece pendente. Nenhuma regra nem ausência real foi ativada. Não confunda a presença da tela ou um teste de fixture com configuração efetiva da conta real.

## Validação desta entrega

Foram consultados os totais reais das duas Entradas e criadas pastas controladas **Órbita - Validação 0.4** no Microsoft e no Google. Na conferência de 16h34: 149.127 não lidos Intellitouch + 11.675 2safe = 160.802, com apenas 80 mensagens carregadas na lista. São valores pontuais, que mudam com novos recebimentos e ações de leitura.

Na demonstração isolada: pasta criada, regra por três condições salva/listada, ausência com período salva, assinatura cadastrada e aplicada ao novo email, retirada automaticamente ao trocar de conta. Nenhuma mensagem real foi enviada por esses exercícios. As regras fictícias ficam apenas cadastradas, sem um motor simulado de recebimento.

Testes automatizados e capturas estão relacionados em [VALIDACAO.md](VALIDACAO.md). A validação de configurações remotas Microsoft/Google depende do consentimento adicional; EWS/IMAP continuam sem servidor real adicional fornecido pela TI.
