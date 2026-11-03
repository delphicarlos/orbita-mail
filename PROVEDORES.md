# Conectar provedores e usar na empresa — Órbita 0.3

Em **Contas → Outro provedor…**, escolha o serviço habilitado pelo provedor ou pela TI. O aplicativo é um cliente: não hospeda caixas de email e não altera políticas do servidor.

| Conexão | Email | Agenda e tarefas | Autenticação nesta versão |
| --- | --- | --- | --- |
| Microsoft 365 / Outlook | Microsoft Graph | Microsoft Calendar e To Do | OAuth delegado por usuário |
| Google / Gmail | Gmail API | Calendar e Tasks APIs | OAuth por usuário |
| IMAP + SMTP | Entrada e pastas padrão, leitura/anexos, lido/sinalizador, envio, respostas, CC/CCO | CalDAV opcional | Usuário/senha ou senha de aplicativo, SASL disponível no curl do macOS; TLS ou STARTTLS obrigatório |
| POP3 + SMTP | Entrada remota e envio; Enviados, rascunhos e marcações locais | CalDAV opcional | Usuário/senha ou senha de aplicativo, TLS ou STARTTLS obrigatório |
| Exchange próprio | EWS para email, pastas padrão e envio | Calendários e tarefas EWS; aceitar/talvez/recusar | NTLM ou usuário/senha sobre HTTPS válido; Exchange 2013 SP1 ou posterior com EWS habilitado |

“Qualquer provedor” significa **provedores compatíveis com esses protocolos e métodos de autenticação**. Não significa todos os serviços proprietários nem todas as políticas de cada empresa. Não implementamos ActiveSync, MAPI, JMAP, Kerberos integrado, CardDAV ou OAuth personalizado para servidores próprios. iCloud, Yahoo e outros podem funcionar por IMAP/SMTP e eventualmente CalDAV, mas ainda não foram validados com contas desses serviços.

## Dados para pedir à TI

- Endereço da conta e usuário de autenticação, que podem ser diferentes.
- Para IMAP/POP3: servidor, porta e modalidade TLS. Valores comuns: IMAP 993/TLS ou 143/STARTTLS; POP3 995/TLS ou 110/STARTTLS.
- SMTP: servidor, porta e modalidade TLS; normalmente 465/TLS ou 587/STARTTLS. Usuário/senha podem ser diferentes dos de recebimento.
- Exchange próprio: URL EWS, por exemplo `https://mail.empresa.example/EWS/Exchange.asmx`, método NTLM ou senha e formato do usuário. NTLM aceita `DOMINIO\usuario`.
- Agenda fora de EWS/Google/Microsoft: URL HTTPS CalDAV e credenciais. O servidor deve anunciar suporte a VEVENT e/ou VTODO.
- Necessidade de VPN, protocolos liberados, restrições de envio e certificado confiável instalado conforme a política da TI.

**A senha deve ser preenchida no aplicativo. Não a envie pelo chat.** O botão **Testar e conectar** autentica recebimento e SMTP, sem enviar email de teste. Para EWS, confirma acesso à Entrada; os recursos adicionais são consultados na sincronização, e falhas aparecem por fonte. A conta só é gravada após a verificação inicial. A configuração pode ser revisada em **Servidores…**; campos de senha vazios mantêm a senha anteriormente salva.

## Comportamento dos protocolos

**IMAP:** usa UID e UIDVALIDITY para identificar mensagens, e BODY.PEEK para ler sem marcar como lido. Busca/carrega as 40 mensagens de UID mais recente por página. Detecta pastas padrão por atributos e nomes comuns; a TI pode ajustar os nomes manualmente. Movimentação requer IMAP MOVE. Não há fallback com EXPUNGE global, nem criação automática de pastas. A cópia em Enviados pode ser desativada se o SMTP já a criar. Se SMTP aceitar o envio e a cópia IMAP falhar, o rascunho fica sem confirmação; não reenvie antes de conferir.

**POP3:** mantém as mensagens no servidor e exige identificadores UIDL estáveis. TOP carrega cabeçalhos; se o servidor recusar esse comando opcional, tenta RETR, com limite de 32 MB por resposta. Sincroniza 20 mensagens por página e confere se as posições não mudaram durante a leitura. Não executa DELE. Lido/sinalizador, Enviados e rascunhos ficam no Mac, sem sincronização dessas marcações com outros clientes.

**Exchange próprio:** usa EWS para listar fontes, expandir eventos no intervalo, responder a convites e concluir/reabrir tarefas. Escritas usam a versão do item quando aplicável, e o aceite é consultado depois. NTLM requer suporte do servidor; autenticação integrada Kerberos e login moderno personalizado do Exchange próprio não foram implementados. Exchange Online deve usar o botão Microsoft/OAuth; a descontinuação de EWS anunciada pela Microsoft para Online não abrange o Exchange próprio. [Referência Microsoft](https://devblogs.microsoft.com/microsoft365dev/retirement-of-exchange-web-services-in-exchange-online/).

**CalDAV:** descobre calendários/listas, lê eventos e VTODO, e conclui/reabre tarefas com ETag. Respostas a convites exigem `calendar-schedule` e agendamento realizado pelo servidor; nesta versão ficam limitadas a convites sem recorrência. Convites recorrentes são somente leitura. Séries precisam ser expandidas pelo servidor; uma resposta incompleta gera erro, preservando o cache. As alterações mantêm os demais participantes e propriedades do objeto. Redirecionamentos e descoberta para outra origem não encaminham as credenciais: informe a URL final correta. Email IMAP/POP sem CalDAV não ganha agenda artificialmente.

O conteúdo completo de mensagens/anexos tem limite de 32 MB por resposta e os anexos enviados somam até 2,5 MB. O editor continua em texto simples. Pasta personalizada, pesquisa remota completa, criação/edição de eventos e novas tarefas permanecem fora desta versão.

## Importação e uso interno

O assistente do Outlook importa endereços e, quando disponíveis, nomes de servidor, assinaturas e modelos em texto. Escolha o provedor correto para cada conta pendente: Exchange em nuvem, Exchange próprio, IMAP ou POP3. Credenciais/sessões do Outlook não são copiadas; cada colaborador precisa autenticar suas próprias contas.

Cada usuário do macOS tem armazenamento e Keychain próprios. Não existe cadastro central de funcionários, compartilhamento automático de senhas ou sincronização de configurações entre Macs. A agenda conjunta agrega as fontes autorizadas das contas conectadas nesse Mac; não concede acesso às agendas de todos os funcionários.

O pacote atual é local para Apple Silicon/macOS 14+, executado neste Mac. Para distribuição interna ampla ainda faltam assinatura Developer ID/notarização, validação em outros Macs, configuração do Google para uso contínuo e aprovações corporativas. O Google está em modo Testando e esses refresh tokens expiram em sete dias. A organização de cada cliente pode exigir aprovação administrativa Microsoft; usar IMAP/EWS não contorna essa exigência. [Expiração Google](https://developers.google.com/identity/protocols/oauth2#expiration), [consentimento Microsoft](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/configure-user-consent).

## Evidência disponível

A versão 0.3 tem testes de conectores com respostas simuladas e testes reais de transporte contra servidores TLS descartáveis **somente em loopback**, com credenciais fictícias. Os certificados de fixture são temporários, explicitamente confiados apenas pelo executável de teste, sem alterar o Keychain ou permitir ignorar certificados no aplicativo. O teste também verifica rejeição de certificado não confiável.

O teste encontrou truncamento de FETCH no curl 8.7.1 do macOS. O caminho IMAP FETCH passou a usar a libcurl do sistema para TLS/STARTTLS/autenticação e um enquadramento por tamanho dos literais. Isso evita depender da saída truncada de comandos customizados da CLI. Não foi instalado curl externo. [Código oficial do curl 8.7.1](https://github.com/curl/curl/blob/curl-8_7_1/lib/imap.c), [API connect-only](https://curl.se/libcurl/c/CURLOPT_CONNECT_ONLY.html).

Ainda não conectamos uma conta IMAP/POP3/EWS/CalDAV real. Os envios e aceites já comprovados com contas reais foram feitos pelos conectores Microsoft/Google na etapa anterior. Veja [VALIDACAO.md](VALIDACAO.md) e [FEATURES.md](FEATURES.md).
