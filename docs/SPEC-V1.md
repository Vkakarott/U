# hub-agent — Spec da v1

Este documento detalha a v1 descrita em [IDEIA.md](../IDEIA.md). A ordem de construção está em [PLANO-IMPLEMENTACAO.md](PLANO-IMPLEMENTACAO.md). O repositório tem hoje só o esqueleto de módulos: nenhuma funcionalidade da v1 (terminal, daemon, interface, protocolo) deve ser implementada antes da autorização do Lucas.

Como ler:

- **Decisão**: fechada pelo Lucas. As que nasceram das questões Q1–Q12 de uma versão anterior deste spec levam o código da questão.
- Os códigos P1–P6 e A1–A4 identificam decisões que começaram como propostas e perguntas deste spec e foram aceitas por ele. As P estão detalhadas na seção 7; a seção 8 resume todas.
- **Ponto em aberto**: só resta o A5, na seção 9, agora com a resposta que o protótipo deu.
- A seção 11 registra o que o protótipo da fase 1 mostrou, separando o que foi verificado do que ainda depende de teste manual.
- O que não tem marcação é desdobramento das decisões feito neste spec e pode ser revisto.

## 1. Objetivo

Entregar um app desktop macOS, bem enxuto, com o básico para o próprio hub-agent ser usado no desenvolvimento das próximas versões.

A v1 é enxuta em funcionalidade, não em arquitetura: a base (daemon de PTYs, interface do terminal, protocolo, armazenamento) precisa receber chat, quadro e mobile sem ser refeita.

Critério de pronto: dá para abrir o projeto hub-agent no app, trabalhar nele com abas de terminal (rodando Claude Code e Codex dentro delas) durante um dia inteiro, fechar e reabrir o app sem perder os terminais, e testar uma versão nova do hub-agent sem derrubar os terminais em uso.

## 2. Escopo

### Entra

- **Projetos.** Cada projeto aponta para um diretório local. Não existe a camada de "máquinas" do Termhub.
- **Abas de terminal** dentro de cada projeto. Toda aba é um terminal normal aberto na raiz do projeto, como no Termhub (Q1).
- **Daemon de PTYs**: os terminais sobrevivem ao fechamento ou crash do app.
- **Daemon de desenvolvimento** separado do daemon em uso (Q10).

### Não entra

- Aba de agente e atalhos para abrir Claude Code ou Codex direto (Q1). Na v1 o usuário digita `claude` ou `codex` no terminal. Os atalhos ficam para depois da v1.
- Painéis divididos, reordenar abas arrastando e indicador de atividade na aba (Q12, P6).
- Chat (por projeto e global).
- Quadro de cards.
- App Android.
- Acesso fora da rede local (e qualquer acesso pela rede: na v1 o daemon só atende o app local).
- Vários clientes na mesma sessão de terminal (Q8).
- Assinatura, notarização e distribuição (Q11).
- tmux, em qualquer papel.

## 3. Arquitetura

### 3.1 Visão geral

```
┌─────────────────────────────── App (Swift) ─────────────────────────────────┐
│                                                                             │
│  SwiftUI: barra lateral e abas ──► TerminalSurface (interface própria)      │
│          │                             └── v1: SwiftTerm, em AppKit         │
│          ▼                                                                  │
│  ProjectStore (JSON local, P4)        DaemonClient                          │
│                                            │                                │
└────────────────────────────────────────────┼────────────────────────────────┘
                                             │ Unix socket local (P2)
┌────────────────────────────────────────────┼────────────────────────────────┐
│  Daemon de PTYs (processo separado)        ▼                                │
│                                                                             │
│  Servidor de protocolo ──► SessionManager ──► PTY + shell do usuário        │
│                                   └── emulador sem interface por sessão,    │
│                                       com o estado atual da tela (Q3)       │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 App

**Decisões:** macOS nativo em Swift. SwiftUI na estrutura (barra lateral, abas) e AppKit no terminal (Q9). O app é dono da lista de projetos e abas (Q4).

Responsabilidades:

- interface: lista de projetos, abas do projeto ativo, área do terminal;
- persistência de projetos e abas (ver 3.5);
- cliente do daemon: pede criação de sessões, anexa, envia entrada, recebe saída;
- iniciar o daemon ao abrir, se ainda não estiver rodando (Q10).

O app **não** cria PTYs nem processos de shell. Se o app morre, nenhum terminal morre.

### 3.3 Daemon de PTYs

**Decisões:** os PTYs rodam num processo daemon separado e o app é cliente dele. O daemon inicia junto com o app e continua rodando depois que o app fecha (Q10). Cuida só das sessões de terminal (Q4). Um cliente por sessão (Q8).

Responsabilidades:

- criar PTYs e iniciar o shell do usuário (ver 3.4);
- ler a saída de cada PTY continuamente, mesmo sem cliente anexado (se o daemon parar de ler, o processo filho bloqueia ao escrever);
- manter o estado da tela de cada terminal num emulador sem interface e enviar a tela pronta quando o app reanexa (Q3, detalhes em 3.6);
- repassar entrada e redimensionamento;
- informar quando uma sessão termina.

O daemon não conhece interface, projetos nem abas. Ele trabalha com sessões identificadas por id, e cada sessão carrega um rótulo que o cliente define e que o daemon guarda sem interpretar (necessário para a Q6, ver 4).

Linguagem e repositório: P1. Mecanismo de inicialização: P5.

### 3.4 Shell das sessões

**Decisão (Q2):** a aba abre o shell de login interativo do usuário, com o ambiente normal dele. O usuário digita `claude` ou `codex` como em qualquer terminal.

Consequências:

- o shell é o cadastrado na conta do usuário, não um valor fixo;
- ele é iniciado como shell de login (como o Terminal do macOS faz), para carregar os arquivos de configuração do usuário e, com eles, o PATH em que `claude` e `codex` estão;
- o diretório inicial é a raiz do projeto;
- o daemon precisa montar o ambiente base por conta própria, porque não herda o do usuário (risco R3).

### 3.5 Armazenamento

| Dado | Dono na v1 | Onde | Sobrevive a |
|---|---|---|---|
| Projetos e abas | app | arquivo JSON local (P4) | tudo |
| Sessões de terminal vivas | daemon | memória | fechamento e crash do app |
| Estado da tela e histórico | daemon | memória | fechamento e crash do app |

Nada do daemon sobrevive à morte do próprio daemon ou ao reinício do Mac: os processos morrem junto. Nesse caso as abas continuam e ganham um terminal novo (Q5).

O acesso ao arquivo fica atrás de uma interface de repositório (`ProjectStore`), para a troca por SQLite quando o chat entrar não afetar o resto do app.

**Migração futura para o daemon (Q4).** Quando o mobile entrar, ele vai precisar da lista de projetos e abas com o app desktop fechado, e só o daemon estará rodando. Nesse momento a lista pode passar a ser do daemon. O que isso custa:

- o arquivo de dados muda de dono (o formato pode ser o mesmo);
- o protocolo ganha mensagens para criar, alterar, apagar e listar projetos e abas, e para avisar os clientes quando algo muda;
- o app deixa de ler e gravar o arquivo e passa a pedir tudo ao daemon;
- uma conversão única dos dados existentes;
- o daemon cresce, o que pesa no risco R7.

O que a v1 faz para baratear isso: `ProjectStore` como única porta de acesso aos dados, ids estáveis e o rótulo nas sessões.

### 3.6 Interface do terminal e restauração da tela

**Decisão:** SwiftTerm como emulador, atrás de uma interface própria que permita trocá-lo por libghostty no futuro.

A interface (nome de trabalho: `TerminalSurface`) é o único ponto em que o resto do app toca no emulador. Contrato mínimo:

| Direção | Operação |
|---|---|
| app → emulador | alimentar bytes de saída vindos do daemon |
| app → emulador | receber a tela pronta ao reanexar |
| emulador → app | bytes de entrada gerados pelo teclado/mouse/colagem |
| emulador → app | mudança de tamanho (colunas × linhas) |
| emulador → app | título, sino, pedido de abrir link |
| app → emulador | foco, tema/fonte, seleção e cópia |

Regras:

- nenhum tipo do SwiftTerm aparece fora da implementação da interface;
- no app, o emulador nunca é dono do PTY nem do processo: ele só recebe e emite bytes. Isso exclui o `LocalProcessTerminalView` do SwiftTerm.

**Decisão (Q3):** restaurar a tela da melhor forma possível, como fazem o tmux e o terminal do VS Code. O daemon mantém o estado da tela de cada terminal num emulador sem interface e envia a tela pronta quando o app reanexa.

#### O que o SwiftTerm oferece para isso

Verificado lendo o código-fonte do SwiftTerm (repositório `migueldeicaza/SwiftTerm`) e, depois, com o protótipo da fase 1 compilado contra a versão 1.99.0. Correção de uma versão anterior deste texto: a versão publicada mais recente não é a 1.9.0, e sim a **1.99.0, de 08/10/2026**; a anterior é a 1.20.0, de agosto de 2026. O erro veio de uma listagem de versões ordenada como texto.

Verificado:

- O motor do emulador (`Terminal`) é separado da parte visual. Dá para criá-lo sem janela, alimentá-lo com bytes, redimensioná-lo e ler o conteúdo de cada célula, a posição do cursor e se a tela alternativa (usada por programas de tela cheia) está ativa.
- Existe `HeadlessTerminal`, descrito na documentação como um terminal que roda um processo local sem exibição. Ele junta o motor a um `LocalProcess`, que cria o PTY e o processo. Está disponível no macOS.
- O SwiftTerm traz o código de criação de PTY (`PseudoTerminalHelpers`, sobre `forkpty`).
- `makeRenderSnapshot` devolve uma cópia estruturada da tela: células com texto e atributos, cursor, paleta e indicador de tela alternativa. Existe na 1.99.0 e não na 1.20.0. A peça do protótipo não precisou dela: usa só a leitura célula a célula, que existe nas duas.
- `getBufferAsData` exporta o conteúdo só como texto puro, sem cores.
- **Não existe** função que transforme o estado da tela em algo que outro emulador consiga carregar. O motor só recebe estado por bytes de terminal, e a cópia estruturada não tem formato de transporte nem caminho de volta para dentro de um emulador.
- O pacote exige macOS 11 ou mais novo.

Conclusão: o SwiftTerm serve para manter o estado da tela no daemon, mas não entrega a "tela pronta" sozinho. Falta uma peça nossa, que lê o estado do motor e gera os bytes de terminal que reconstroem aquela tela no emulador do app. É a mesma técnica do terminal do VS Code.

O protótipo da fase 1 testou as suposições que estavam aqui. O resultado está na seção 11; em resumo: a peça funciona, os modos internos do SwiftTerm não são todos legíveis de fora (o daemon os acompanha por conta própria), e o daemon combina `Terminal` e `LocalProcess` diretamente em vez de usar `HeadlessTerminal`.

A decisão é escrever essa peça (P3). As alternativas, se o protótipo mostrar que não serve:

| Alternativa | Custo |
|---|---|
| **Reenviar os bytes brutos e forçar o programa a se redesenhar** | Barata e sem peça nova. Não atende a decisão: o histórico pode voltar quebrado e programas de tela cheia podem voltar errados. Serve como plano B temporário. |
| **Outro emulador sem interface no daemon** (por exemplo o núcleo da libghostty) | Dependência fora do Swift no daemon, e dois emuladores diferentes (daemon e app) podem discordar sobre a mesma tela. Ainda exigiria a peça que gera a tela pronta, se o emulador não trouxer uma. |
| **Contribuir a função que falta ao SwiftTerm** | Mesmo trabalho da P3, mais o tempo de aceitação pelo projeto. Reduz manutenção depois. |

### 3.7 Fronteiras entre os componentes

| Fronteira | Quem conhece o quê |
|---|---|
| UI ↔ emulador | só a `TerminalSurface`. A UI não sabe que é SwiftTerm. |
| App ↔ daemon | só o protocolo de mensagens. O app não sabe como o daemon cria PTYs; o daemon não sabe o que é aba ou projeto. |
| App ↔ disco | só o `ProjectStore`. O resto do app não sabe que é JSON. |
| Daemon ↔ transporte | o servidor de protocolo é separado do `SessionManager`. Trocar ou somar transporte (Unix socket hoje, WebSocket depois) não toca na gestão de sessões. |
| Daemon ↔ emulador | o emulador sem interface fica atrás de uma interface própria no daemon, pelo mesmo motivo da `TerminalSurface`. |

A ligação entre os dois mundos são dois campos: a aba guarda o `sessionId` da sessão que exibe, e a sessão guarda o rótulo com o projeto e a aba a que pertence.

## 4. Modelo de dados

Nomes de campos em inglês, como ficarão no código. Tipos e campos são indicativos.

### Project (persistido pelo app)

| Campo | Tipo | Observação |
|---|---|---|
| `id` | UUID | |
| `name` | string | padrão: nome da pasta |
| `directoryPath` | string | diretório local do projeto |
| `order` | int | posição na lista |
| `createdAt` | data | |

### Tab (persistida pelo app)

| Campo | Tipo | Observação |
|---|---|---|
| `id` | UUID | |
| `projectId` | UUID | |
| `title` | string | |
| `order` | int | posição entre as abas do projeto |
| `sessionId` | UUID \| nulo | sessão viva no daemon, se houver |
| `createdAt` | data | |

Não existe tipo de aba na v1: toda aba é um terminal (Q1).

### TerminalSession (viva no daemon, não persistida)

| Campo | Tipo | Observação |
|---|---|---|
| `id` | UUID | |
| `workingDirectory` | string | raiz do projeto no momento da criação |
| `columns`, `rows` | int | tamanho atual |
| `pid` | int | |
| `label` | mapa | definido pelo cliente, o daemon não interpreta. Na v1: `projectId`, `tabId`, `title` |
| `createdAt` | data | |

Relações: um projeto tem N abas; uma aba tem no máximo uma sessão e uma sessão pertence a uma aba. A aba é durável, a sessão é efêmera.

O arquivo de armazenamento leva um número de versão de esquema desde o primeiro dia, para permitir migração.

## 5. Fluxos principais

### 5.1 Criar projeto

1. Usuário escolhe "novo projeto" e seleciona um diretório.
2. App valida que o diretório existe e cria o `Project` com o nome da pasta como padrão.
3. App grava no `ProjectStore`.
4. Projeto aparece na lista, selecionado e sem abas. O daemon não é envolvido.

### 5.2 Abrir aba de terminal

1. Usuário pede nova aba no projeto ativo.
2. App cria a `Tab` e a `TerminalSurface`, que informa seu tamanho inicial.
3. App pede ao daemon uma sessão: raiz do projeto, tamanho, rótulo (`projectId`, `tabId`, `title`).
4. Daemon cria o PTY, inicia o shell de login do usuário e devolve o `sessionId`. Se a pasta do projeto não existir mais, o app avisa e não abre o terminal (A4).
5. App grava o `sessionId` na aba e anexa à sessão.
6. Saída do daemon alimenta a `TerminalSurface`; entrada e redimensionamento fazem o caminho inverso.

Para usar um agente, o usuário digita `claude` ou `codex` nesse terminal.

### 5.3 Fechar aba

1. Usuário fecha a aba. Se houver algo rodando além do shell, o app pede confirmação (P6).
2. App pede ao daemon que encerre a sessão (Q7). O daemon encerra o shell e tudo o que estiver rodando nele.
3. App remove a aba do `ProjectStore`.

O caminho inverso dá no mesmo resultado: se o shell termina sozinho (o usuário digita `exit`), o daemon avisa o app e a aba fecha (A1).

### 5.4 Fechar e reabrir o app com os terminais vivos

Fechar:

1. Usuário fecha o app (ou o app trava).
2. A conexão com o daemon cai. O daemon continua rodando, mantém todas as sessões, segue lendo a saída dos PTYs e atualizando o estado da tela de cada uma.

Reabrir:

1. App inicia, lê projetos e abas do `ProjectStore` e inicia o daemon se ele não estiver rodando.
2. App pede ao daemon a lista de sessões e reconcilia com as abas:

| Situação | Ação |
|---|---|
| Aba com sessão viva | anexar; o daemon envia a tela pronta |
| Aba cuja sessão terminou sozinha com o app fechado (`exit`) | a aba fecha (A1) |
| Aba cuja sessão não existe mais (daemon ou Mac reiniciou) | a aba continua e abre um terminal novo na raiz do projeto; o histórico anterior se perde (Q5). Se a pasta do projeto sumiu, o app avisa e não abre o terminal (A4) |
| Sessão viva sem aba (caso de falha) | o app recria a aba, usando o rótulo da sessão para saber o projeto e o título (Q6) |
| Sessão viva sem aba, de um projeto que já foi apagado | o app encerra a sessão (A2) |

Para separar o primeiro caso do segundo, o daemon guarda o registro das sessões que terminaram sozinhas até o app tomar conhecimento. Sessão que o daemon desconhece por completo é sinal de que ele reiniciou.

3. Ao anexar, o daemon envia a tela pronta e em seguida a saída ao vivo, sem lacuna nem duplicação entre as duas.
4. App envia o tamanho atual da `TerminalSurface`; o daemon redimensiona o PTY e o emulador sem interface se mudou.

### 5.5 Apagar projeto

1. Usuário pede para apagar o projeto. O app pede confirmação, avisando que os terminais do projeto serão encerrados.
2. App pede ao daemon que encerre as sessões das abas do projeto.
3. App remove o projeto e suas abas do `ProjectStore`.

A pasta do projeto no disco nunca é tocada (A3).

## 6. Pontos de extensão

### Atalhos de agente (pós-v1)

- Um atalho para abrir Claude Code ou Codex é uma aba de terminal com um comando digitado automaticamente no shell. Não exige mudança no daemon.
- Se as abas ganharem tipos (agente, chat), entra um campo novo em `Tab`, coberto pela versão de esquema do arquivo.

### Chat (por projeto e global)

- O chat global não pertence a projeto nenhum, então a navegação não pode assumir que tudo vive dentro de um projeto.
- `ProjectStore` é a costura para SQLite quando o chat trouxer volume e consulta.
- Se o chat precisar ler ou escrever em terminais, ele usa o mesmo protocolo do daemon. Isso pode ser a primeira funcionalidade a exigir mais de um cliente por sessão (Q8).

### Quadro de cards

- Mesma costura de armazenamento do chat.
- `Project.id` e `Tab.id` estáveis (UUID) permitem que cards referenciem projetos e abas.
- Escopo e modelo do quadro ainda não foram discutidos.

### Mobile

- O daemon já é a peça que o mobile vai consumir: ele tem os terminais reais, independentes do app desktop.
- O estado da tela mantido no daemon (Q3) é o que permite ao mobile abrir um terminal em andamento e ver a tela correta.
- O protocolo foi pensado para ganhar um segundo transporte (WebSocket) com as mesmas mensagens (P2).
- **Decisão:** a camada de conexão fica abstraída, o cliente conhece só um endpoint. Tailscale primeiro; Headscale ou relay próprio com criptografia ponta a ponta numa VPS gratuita como evolução.
- O que o mobile vai exigir e a v1 não resolve: vários clientes na mesma sessão (Q8), autenticação, e a lista de projetos e abas no daemon (Q4, custo em 3.5).

### Troca do emulador

- `TerminalSurface` isola o SwiftTerm no app; o daemon tem a sua própria interface para o emulador sem interface. Ver risco R2.

## 7. Decisões técnicas (P1–P6)

Nasceram como propostas deste spec e foram todas aceitas pelo Lucas. Os códigos foram mantidos porque o resto do documento os cita.

### P1 — Daemon em Swift, no mesmo repositório

- Uma linguagem só, e o código de protocolo é compartilhado entre app e daemon.
- Ganhou um argumento com a Q3: o SwiftTerm já traz o motor sem interface e a criação de PTY, e os dois só são aproveitáveis num daemon em Swift.

### P2 — Unix socket local com protocolo simples de mensagens

- Mensagens: criar, listar, anexar, desanexar, entrada, saída, redimensionar, encerrar sessão, aviso de sessão encerrada. Pensado para ser reaproveitado pelo mobile por WebSocket.
- Primeira mensagem de toda conexão: versão do protocolo dos dois lados (R5).
- Um cliente por sessão (Q8): se um segundo cliente anexar, ele assume e o anterior é desanexado. Cobre o caso de uma conexão antiga que ficou presa depois de um crash do app.
- Formato: saída de terminal é binária e volumosa. Enquadramento binário (cabeçalho pequeno + bytes) em vez de JSON puro, que obrigaria a codificar tudo em base64. Serve também para WebSocket.
- Socket num diretório do usuário com permissão restrita ao dono.

### P3 — Escrever a peça que mantém o estado e gera a tela pronta

- Em cada sessão, o daemon alimenta um motor `Terminal` do SwiftTerm com a mesma saída que repassa ao app.
- Ao anexar, uma peça própria lê o estado do motor (histórico, área visível, cores e atributos, cursor, tela alternativa, modos ativos) e gera os bytes de terminal que reconstroem essa tela. O app os entrega ao seu emulador como se fossem saída normal.
- Versão do SwiftTerm: resultado do protótipo, a confirmar pelo Lucas: usar a **publicada 1.99.0, fixada exatamente** no pacote. Não é preciso código ainda não publicado. A 1.20.0 também serviria para a peça, mas não tem a trava que protege o emulador quando ele é lido e alimentado ao mesmo tempo.
- Histórico com limite de linhas por sessão. O número é detalhe de implementação, a fixar no protótipo (o padrão do SwiftTerm é 500, pouco para uso com agentes).
- O protótipo do risco R1 é quem confirma que a peça funciona. Base e limites do que foi verificado: seção 3.6.

### P4 — Armazenamento em JSON local; SQLite só quando o chat entrar

- Projetos e abas num arquivo JSON, gravado de forma atômica (escreve em temporário e renomeia).

### P5 — Inicialização do daemon pelo launchd, com daemon de desenvolvimento separado

Comportamento (Q10): o daemon inicia junto com o app, continua rodando depois que o app fecha, e existe um daemon de desenvolvimento separado do daemon em uso.

Mecanismo: agente de usuário do launchd. Ao abrir, o app instala (se faltar) um arquivo de configuração em `~/Library/LaunchAgents` e pede ao launchd que inicie o daemon. Sem início automático no login e sem reinício automático.

Por que launchd e não o app iniciar o daemon como processo solto:

- o daemon não é filho do app, então nada que mate o app (crash, forçar encerramento, parar a execução pelo Xcode) o leva junto;
- o launchd garante uma única instância por nome, o que elimina a corrida de dois apps iniciando dois daemons;
- saída de log e ambiente ficam definidos num lugar só;
- separar o daemon de desenvolvimento vira só mais um nome registrado.

O que custa: o ambiente mínimo do launchd e as permissões do macOS passam a ser assunto do daemon (R3).

Por que não o registro pelo próprio pacote do app (`SMAppService`): é pensado para apps assinados e distribuídos, e a Q11 dispensa assinatura.

Daemon de desenvolvimento:

- a versão de desenvolvimento do app (a que roda direto do código-fonte, por `make run` ou pelo Xcode) usa um daemon próprio, com nome, socket, pasta de dados e arquivo de projetos e abas diferentes dos da versão em uso;
- o arquivo de projetos e abas também precisa ser separado: se as duas versões dividissem o mesmo arquivo, a de desenvolvimento não encontraria as sessões das abas no seu daemon e abriria terminais novos por cima (Q5);
- a versão de desenvolvimento nunca fala com o daemon em uso, e vice-versa.

Atualização do daemon em uso: trocar o daemon encerra todos os terminais. O app detecta que o daemon rodando é de versão diferente, avisa e só troca com confirmação; enquanto isso continua funcionando com o daemon antigo, se as versões de protocolo forem compatíveis (R5).

Parada: o daemon em uso não encerra sozinho. O app oferece uma ação explícita de encerrar o daemon, com aviso de que os terminais serão perdidos.

### P6 — Lista mínima de ações de aba

Abas só com o básico e funcional (Q12).

Entra:

- criar aba (abre na raiz do projeto ativo);
- fechar aba (encerra a sessão, Q7), com confirmação se houver algo rodando além do shell;
- trocar de aba, por clique e por atalho de teclado (próxima, anterior, por número);
- renomear aba; o título padrão é sequencial ("Terminal 1", "Terminal 2").

Fica fora da v1: painéis divididos, reordenar por arraste e indicador de atividade na aba. Também não entram, por não estarem na lista acima: título automático a partir do programa em execução, duplicar aba e mover aba entre projetos.

## 8. Resumo das decisões

Todas fechadas pelo Lucas.

### Questões Q1–Q12

| | Questão | Decisão |
|---|---|---|
| Q1 | O que é uma aba de agente | Não existe aba de agente na v1. Toda aba é um terminal normal na raiz do projeto, como no Termhub. Atalhos para Claude Code e Codex ficam para depois. |
| Q2 | Como a CLI do agente é iniciada | Deixa de existir. A aba abre o shell de login interativo do usuário, com o ambiente normal dele, e ele digita `claude` ou `codex`. |
| Q3 | Como restaurar a tela ao reanexar | Da melhor forma possível, como tmux e VS Code: o daemon mantém o estado da tela num emulador sem interface e envia a tela pronta. Implementação: P3. |
| Q4 | Dono de projetos e abas | O app, na v1. O daemon cuida só das sessões. Pode migrar para o daemon quando o mobile entrar (custo em 3.5). |
| Q5 | Aba cuja sessão morreu | A aba continua e abre um terminal novo na raiz do projeto. O histórico se perde. Igual ao Termhub. |
| Q6 | Sessão viva sem aba | Ao abrir, o app recria a aba para ela. |
| Q7 | Fechar uma aba | Encerra a sessão de terminal. |
| Q8 | Vários clientes na mesma sessão | Um cliente por sessão na v1. Vários só quando alguma funcionalidade exigir. |
| Q9 | AppKit e SwiftUI | SwiftUI na estrutura (barra lateral, abas), AppKit no terminal. |
| Q10 | Ciclo de vida do daemon | Inicia junto com o app e continua depois que o app fecha. Daemon de desenvolvimento separado do daemon em uso. Mecanismo: P5. |
| Q11 | Versão do macOS e distribuição | Só execução local no Mac do Lucas, na versão que ele usa (macOS 26.6.2 nesta máquina). Sem assinatura nem notarização por enquanto. |
| Q12 | Modelo de abas | Só o básico e funcional, sem painéis divididos. Lista mínima: P6. |

Confirmado junto: o daemon de PTYs permanece na v1.

### Decisões técnicas P1–P6

| | Assunto | Decisão |
|---|---|---|
| P1 | Linguagem do daemon | Swift, no mesmo repositório do app. |
| P2 | Conversa entre app e daemon | Unix socket local, com protocolo simples de mensagens em formato binário e troca de versão na primeira mensagem. |
| P3 | Tela restaurada | Escrever a peça própria que lê o estado do emulador do daemon e gera a tela pronta. |
| P4 | Armazenamento | Projetos e abas num arquivo JSON local. SQLite só quando o chat entrar. |
| P5 | Inicialização do daemon | Pelo launchd, com daemon de desenvolvimento separado. |
| P6 | Ações de aba | Criar, fechar (com confirmação se houver algo rodando), trocar por clique e por atalho, renomear. |

### Perguntas A1–A4

| | Pergunta | Decisão |
|---|---|---|
| A1 | O shell termina sozinho (`exit`) | A aba fecha. |
| A2 | Sessão viva sem aba, de um projeto já apagado | Encerrar a sessão. |
| A3 | Apagar um projeto | Fecha as abas e encerra os terminais dele, com confirmação. A pasta no disco nunca é tocada. |
| A4 | Pasta do projeto sumiu | Avisar e não abrir o terminal. |

## 9. Ponto ainda em aberto

Sobrou um. O protótipo da fase 1 deu a resposta técnica; falta a confirmação do Lucas para virar decisão.

### A5 — Quem responde às consultas dos programas ao terminal

Com um emulador no daemon e outro no app, os dois responderiam à mesma consulta (posição do cursor, cores, tamanho), e o programa receberia a resposta em dobro.

- **A. Só o daemon responde.** Funciona com o app fechado. Custo: o daemon precisa conhecer o que só o app sabe, como as cores do tema, e o app precisa descartar as respostas do seu emulador sem descartar o que o usuário digita.
- **B. Só o app responde.** Mais simples. Custo: com o app fechado ninguém responde, e um programa que consulte o terminal nesse intervalo pode ficar esperando.

É decisão técnica, a tomar com o resultado do protótipo.

**Resultado do protótipo: opção A, só o daemon responde.** Medido com um programa que pergunta a posição do cursor:

| Quem responde | App aberto | App fechado |
|---|---|---|
| Só o daemon | programa recebe a resposta | programa recebe a resposta |
| Só o app | programa recebe a resposta | programa fica sem resposta até desistir |
| Os dois | a resposta em dobro vaza para o shell como se fosse texto digitado e estraga o comando seguinte | — |

O Claude Code fez 15 consultas só ao abrir e o Codex mais 6, então isso não é caso raro. O custo previsto se confirmou e tem solução: a visualização do SwiftTerm entrega as respostas do emulador por um caminho separado do teclado, que o app pode simplesmente ignorar (verificado que compila; o efeito na janela depende do teste manual). Resta um detalhe: o daemon informa aos programas a cor de fundo padrão dele, então o app precisa enviar as cores do tema ao daemon.

## 10. Riscos técnicos

### R1 — Dois emuladores para o mesmo terminal

O terminal passa por dois emuladores: o do daemon, sem interface, e o do app, que desenha. Precisa ser validado num protótipo descartável, antes de qualquer outra coisa:

- o SwiftTerm no app recebendo bytes do daemon e devolvendo entrada e tamanho (o uso comum dele é criar o processo no próprio app);
- a tela pronta gerada pela peça da P3, comparada com a tela real, com Claude Code e Codex abertos;
- latência com um salto a mais de comunicação e comportamento com saída muito volumosa;
- os dois emuladores sempre com o mesmo tamanho; qualquer diferença corrompe a tela restaurada;
- a questão A5.

Era o maior risco da v1. O protótipo da fase 1 o reduziu bastante: ver seção 11.

### R2 — Troca futura por libghostty

A `TerminalSurface` assume um emulador que aceita bytes de fora. A libghostty, até onde se sabe e sem verificação nesta etapa, foi desenhada para ser dona do PTY e do processo, e sua forma de embutir ainda não é estável. Além disso, com a Q3 o emulador passa a existir em dois lugares: trocar só o do app deixa daemon e app com emuladores diferentes, que podem discordar sobre a mesma tela. A troca futura provavelmente envolve os dois lados. Não é bloqueio para a v1.

### R3 — Ambiente e permissões de um processo iniciado pelo launchd

- Um processo do launchd não herda o ambiente do usuário. O daemon precisa montar o ambiente base (pasta do usuário, idioma, tipo de terminal) e iniciar o shell como shell de login para que o resto venha da configuração do usuário (3.4). Se isso falhar, `claude` e `codex` não são encontrados.
- As permissões de privacidade do macOS (acesso a Documentos, Mesa, Downloads) são atribuídas ao processo responsável. Com o daemon como pai dos shells, os pedidos de permissão passam a ser do daemon, não do app. O repositório do hub-agent fica dentro de `~/Documents`, então isso aparece no primeiro uso.
- Sem assinatura (Q11), cada recompilação do daemon pode ser vista pelo macOS como um programa novo e pedir as permissões de novo. Afeta principalmente o daemon de desenvolvimento.

Resultado do protótipo: o shell de login iniciado por um daemon do launchd carregou o ambiente do usuário e encontrou `claude` e `codex`. O macOS mostrou uma caixa de permissão em nome do daemon para cada pasta protegida (Documentos, Mesa, Downloads); depois de permitido, o acesso funcionou. Detalhes e o que ficou sem testar: seção 11.

### R4 — Criar PTY e processo em Swift

Menor do que parecia: o SwiftTerm já traz esse código (verificado na seção 3.6) e ele pode ser usado no daemon. Segue precisando de teste: propagação de sinais, encerramento de tudo o que roda dentro do shell ao fechar a aba e detecção do fim do processo.

Resultado do protótipo: criar o terminal com o código do SwiftTerm funcionou. Encerrar exigiu cuidado: o shell interativo ignora o pedido normal de término, então a sessão é encerrada com o sinal de desligamento (que o shell repassa ao que está rodando nele) e, se sobrar algo depois de um segundo, com encerramento forçado. Com isso não sobrou processo nos testes.

### R5 — Versões diferentes de app e daemon

Como o daemon sobrevive ao app, é normal um app novo conversar com um daemon antigo, e durante o desenvolvimento isso acontece o tempo todo. Sem troca de versão na primeira mensagem, qualquer mudança de protocolo quebra sessões em uso.

### R6 — Memória no daemon

O daemon continua lendo os PTYs com o app fechado ou lento. Cada sessão guarda um emulador inteiro com histórico. Um comando que gera saída sem parar não pode fazer a memória crescer sem limite nem travar as outras sessões: histórico com limite por sessão e descarte do mais antigo.

Resultado do protótipo: com 5.000 linhas de histórico e 100 MB de saída, o daemon ficou em cerca de 23 MB de memória. A vazão passando pelos dois emuladores foi de cerca de 30 MB/s. Dois avisos: compilado sem otimização, o SwiftTerm cai para cerca de 1 MB/s, então o daemon precisa ser compilado com otimização mesmo em desenvolvimento; e no protótipo um cliente lento freia o terminal, o que a fase 2 precisa resolver com fila limitada.

### R7 — Queda do daemon

Se o daemon cair, todos os terminais morrem de uma vez, que é exatamente o que ele existe para evitar. A Q3 colocou um emulador dentro dele, o que aumenta a quantidade de código capaz de derrubá-lo: uma sequência de saída que quebre o emulador não pode derrubar as outras sessões. Tudo que puder ficar no app fica no app.

### R8 — Foco de teclado entre SwiftUI e AppKit

Com SwiftUI na estrutura e AppKit no terminal (Q9), foco e atalhos de teclado atravessam os dois mundos, e é a parte mais sensível de um app de terminal: o terminal precisa receber todas as teclas, menos os atalhos do app. Validar cedo.

### R9 — Segurança do socket

Quem consegue conectar ao socket consegue executar comandos como o usuário. Na v1: socket com permissão só para o dono. Quando o mobile entrar, o transporte de rede exige autenticação antes de qualquer mensagem.

## 11. Resultados do protótipo (fase 1)

Protótipo descartável em `Prototypes/TerminalPath`, com SwiftTerm 1.99.0, rodado em macOS 26.6.2. Os testes automáticos estão em `Prototypes/TerminalPath/Checks` e podem ser repetidos com `Checks/run.sh`.

### Como foi verificado

Um cliente sem janela faz o papel do app: mantém o seu próprio emulador, alimentado só pelo que o daemon envia, e compara o estado dele com o do daemon célula a célula (texto, cores, atributos, histórico, cursor e modos). Isso prova que os dois emuladores ficam com a mesma tela. **Não prova o que aparece desenhado na janela nem o comportamento do teclado**, que dependem do teste manual descrito em `Prototypes/TerminalPath/README.md`.

### Verificado

| O que | Resultado |
|---|---|
| Terminal que vive no daemon, usado por um cliente | Digitar, redimensionar, Ctrl-C e seta para cima funcionaram pelo protocolo. |
| Tela ao vivo igual nos dois lados | Idêntica em todos os casos sem redimensionamento durante saída. |
| Fechar e reabrir com shell simples | Tela e 405 linhas de histórico idênticas, com cores, acentos e emoji. |
| Saída produzida com o app fechado | Aparece ao reabrir, idêntica. |
| Fechar e reabrir com programa de tela cheia | Idêntica com vim, less, top, Claude Code 2.1.295 e Codex 0.160.1. Nenhum prompt foi enviado aos agentes; só as telas iniciais e menus. |
| Sair do programa de tela cheia depois de reabrir | O shell que estava por trás volta idêntico, com cores. |
| Sem lacuna nem duplicação entre tela pronta e saída ao vivo | Confirmado: as comparações continuam idênticas depois de reanexar e seguir usando. |
| `exit` no terminal | O daemon avisa o cliente (base da A1). |
| Encerrar sessão | Nenhum processo sobrou. |
| Custo da tela pronta | 5.000 linhas de histórico: 514 KB, montada em 47 ms. |
| Janela do protótipo | Abre, cria o terminal, e ao reabrir anexa ao terminal vivo e recebe a tela pronta (pelo registro do app, sem olhar a janela). |
| Shell de login a partir do launchd | `claude` e `codex` encontrados; ambiente do usuário carregado. |

### O que a peça precisou além do previsto

- **Modos.** O SwiftTerm não expõe vários modos (cursor visível, teclado numérico de aplicação, aviso de foco e outros). O daemon passou a acompanhá-los lendo a própria saída do terminal.
- **Tela escondida.** O SwiftTerm só expõe com cores a tela ativa. Quando um programa de tela cheia abre, o shell por trás fica inacessível com cores. O daemon guarda uma cópia dele no instante anterior à troca de tela. Limite conhecido: se a janela for redimensionada com o programa de tela cheia aberto, a posição do cursor dessa cópia pode ficar errada.
- **Linha quebrada vazia.** Caso de borda corrigido na peça.
- **Primeira linha do histórico.** Quando é a continuação de uma linha já descartada, a marca de "continuação" não pode ser reconstruída. Não afeta o que se vê.

### Problemas encontrados

- **Redimensionar durante saída.** O app muda de tamanho antes do daemon. O texto que sai nesse intervalo é disposto em larguras diferentes nos dois emuladores, e o histórico do app fica diferente do histórico do daemon até a próxima reconexão. Não acontece com o terminal parado. Correção proposta para a fase 2: depois de redimensionar, o daemon reenvia a tela pronta, com um pequeno atraso para não reenviar a cada passo do arraste.
- **Cliente lento freia o terminal.** Ver R6.
- **Compilação sem otimização.** Ver R6.

### launchd e permissões do macOS

Foi registrado um serviço temporário, `com.hubagent.prototype.phase1-daemon`, carregado de uma pasta temporária, sem nada gravado em `~/Library/LaunchAgents`. Ele foi removido ao fim do teste.

- O daemon iniciou e ficou independente de qualquer app.
- Ao entrar na pasta do projeto, dentro de `~/Documents`, o macOS mostrou uma caixa de permissão em nome do daemon. O mesmo aconteceu para a Mesa e para Downloads: **uma caixa por pasta protegida**, na primeira vez.
- As três foram permitidas na tela em cerca de dois segundos cada, e o acesso funcionou. O teste do launchd foi interrompido nesse ponto.
- O macOS guardou as permissões pelo caminho do arquivo do daemon.

Não testado: daemon cujo arquivo fica dentro de `~/Documents`; se recompilar o daemon faz o macOS perguntar de novo; o que acontece quando a permissão é negada. Ficam para a fase 3.

### Depende de teste manual

Tudo o que exige olhar a janela ou usar o teclado de verdade: aparência do terminal, teclas especiais e acentos pelo teclado, copiar e colar, rolagem, foco entre a barra lateral e o terminal (R8), atalhos do app com o terminal em foco, e se a tela restaurada **parece** igual. O risco R8 continua sem verificação.

### Só pacote Swift, sem projeto Xcode

Confirmado para o protótipo: a janela SwiftUI com o terminal em AppKit compila e abre a partir do pacote, sem projeto Xcode. O empacotamento como `.app` continua para a fase 3.
