# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/)
e [Versionamento Semântico](https://semver.org/lang/pt-BR/).

O corpo da seção de cada versão é publicado como nota da release no GitHub —
`scripts/changelog-section.sh` extrai, e o workflow de release anexa.

## [Não publicado]

## [0.2.0] — 2026-08-04

### Adicionado

- **Botão de enviar** (`↑`) no canto do campo, habilitado só quando há texto ou
  anexo. `Enter` continua funcionando igual.
- **Botão de abortar** — um quadrado vermelho que aparece apenas durante a
  execução, ao lado do enviar. Mesmo caminho do `⌘.`, que continua valendo.
  Durante uma execução os dois convivem: enviar vira correção (`steer`) e
  abortar interrompe.
- Ambos com estados de hover e pressionado desenhados, tooltip e rótulo de
  acessibilidade.
- `MENUAGENT_DIAGNOSE_BUSY=1` faz o `--diagnose` parar antes do `agent_end`,
  para renderizar o estado em execução.

### Alterado

- O indicador `↵` estático do campo virou o botão de enviar.

## [0.1.0] — 2026-08-03

Primeira versão. GUI nativa mínima para o `omp`, na barra de menus.

### Adicionado

- **Barra de menus e painel flutuante.** `NSStatusItem` com a marca da runa
  Algiz desenhada em runtime, e um `NSPanel` sem borda no estilo Spotlight,
  centralizado no terço superior da tela ativa. Sem presença no Dock
  (`LSUIElement` + `.accessory`). `Esc` fecha sem cancelar a tarefa em curso.
- **Atalho global** `Control + Option + Espaço` via Carbon `RegisterEventHotKey`,
  que não exige permissão de Acessibilidade.
- **Integração RPC com o `omp` 17.2.6.** `--mode rpc-ui`, negociação do
  protocolo v2, remontagem validada de `rpc_chunk`, correlação de comandos por
  `id` com timeout, e tratamento dos frames de sessão, ferramenta, compactação,
  retry e subagente.
- **Modelo fixado com verificação.** `opencode-zen/deepseek-v4-flash-free` com
  effort `max`, conferido contra o catálogo vivo. Modelo ausente gera erro
  claro em vez de troca silenciosa; effort não suportado cai no padrão do
  modelo com aviso.
- **Conversa em streaming** com Markdown inline, blocos de código
  monoespaçados, tool calls recolhidas por padrão e diffs coloridos com limite
  de linhas.
- **Solicitações interativas inline.** `extension_ui_request` (`select`,
  `confirm`, `input`, `editor`) renderizado na própria transcrição — aprovações
  de ferramenta aparecem com o comando visível.
- **Clipboard por `⌘V`.** Texto, PNG, JPEG, TIFF e PDF (convertidos para PNG),
  arquivos por caminho absoluto e pastas como workspace.
- **Comandos internos** `/key`, `/cd`, `/new`, `/abort`, `/status`.
- **Chave no Keychain.** `/key sk-…` grava direto, sem passar pelo histórico,
  log, `UserDefaults` ou pelo undo do campo; só os quatro últimos caracteres
  são ecoados.
- **Ciclo de vida econômico.** O `omp` só sobe no primeiro prompt e é encerrado
  após 10 min ocioso — nunca durante execução, ferramenta, compactação ou
  pedido pendente. Sem processos órfãos, inclusive após `kill -9` no app.
- **`--diagnose`**, que monta o item de status e o painel reais, roda o
  handshake, e renderiza o painel em PNG.
- **Empacotamento.** `scripts/build-app.sh`, `scripts/build-dmg.sh` (só
  ferramentas do próprio macOS) e `scripts/make-icon.swift`, que gera o ícone
  por código.
- **72 testes** cobrindo framing JSONL, remontagem de chunks, clipboard, a
  máquina de estados do agente e integração real com o `omp` sem gastar token.

### Segurança

- `--approval-mode write` em vez do padrão `yolo` do `omp`: leitura e escrita
  automáticas, mas tudo em tier `exec` (shell, browser, subagentes) pede
  aprovação.
- A chave só existe no Keychain e no ambiente do processo filho.
- URLs pedidas pelo agente não abrem sozinhas.

### Limitações conhecidas

- `deepseek-v4-flash-free` anuncia `input: ["text"]`, então imagens são
  recusadas com erro claro. O transporte de `ImageContent` está implementado e
  testado; falta rotear para um modelo de visão.
- Assinatura ad-hoc — o Gatekeeper bloqueia na primeira abertura.

[Não publicado]: https://github.com/raniere57/rune/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/raniere57/rune/releases/tag/v0.2.0
[0.1.0]: https://github.com/raniere57/rune/releases/tag/v0.1.0
