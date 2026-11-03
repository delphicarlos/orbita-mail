# Design — Órbita Mail

## Contexto físico
Uma pessoa alterna email e reuniões ao longo do dia no Mac, em escritório iluminado; o aplicativo acompanha a aparência do sistema para preservar conforto ao anoitecer.

## Estratégia
Restrained: superfícies nativas, tipografia SF do sistema e um acento discreto. Painéis e listas utilitárias; cores de conta apenas como identificação adicional ao nome.

## Tokens
Âncora de marca: oklch(0.55 0.16 0); seleção usa tom compatível com contraste e controles nativos. Superfície clara: oklch(1 0 0); tinta: oklch(0.20 0 0); superfície escura e tinta invertida vêm das cores semânticas do macOS. A implementação converte a âncora OKLCH para sRGB para uso em SwiftUI. Estados de erro, aviso e sucesso usam papéis semânticos do sistema.

## Estrutura
Barra lateral: Email, Agenda, Tarefas; todas as contas e filtro individual; pastas. Email: lista com busca + leitura; botões contextuais e editor em folha. Agenda: navegação por período, filtros de conta/fontes, dia/semana/mês/lista, painel de tarefas. Integrações: configuração e conexão por provedor com estado claro.

## Estados
Primeiro uso sem dados, carregamento, cache desatualizado, erro por fonte, operação em andamento, demonstração claramente identificada e confirmação após reconciliação. Não mostrar sucesso ao falhar uma escrita.
