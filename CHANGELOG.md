# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/)
e [Versionamento Semântico](https://semver.org/lang/pt-BR/).

O corpo da seção de cada versão é publicado como nota da release no GitHub —
`scripts/changelog-section.sh` extrai, e o workflow de release anexa.

## [Não publicado]

### Documentação

- **A RAM ociosa está medida errada no README desde sempre — corrigida para
  22 MB.** Os números anteriores (54 MB, depois 29 MB) vinham de leituras de `ps`
  em momentos diferentes da estabilização, e nenhuma das duas media a coisa
  certa: o RSS inclui as páginas limpas e compartilhadas de AppKit, SwiftUI e
  Foundation, que todo app nativo mapeia e nenhum paga sozinho. O valor honesto é
  o *physical footprint* — o que o Monitor de Atividade mostra —, obtido com
  `vmmap --summary`. Ele é **22 MB**; o RSS do mesmo processo é 93 MB.

  Com o mesmo método, no mesmo boot, a 0.8.1 mede 22,0 MB e a 0.11.0 mede
  22,2 MB: as três levas de auditoria custaram 0,2 MB somadas.

## [0.11.0] — 2026-08-08

Terceira e última leva da auditoria: capacidades. Continua sem timer, sem
polling e sem processo extra.

### Adicionado

- **O app sobrevive à aposentadoria do modelo.** Um id de modelo hardcoded é um
  ponto único de falha que o app não consegue consertar em runtime: no dia em que
  o provedor retirar o `deepseek-v4-flash-free`, toda instalação fica morta até
  sair uma release. Agora, se o modelo configurado sumir do catálogo, o boot cai
  no modelo **gratuito** com maior janela de contexto que o provedor ainda
  oferece — hoje seriam nove candidatos, com o `nemotron-3-ultra-free` (1M de
  contexto) na frente — e diz isso em um aviso visível. Um modelo pago nunca é
  escolhido: uma retirada de catálogo não pode virar uma fatura surpresa. Sem
  nenhum modelo grátis, o boot continua falhando como antes.

- **Arrastar e soltar.** Arquivos, pastas e imagens agora podem ser arrastados
  para qualquer parte do painel — o gesto mais natural do macOS, e o único
  caminho de entrada que faltava, porque todo o pipeline de anexos já existia
  para o `⌘V`. Uma pasta solta vira o workspace, igual ao paste. TIFF e outros
  formatos são reconvertidos para PNG.

- **Abrir no login**, no menu de clique direito do ícone. `SMAppService.mainApp`
  não usa app auxiliar, não usa daemon e não deixa processo nenhum rodando — o
  `launchd` faz o trabalho.

- **Notificação quando a tarefa termina com o painel fechado.** Complementa a
  marca no ícone: uma cobre quem olha para a barra, a outra cobre quem não olha.
  A autorização é *provisional*, então nunca aparece um diálogo pedindo
  permissão — a primeira notificação chega silenciosamente na Central. Abrir o
  painel limpa a notificação.

### Notas

- `/compact` **já funcionava** por encaminhamento, verificado contra o `omp`
  real: qualquer `/comando` desconhecido vai como prompt e o `omp` responde com
  `command_output`. A auditoria apontou o comando RPC `compact` como não usado —
  é verdade, mas a necessidade do usuário já estava atendida, então não há código
  novo aqui.

## [0.10.0] — 2026-08-08

A segunda leva da auditoria: a interface. Tudo aqui custa zero em RAM ociosa —
são estados booleanos por bloco visível e valores que o app já rastreava.

### Adicionado

- **Botão de copiar nos blocos de código**, revelado no hover. Era a saída mais
  copiada de um agente de código e não tinha nenhuma affordance: só dava para
  selecionar à mão, dentro de um `ScrollView` horizontal onde o arrasto disputa o
  eixo com a rolagem. Vale também para a saída de comandos. O símbolo vira um
  ✓ por 1,5 s.

- **Marca de concluído no ícone da barra.** O fluxo central do app é disparar uma
  tarefa e fechar o painel — e até agora "terminou" e "nunca rodou" eram
  visualmente idênticos, então a única forma de saber era reabrir. Agora o ícone
  vira um `checkmark.circle` quando um turno termina com o painel fechado, e
  limpa ao reabrir.

- **"Tentar de novo" na falha terminal.** Só aparece na falha que encerra a
  conversa, e só quando a mensagem pode ser reproduzida: um turno com anexo não
  oferece, porque o `UserTurn` guarda apenas um resumo do arquivo e o reenvio
  seria uma requisição diferente da que falhou.

- **Indicador de contexto no rodapé.** O `contextPercent` já era rastreado a cada
  frame RPC e só aparecia com `/context`. Agora surge como `72% ctx` a partir de
  60%, laranja acima de 85%. Abaixo do limiar não renderiza nada.

### Alterado

- **A rolagem automática respeita quem está lendo.** Cada token puxava a tela
  para o fim, o que tornava impossível reler algo durante uma resposta longa.
  Agora o texto em streaming só arrasta a view quando ela já está no fim (com 40
  pt de folga); um item novo sempre arrasta, porque é algo que o usuário pediu ou
  precisa ver.

- Linhas de tool call ganharam estado de hover, e a prosa do assistente ganhou
  entrelinha — 720 pt é uma linha longa para 13 pt de texto.

## [0.9.0] — 2026-08-08

Uma auditoria de seis frentes sobre o código — cada bug apontado passou por uma
verificação adversarial contra o próprio código antes de virar correção. O que
sobreviveu está aqui.

### Corrigido

- **`⌘.` ou `/abort` sem nada rodando travava o app em "Abortando…" para sempre.**

  O OMP não emite `agent_end` para um turno que já terminou, e nada mais limpava
  o estado. Como todas as saídas (o reaper de ociosidade, a troca de modo, a
  troca de sessão) se recusam a rodar enquanto o estado está ocupado, o app
  ficava preso até o próximo prompt. Agora abortar exige um turno em andamento, e
  um abort que falha restaura o estado que interrompeu.

- **`⌘C` roubava a seleção do histórico.**

  O painel só enxerga seleção de `NSTextView`; a do SwiftUI (`.textSelection`) é
  invisível para ele. Quem selecionava um trecho da conversa e apertava `⌘C`
  recebia a resposta inteira na área de transferência. `⌘C` voltou a ser do
  sistema; copiar a última resposta agora é **`⌘⇧C`**. Os modificadores também
  passaram a ser exatos — `⌘⌥K` não é mais engolido pelo painel.

- **`⌘K` com histórico fazia o painel sumir atrás do diálogo de confirmação.**

  O `NSAlert` tira o foco do painel, que é exatamente o gatilho do auto-fechar.
  O usuário confirmava um alerta de uma janela que tinha acabado de desaparecer.

- **Modo claro.** O painel é pintado sobre `.ultraThinMaterial`, que é
  adaptativo — mas dezesseis cores de chrome eram brancos e pretos fixos. No modo
  claro os chips perdiam o contorno, o popup de comandos ficava escuro sobre
  fundo claro e os blocos de código viravam lajes escuras com texto escuro. Todas
  passaram a derivar de `Color.primary`. `--diagnose` agora aceita
  `RUNE_DIAGNOSE_APPEARANCE=light|dark` para renderizar os dois temas.

- **Corrida no restart rápido.** `shutdown()` esperava o processo morrer, mas
  lançar um novo exige o slot liberado — e o macOS marca o processo como morto
  até ~17 ms antes de entregar o handler que libera o slot (medido nesta
  máquina). Uma troca de modo reinicia dentro dessa janela e falhava com
  `alreadyRunning`. Some um token de geração nos pipes, para que bytes atrasados
  do processo anterior não sejam costurados no stream do novo.

- **`/new` e `/cd` no meio de um turno** repovoavam o histórico recém-limpo com
  os deltas ainda em voo, e um encerramento deliberado era reportado como queda
  do OMP. Os dois agora abortam antes, e a saída limpa deixou de virar erro.

- **`Shift + Enter` corrompia entrada por IME** (chinês, japonês, coreano): a
  interceptação ignorava o texto em composição, e o Return que confirmava o
  candidato virava quebra de linha no meio dele.

- **`⌃⌥Space` pode ser roubado pelo macOS** (troca de fonte de entrada, quando há
  mais de um teclado ativo). `RegisterEventHotKey` retorna sucesso mesmo assim,
  então a falha era silenciosa. Agora o app detecta e avisa no log e no
  `/status`.

### Performance

- **Texto streamado deixou de ser O(n²).** Cada delta mutava `items`, e cada
  mutação custava duas passadas pela resposta inteira: o copy-on-write duplicava
  a string acumulada e a view reparseava tudo como markdown. Uma resposta de
  100 KB copiava ~100 MB de bytes na main actor. Os deltas agora são acumulados e
  gravados uma vez por quadro (~80 ms), e a gravação tira o item do array antes
  de concatenar, para que o `+=` aconteça no lugar.

- **Argumentos de ferramenta deixaram de crescer sem teto.** `write`/`edit`
  carregam o corpo inteiro do arquivo, retido pela sessão toda enquanto a tela
  nunca mostra mais que o limite de renderização. Um run tocando vinte arquivos
  de 50 KB segurava megabytes de texto que ninguém leria. Agora são cortados na
  construção.

- **Escrita no stdin saiu da main thread.** O buffer de um pipe é ~64 KB, então
  um prompt com imagem sempre excedia e bloqueava a interface até o OMP drenar —
  justamente quando ele está ocupado numa ferramenta longa.

## [0.8.1] — 2026-08-06

### Corrigido

- **`Shift + Enter` quebrava linha? Não — enviava a mensagem.**

  O `StandardKeyBinding.dict` do AppKit não tem entrada para `Shift + Return`:
  ele cai no mesmo `insertNewline:` de um Return puro, e o modificador já não
  existe quando o `doCommand(by:)` roda. O código roteava a quebra de linha por
  `insertNewlineIgnoringFieldEditor:`, que na verdade está mapeado em
  **`Option + Return`** (`~\r`) — então esse caminho nunca era acionado por
  Shift, e toda quebra de linha virava um envio.

  A separação passou para o `keyDown(with:)`, onde o modificador ainda está no
  evento. `Option + Enter` continua quebrando linha, e o Enter puro continua
  enviando. Vale para o Enter do teclado numérico também.

## [0.8.0] — 2026-08-04

### Adicionado

- **Imagens funcionam.** Cole com `⌘V` e pergunte — em Plan e em Build.

  O modelo principal não enxerga (`input: ["text"]`), mas o `omp` já resolve
  isso: para um modelo sem entrada de imagem ele expõe a ferramenta
  `inspect_image`, que delega ao modelo em `modelRoles.vision`. Rune só precisa
  nomear o modelo — nada de roteamento próprio. O papel vai num overlay de
  config gerado a cada lançamento e passado com `omp --config`.

  O modelo de visão é **`opencode-zen/mimo-v2.5-free`**: aceita
  `["text", "image"]`, 200K de contexto e **custo zero**, então a conta continua
  em nada.

  Verificado de ponta a ponta com modelos reais: um PNG escrito `ZEPHYR 907`,
  em diretório novo e com texto inédito para o modelo, volta como `ZEPHYR 907`
  em modo Plan.

### Alterado

- Uma imagem só é recusada quando o modelo ativo não a lê **e** não há modelo de
  visão configurado. Antes bastava a primeira condição, o que bloqueava um
  caminho que funciona.
- 6 testes novos (144 no total), incluindo um que confirma que o lançamento real
  do `omp` recebe o overlay — se ele parar de ser passado, imagens quebram em
  silêncio.


## [0.7.2] — 2026-08-04

### Alterado

- **Documentação auditada contra o código**, em vez de remendada. A árvore de
  arquivos, a tabela de suítes de teste, o índice e as limitações estavam
  atrasados em várias versões. Capturas de tela regeradas com o layout atual.
- **Correção de medição:** a RAM ociosa é **29 MB**, não os 54 MB que ficaram
  no README por duas versões. O número antigo foi lido antes de o app assentar.
  Volta a caber na meta de 50 MB do escopo original.
- Limitações e próximos passos reescritos: `command_output` já foi resolvido na
  0.5.0 e continuava listado como pendente.


## [0.7.1] — 2026-08-04

### Corrigido

- **A tela podia mostrar uma conversa que o modelo não tinha.** Trocar de
  diretório limpava a sessão do `omp` mas deixava o histórico no painel, então
  a próxima mensagem começava do zero enquanto a conversa anterior continuava
  visível — o agente parecia ter esquecido tudo. O transcrito agora sai junto
  com a sessão, com um aviso dizendo que o contexto anterior não vem.
- **`switch_session` cancelado era tratado como sucesso.** A resposta é
  `success: true` com `data.cancelled`, e eu ignorava o `cancelled` — o mesmo
  resultado: painel com histórico, modelo sem nada.
- **A sessão carregada passa a ser conferida.** Depois de trocar, um `get_state`
  verifica que o `sessionFile` é mesmo o pedido. Divergência vira aviso visível
  e conversa nova, em vez de silêncio.

### Adicionado

- **Indicador de atividade no transcrito.** Três pontos animados e o estado
  atual (`Pensando…`, `Executando bash…`, `Compactando o contexto…`) logo abaixo
  da sua mensagem, enquanto o agente trabalha e ainda não escreveu nada. Some
  sozinho quando o texto começa a streamar, para não competir com ele. Antes o
  painel ficava imóvel por vários segundos — em `max` são muitos — e a resposta
  aparecia de uma vez.
- `RUNE_DIAGNOSE_WAITING=1` renderiza esse estado no `--diagnose`.
- 4 testes novos (138 no total) travando que tela e modelo não divergem.


## [0.7.0] — 2026-08-04

### Alterado

- **Nenhum dos dois modos pede permissão.** Os dois sobem com
  `--approval-mode yolo`; a segurança vem de quais ferramentas existem, não de
  caixas de diálogo.
  - **Plan** não consegue modificar nada porque as ferramentas de escrita e
    execução não estão no registro. Verificado contra o `omp` real: o
    `get_state` lista exatamente as oito de leitura.
  - **Build** é autônomo por escolha — edita, roda shell e lança subagentes sem
    confirmar.

  Antes o app usava `--approval-mode write` nos dois. Parecia prudente e não
  era: o `omp` trata toda ferramenta sem declaração de `approval` como tier
  `exec`, e `read`, `grep`, `glob` e companhia não declaram nenhuma — então até
  **ler um arquivo pedia permissão**, num modo cuja função inteira é ler.

  > ⚠️ Em `yolo` o guarda de padrões críticos do `omp` (`rm -rf /`, fork bombs,
  > baixar-e-executar, escrita em `/etc/passwd`, desligar a máquina) não é
  > aplicado. `bash.patterns` na config do `omp` continua valendo em `yolo` para
  > quem quiser um piso mínimo sem os prompts gerais.

- A política de aprovação virou propriedade de `AgentMode`, junto com a
  allow-list — as duas decisões que definem um modo agora moram no mesmo lugar.
- 4 testes novos (134 no total) travando que nenhum modo prompta e que Plan
  continua sem ferramenta mutante.


## [0.6.2] — 2026-08-04

### Corrigido

- **O histórico da conversa sumia ao reabrir o painel depois de reiniciar o
  app.** A conversa só era reconstruída durante o boot do `omp`, e o boot só
  acontece no primeiro prompt — então o painel abria vazio mesmo com a sessão
  gravada em disco e listada no seletor de conversas.

  Agora a conversa é lida direto do transcrito (`~/.omp/agent/sessions/**.jsonl`)
  no launch e ao retomar uma sessão, **sem precisar subir o `omp`**. Aparece na
  hora, e o processo continua subindo só quando há trabalho de verdade.

  Blocos de raciocínio continuam fora da tela. Uma chamada de ferramenta sem
  resultado registrado é marcada como interrompida em vez de ficar com um
  spinner eterno.

### Adicionado

- 14 testes novos (130 no total), incluindo uma suíte que roda contra os
  transcritos reais desta máquina — as fixtures sintéticas codificam a minha
  leitura do formato, essa suíte confere a leitura contra o que o `omp` de fato
  escreveu. Ela se pula sozinha onde não há sessões.


## [0.6.1] — 2026-08-04

### Corrigido

- **Clicar no ícone da barra de menus não abria o painel logo após o launch** —
  só o `Control + Option + Espaço` abria, e a partir daí o ícone passava a
  funcionar. Três causas somadas:
  - O painel usava `hidesOnDeactivate`, que amarra a visibilidade ao estado de
    ativação do app. Clicar num `NSStatusItem` **não ativa o app**, então o
    AppKit ordenava o painel à frente e o escondia no mesmo instante. Agora a
    dispensa é por perda de foco (`resignKey`), que é o comportamento que um
    launcher realmente quer e que a classe controla.
  - `NSApp.activate(ignoringOtherApps:)` está obsoleto e o macOS 14+ costuma
    recusá-lo quando o pedido vem de um app que não está em primeiro plano — ou
    seja, todo clique no ícone. Trocado por `NSApp.activate()`.
  - A ação do ícone rodava dentro do rastreamento de mouse do próprio botão. O
    atalho global sempre passou pela fila principal antes de agir, e era só por
    isso que ele funcionava quando o clique não. O clique agora faz o mesmo.
- O painel passa a ser construído no launch, não no primeiro clique: montar a
  janela e deixar o SwiftUI fazer o layout custava um frame, pago justamente
  dentro da primeira interação.

### Alterado

- Os seletores de pasta e de conversa suspendem a auto-dispensa via
  `FloatingPanel.keepingVisible`, em vez de mexer no `hidesOnDeactivate`.
- 7 testes novos (116 no total) travando a configuração do painel — o valor de
  `hidesOnDeactivate` agora falha o build se alguém reativá-lo.


## [0.6.0] — 2026-08-04

### Alterado

- **UX do compositor refeita.** Havia duas fileiras de controles sem linha de
  base comum: enviar/abortar ao lado do texto, chips numa linha separada
  abaixo, com alturas diferentes. A assimetria era estrutural, não de espaçamento.
  Agora é uma fileira só — contexto à esquerda, ações à direita, todos com a
  mesma altura e o mesmo centro. Geometria centralizada em `ComposerMetrics`,
  para nada voltar a divergir por um ou dois pontos.
- README reescrito: o que o projeto é, de onde vem cada peça e por que a
  separação app/agente é a decisão que sustenta o resto.
- Adicionada licença MIT.


## [0.5.0] — 2026-08-04

### Corrigido

- **`/session`, `/context`, `/usage`, `/tools` e companhia não faziam nada.**
  Esses comandos não iniciam um turno do agente: respondem com frames
  `command_output`, que o app decodificava e descartava. Agora são renderizados
  em bloco monoespaçado, recolhido acima de 12 linhas.

### Adicionado

- **Seletor de diretório nativo.** O chip da pasta abre o `NSOpenPanel` padrão
  do macOS. `/cd` sem argumento abre o mesmo seletor. O `hidesOnDeactivate` do
  painel é suspenso enquanto o diálogo está aberto, senão o painel sumiria no
  instante em que o Finder tomasse o foco.
- **Seletor de conversas.** O chip **Conversas** lista as sessões recentes lidas
  dos transcritos do `omp`, com **Nova conversa** no topo. As do diretório atual
  vêm primeiro; retomar uma de outra pasta move o workspace junto, senão os
  caminhos relativos daquele histórico resolveriam na árvore errada. A sessão
  em uso aparece marcada e desabilitada.
- Frames `config_update` e `session_info_update` do `omp` passam a atualizar
  modelo e effort exibidos.


## [0.4.1] — 2026-08-04

### Adicionado

- **A versão agora aparece dentro do app**: em `/status`, no menu do ícone e no
  tooltip da barra de menus. Lida do `Info.plist` em runtime, não fixada no
  código — uma constante mostraria o que era verdade quando o arquivo foi
  editado pela última vez.

### Corrigido

- `scripts/release.sh` reconstrói `build/` depois de bumpar o `VERSION`.
  `build-app.sh` carimba o `Info.plist` no momento do build, então um bundle
  construído antes do bump ficava com o rótulo anterior. Só afetava instalações
  locais — o `.dmg` publicado sempre foi construído pelo CI a partir do commit
  da tag e sempre teve a versão correta.


## [0.4.0] — 2026-08-04

### Adicionado

- **Modos Plan e Build, alternados por `⇥`.** Plan é read-only de verdade: o
  `omp` sobe com `--tools=read,grep,glob,lsp,web_search,inspect_image,todo,ask`,
  então escrita, shell, browser e subagentes não existem no registro de
  ferramentas — não há o que aprovar nem como escapar. Build usa tudo.
  O plan mode nativo do `omp` só existe no TUI (`Alt+Shift+P`) e não é exposto
  no RPC; a allow-list é o mecanismo disponível a um host de protocolo, e é o
  mais estrito.
- Chip de modo abaixo do campo, com o glifo `⇥` para o atalho ser descobrível,
  ponto laranja quando o reinício está pendente e estado travado durante uma
  execução.
- O modo escolhido é lembrado entre sessões.

### Corrigido

- **Ícone solto na janela do `.dmg`.** Era o `.VolumeIcon.icns`: um arquivo
  dentro da janela sem posição no `.DS_Store`, que o Finder estacionava embaixo
  do app e ficava visível para quem navega com arquivos ocultos à mostra.
  Removido — um ícone genérico de disco por alguns segundos custa menos.
- **Corrida no reinício do processo.** O evento `terminated` do processo
  anterior podia chegar depois do novo boot e derrubá-lo, e `start` recusava
  enquanto o filho antigo ainda vivia. O consumo de eventos agora é marcado por
  geração e o desligamento espera a saída real. Afetava também `/cd`.


## [0.3.0] — 2026-08-04

### Alterado

- **O app agora se chama Rune.** `MenuAgent` era provisório e não era o nome que
  ninguém digitava no Spotlight — buscar por "rune" não achava nada. Renomeados
  o bundle (`dev.raniere.Rune`), o executável, os módulos (`RuneKit`), o
  serviço do Keychain e os artefatos (`Rune-x.y.z.dmg`).

  > Quem já tinha chave gravada com o nome antigo precisa regravar com
  > `/key sk-…`; o serviço do Keychain mudou junto.

### Corrigido

- **`⌘V`, `⌘C`, `⌘X`, `⌘A` e `⌘Z` não funcionavam** — qualquer atalho com ⌘
  tocava o som de erro. Um app `.accessory` não mostra menu bar, mas essas
  combinações são *key equivalents de menu*, não teclas embutidas no
  `NSTextView`: sem `NSApp.mainMenu` nada responde por `paste:`. Agora existe um
  menu principal invisível com o menu Editar.
- **Janela do `.dmg` sem layout e com `.fseventsd` à mostra.** Duas causas: o
  posicionamento dependia de AppleScript, que precisa de Finder e não existe no
  runner de CI, então toda release saía crua; e a imagem era montada como
  leitura/escrita antes de ser comprimida, o que fazia o sistema gravar
  `.fseventsd` dentro dela. Agora o layout vem de `packaging/dmg-DS_Store`
  versionado e a imagem é gerada direto em UDZO, sem montar.

### Adicionado

- **Lista de comandos ao digitar `/`.** Filtra enquanto se escreve, `↑↓` navega,
  `⇥` ou `Enter` completa, `Esc` fecha. Os cinco comandos do app vêm primeiro,
  marcados com `app`; o resto vem do `available_commands_update` do `omp` (133
  na instalação de referência) e fica em cache, então a lista aparece completa
  mesmo com o `omp` desligado.
- `scripts/capture-dmg-layout.sh`, que regenera o layout congelado do `.dmg`.
- `RUNE_DIAGNOSE_SLASH=/co` renderiza a lista de comandos no `--diagnose`.
- 19 testes novos (91 no total) para ranqueamento de comandos e comportamento
  da lista.

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
- `RUNE_DIAGNOSE_BUSY=1` faz o `--diagnose` parar antes do `agent_end`,
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

[Não publicado]: https://github.com/raniere57/rune/compare/v0.8.0...HEAD
[0.11.0]: https://github.com/raniere57/rune/releases/tag/v0.11.0
[0.10.0]: https://github.com/raniere57/rune/releases/tag/v0.10.0
[0.9.0]: https://github.com/raniere57/rune/releases/tag/v0.9.0
[0.8.1]: https://github.com/raniere57/rune/releases/tag/v0.8.1
[0.8.0]: https://github.com/raniere57/rune/releases/tag/v0.8.0
[0.7.2]: https://github.com/raniere57/rune/releases/tag/v0.7.2
[0.7.1]: https://github.com/raniere57/rune/releases/tag/v0.7.1
[0.7.0]: https://github.com/raniere57/rune/releases/tag/v0.7.0
[0.6.2]: https://github.com/raniere57/rune/releases/tag/v0.6.2
[0.6.1]: https://github.com/raniere57/rune/releases/tag/v0.6.1
[0.6.0]: https://github.com/raniere57/rune/releases/tag/v0.6.0
[0.5.0]: https://github.com/raniere57/rune/releases/tag/v0.5.0
[0.4.1]: https://github.com/raniere57/rune/releases/tag/v0.4.1
[0.4.0]: https://github.com/raniere57/rune/releases/tag/v0.4.0
[0.3.0]: https://github.com/raniere57/rune/releases/tag/v0.3.0
[0.2.0]: https://github.com/raniere57/rune/releases/tag/v0.2.0
[0.1.0]: https://github.com/raniere57/rune/releases/tag/v0.1.0
