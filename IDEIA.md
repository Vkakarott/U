# hub-agent

## Visão

Um aplicativo pessoal para desktop que reúne o essencial do Termhub e do Orca: uma experiência simples para trabalhar com projetos, agentes, terminais e chat, rodando inteiramente de forma local. O objetivo não é reproduzir todos os recursos de nenhuma das referências, mas construir uma ferramenta própria, focada no fluxo de trabalho diário.

O produto será construído em etapas. A v1 é apenas o desktop macOS, enxuto, com projetos e abas de terminal: o básico para o próprio hub-agent ser usado no desenvolvimento das versões seguintes. O detalhamento está em [docs/SPEC-V1.md](docs/SPEC-V1.md).

## Referências

### Termhub

O Termhub já faz parte do fluxo de trabalho pretendido. Dele, o hub-agent preserva:

- simplicidade da interface e do modelo mental;
- organização por projetos;
- agentes e terminais dentro de cada projeto, em abas;
- chat como parte central da experiência.

Motivação para não depender exclusivamente dele: é hospedado e externo ao controle do usuário, portanto sua evolução e prioridades não são próprias. Além disso, o terminal do Termhub passa pelo tmux, que impõe adaptações de comandos, teclas e scroll; o hub-agent quer o terminal mais nativo possível.

### Orca

Do Orca, o hub-agent toma como direção:

- aplicativo desktop;
- execução local, sem serviço hospedado obrigatório;
- possibilidade de um aplicativo mobile complementar.

O escopo, porém, deve permanecer menor e mais simples que o do Orca.

## Produto desejado

- Aplicativo desktop pessoal, simples como o Termhub.
- Todos os dados e processos operando localmente, sem hospedagem.
- Projetos que agrupam agentes e terminais.
- Integração com ferramentas de agentes como Claude Code e Codex. Na v1 elas rodam dentro das abas de terminal, digitadas pelo usuário; atalhos e integração própria vêm depois.
- Chat como recurso essencial, associado ao fluxo dos projetos e agentes (pós-v1).
- Aplicativo mobile complementar para controlar terminais reais em execução no desktop (pós-v1).

## Diferencial principal: controle mobile de terminal

O aplicativo mobile deve ir além de acompanhar ou controlar apenas conversas. Ele precisa oferecer controle remoto de um terminal real do desktop, incluindo:

- visualizar a tela ou a saída atual do terminal;
- enviar texto e comandos como entrada;
- aprovar ou recusar permissões solicitadas por agentes;
- pressionar teclas e combinações necessárias ao fluxo de terminal;
- interagir com sessões de Claude Code, Codex e ferramentas semelhantes como se estivesse diante do desktop.

Esse ponto resolve a principal limitação percebida no app mobile beta do Termhub, que controla somente chats.

O mobile continua sendo o diferencial do produto, mas não entra na v1. A v1 já nasce com a base que ele exige: os terminais rodam num daemon separado do app, que depois passa a atender também o mobile.

## Princípios de escopo

- Construir apenas o que é útil no dia a dia.
- Priorizar simplicidade, autonomia e controle local.
- Evitar replicar a abrangência do Orca.
- Não introduzir hospedagem como requisito do produto.
- Projetar desktop e mobile como partes de um único fluxo de trabalho pessoal.
- Versões enxutas, mas com arquitetura que cresça sem refazer a base.

## Próximos detalhes a definir

- Qual dos dois lados (app ou daemon) responde às consultas que os programas fazem ao terminal. Fica em aberto até o protótipo; detalhes em [docs/SPEC-V1.md](docs/SPEC-V1.md).
- Atalhos para abrir Claude Code e Codex direto, e o que mais diferenciar um agente de um terminal comum (pós-v1).
- Modificações em relação ao modelo de projetos e de chat do Termhub.
- Quadro de cards: escopo e modelo (fica fora da v1).
- Comportamento do controle remoto de terminal e das aprovações de permissão no mobile.
- Detalhes da conexão mobile fora da rede local (autenticação, pareamento, qual evolução seguir depois do Tailscale).
- Segurança e backup dos dados locais.

## Decisões já tomadas

### Produto

- Plataformas iniciais: macOS no desktop e Android no mobile.
- O app mobile deve conectar ao desktop tanto na rede local quanto fora dela.
- Projetos devem seguir o modelo do Termhub para organização de agentes e terminais, com algumas modificações ainda a definir.
- Cada projeto aponta para um diretório local. Não existe a camada de "máquinas" do Termhub.
- Os terminais serão locais, em vez de Termx.
- O chat deve seguir o modelo do Termhub, com algumas modificações ainda a definir. Vai existir nas duas formas: por projeto e global.

### v1

- Objetivo: só o desktop macOS, bem enxuto, com o básico para o próprio hub-agent ser usado no desenvolvimento das próximas versões.
- Entra: projetos e abas de terminal. Toda aba é um terminal normal aberto na raiz do projeto, como no Termhub, com o shell de login do usuário e o ambiente normal dele.
- Não existe aba de agente na v1: o usuário digita `claude` ou `codex` no terminal. Atalhos para abri-los direto ficam para depois.
- Abas só com o básico e funcional: criar, fechar (com confirmação se houver algo rodando), trocar por clique e por atalho, renomear. Ficam fora painéis divididos, reordenar arrastando e indicador de atividade.
- Fechar a aba encerra o terminal, e digitar `exit` no terminal fecha a aba. Fechar o app não: os terminais continuam e voltam com a tela restaurada ao reabrir.
- Se o terminal de uma aba morrer (daemon ou Mac reiniciou), a aba continua e abre um terminal novo na raiz do projeto; o histórico anterior se perde.
- Apagar um projeto fecha as abas e encerra os terminais dele, com confirmação, sem nunca tocar na pasta.
- Se a pasta do projeto sumiu, o app avisa e não abre o terminal.
- Fica fora: chat, quadro de cards, app Android e acesso fora da rede local.
- Só execução local no Mac do Lucas, na versão do macOS que ele usa. Sem assinatura nem notarização por enquanto.

### Tecnologia

- App macOS nativo em Swift: SwiftUI na estrutura (barra lateral, abas) e AppKit no terminal. Electron e Tauri foram descartados.
- SwiftTerm como emulador de terminal, atrás de uma interface própria que permita trocá-lo por libghostty no futuro.
- Sem tmux.
- Daemon de PTYs já na v1: os PTYs rodam num processo separado e o app é cliente dele. Assim os terminais sobrevivem ao fechamento ou crash do app e, depois, atendem o mobile.
- O daemon inicia junto com o app e continua rodando depois que o app fecha. Existe um daemon de desenvolvimento separado do daemon em uso, para que testar o hub-agent não derrube os terminais em que se está trabalhando.
- O daemon mantém o estado da tela de cada terminal num emulador sem interface e envia a tela pronta quando o app reanexa, como fazem o tmux e o terminal do VS Code.
- Na v1 o app é dono da lista de projetos e abas e o daemon cuida só das sessões de terminal. Isso pode migrar para o daemon quando o mobile entrar.
- Um cliente por sessão de terminal na v1; vários só quando alguma funcionalidade exigir.
- Daemon escrito em Swift, no mesmo repositório do app, iniciado pelo launchd.
- App e daemon conversam por Unix socket local, com um protocolo simples de mensagens pensado para ser reaproveitado pelo mobile.
- A tela restaurada é gerada por uma peça própria, que lê o estado do emulador do daemon.
- Projetos e abas guardados num arquivo JSON local; SQLite só quando o chat entrar.

### Conexão mobile fora da rede local (pós-v1, sem prioridade)

- Tailscale primeiro.
- Evolução possível: Headscale ou relay próprio com criptografia ponta a ponta numa VPS gratuita. Sem gasto com VPS paga.
- A camada de conexão fica abstraída: o app conhece só um endpoint.
