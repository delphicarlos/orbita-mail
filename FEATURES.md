# Matriz da primeira implementação

“Implementado” significa código e fluxo local disponíveis. A validação real de 03/11/2026 abrangeu as contas Intellitouch e 2safe nos fluxos abaixo. Os demais recursos não foram certificados por esses testes.

| Área | Estado local | Validação / pendência |
| --- | --- | --- |
| Aplicativo Mac | Implementado, pacote arm64 | Build debug/release e abertura neste Mac; outros Macs/versões pendentes. |
| Contas Microsoft/Google | OAuth registrado e contas conectadas | Intellitouch/2safe sincronizam após reiniciar o app. Expiração/revogação e outras organizações não testadas; Google em teste exige nova autorização após sete dias. |
| Importação de contas Outlook | Assistente com seleção e autorização individual posterior | JSON conferido com três contas reais; duas posteriormente conectadas por OAuth. Leitura direta pela automação pública implementada, mas não validada. Sem senhas, tokens ou mensagens. |
| Assinaturas e modelos | Cadastro/edição/remoção de assinaturas e padrão por conta na 0.4; modelos importados | Assinatura aplicada no editor e retirada ao trocar de conta na demonstração. Snapshot local em rascunhos; texto simples, sem alterar assinatura no provedor. |
| Várias contas, filtro e caixa unificada | Implementado | Duas contas reais, envio com origem correta em cada direção e persistência após reiniciar. |
| Não lidos na tela | Implementado na 0.4 | Contagens reais de Entrada Microsoft/Google conferidas, separadas dos 80 emails carregados. Parcial/indisponível e POP3 local identificados. |
| Pastas padrão e personalizadas | Criação, navegação e movimentação implementadas na 0.4 | Pasta de validação criada nas duas contas reais; Microsoft/Google/IMAP/EWS com conectores. POP3 sem pastas remotas. Renomeação/exclusão/pasta pai pendentes. |
| Paginação de email | Implementada, 40 por página (POP3: 20) | Atualização reinicia as páginas recentes; delta/consistência de todo histórico pendentes. |
| Busca | Local nas mensagens carregadas | Busca remota completa pendente. |
| Leitura texto/HTML | Implementada com isolamento | Conteúdo fictício renderizado no app; anexos reais pendentes. |
| Envio, respostas, CC/CCO | Implementados | Dois envios reais pelo Órbita com recebimento confirmado nas caixas opostas. Responder/encaminhar e CC/CCO reais ainda não exercitados. |
| Anexos | Envio até 2,5 MB e download sob demanda | Não copia automaticamente anexos ao encaminhar; anexos grandes pendentes. |
| Rascunhos | Persistência local implementada | Não sincroniza rascunhos criados no app com o provedor; edição de rascunho remoto pendente. |
| Lido, sinalizador, arquivo, spam, lixeira | Ações implementadas | Exercícios locais/fixtures; confirmação E2E real pendente. |
| Agenda individual/conjunta | Implementada | Duas contas reais, quatro calendários e nove listas; convite e tarefas controladas visíveis juntos com origem preservada. |
| Dia, semana, mês e lista | Implementados | Conferência visual no aplicativo. |
| Calendários e listas de tarefas | Paginação implementada | Quatro calendários e nove listas reais consultados sem erros de fonte na conferência final. |
| Recorrências/cancelamentos | Expansão por período e snapshots transacionais | Consultas/armazenamento testados; séries reais pendentes. |
| Fusos e eventos de dia inteiro | Implementados com limites | IANA/UTC e conjunto inicial Windows; personalizados desconhecidos geram erro da fonte. |
| Convites aceitar/talvez/recusar | Implementados | Talvez → Aceitar na conta Google, conferidos no organizador Microsoft; Sem resposta → Aceitar na conta Microsoft, conferido no organizador Google (“2 convidados, 2: sim”). Todas as respostas acionadas pelo Órbita. Recusa real ainda não exercitada. |
| Resposta sem confirmação | Estado persistente e bloqueio implementados | Sem retry automático; recusa Microsoft removida pode continuar pendente de conferência. |
| Tarefas datadas/sem data | Implementadas | Tarefa controlada de cada provedor criada no site, sincronizada, concluída/reaberta pelo Órbita e conferida novamente no site. Google sem hora sincronizada. |
| Criação/edição de compromissos e tarefas | Pendente | Fora da fatia atual; permanece no objetivo do produto completo. |
| Calendário de outras pessoas/delegação | Pendente | Esta entrega agrega calendários listados das próprias contas autorizadas. |
| Contatos/Pessoas | Pendente | Sem módulo de contatos nesta versão. |
| Conversas agrupadas, Destaques/Outros, perfis | Pendente | Email inicial lista mensagens; filtro individual de conta disponível. |
| Editor rico e envio agendado | Pendente | Editor em texto simples; assinaturas e modelos importados podem ser inseridos pelo menu. |
| Regras de direcionamento | Implementadas na 0.4 para Microsoft/Google/EWS | Remetente, destinatário, assunto/corpo e pasta da própria conta. Fixtures e cadastro na demonstração; autorização OAuth adicional e regra real pendentes. Regras anteriores preservadas; IMAP/POP usam painel do provedor. |
| Respostas automáticas | Implementadas na 0.4 para Microsoft/Google/EWS | Ativação/período/público/mensagens, consulta antes/depois da escrita. Fixtures e demonstração; autorização adicional e teste remoto pendentes. Nenhuma ausência real ativada. |
| Recibos, S/MIME, retenção | Pendente | Depende também de recursos/políticas do provedor. |
| IMAP/SMTP | Implementado na 0.3 | TLS/STARTTLS, pastas padrão configuráveis, UIDVALIDITY, PEEK, MOVE e cópia em Enviados; testes de fixtures/loopback. Conta real adicional pendente. |
| POP3/SMTP | Implementado na 0.3 | Entrada remota por UIDL; marcações/Enviados locais, sem DELE; testes de fixtures/loopback. Conta real pendente. |
| Exchange próprio EWS | Implementado na 0.3 | Email, agenda/tarefas, RSVP, NTLM ou senha/HTTPS; fixtures. Servidor real da TI pendente. Não inclui ActiveSync/MAPI/Kerberos. |
| CalDAV opcional | Implementado na 0.3 com limites | Eventos/VTODO, conclusão de tarefas e RSVP sem recorrência quando servidor oferece scheduling; ETag e participantes testados por fixtures. Servidor real pendente. |
| iCloud/Yahoo/outros por protocolos | Compatibilidade possível, não certificada | Exige protocolos e autenticação suportados e habilitados; sem teste com essas contas. Ver PROVEDORES.md. |
| Arquivo morto online Microsoft | Limitação de API | Graph não oferece acesso ao in-place archive. Arquivo comum é diferente. |
| Notificações, lembretes e calendário na barra de menus | Pendente | Atualização quando app ativo, sem daemon para Mac desligado. |
| Assinatura de distribuição e notarização | Pendente | Pacote usa assinatura ad hoc local. |

Referência funcional original e capturas do Outlook: `/Users/carloseduardocabraldasilva/.codex/visualizations/2026/11/03/01a1a12e-4157-7cf1-a122-5d48126e87e6/outlook-analysis/ANALISE.md`.
