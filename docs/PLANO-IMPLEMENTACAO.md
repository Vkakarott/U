# Plano de implementação

Este plano segue [IDEIA.md](../IDEIA.md) e [SPEC-V1.md](SPEC-V1.md). Cada fase da v1 só começa após autorização explícita do Lucas. Estado atual: fase 0 concluída; fase 1 executada, com a parte de teste manual pendente; fase 2 executada; fase 3 não autorizada.

## Fase 0 — Esqueleto do repositório

**Objetivo:** deixar a base de módulos, testes e comandos locais pronta, sem comportamento de produto.

**Entrega:** pacote Swift com os executáveis `HubAgentApp` e `HubAgentDaemon`, módulo `HubAgentShared`, testes triviais, regras de estilo e `Makefile`.

**Verificação:** `make check` compila, executa os três testes e passa no lint de estilo.

**Depende de:** nada.

**Escopo:** preparação; não implementa recurso da v1.

## Fase 1 — Protótipo descartável do caminho do terminal

**Objetivo:** reduzir o risco R1 antes de qualquer implementação permanente: um PTY no daemon passa bytes ao SwiftTerm no app, recebe entrada e restaura a tela após reconectar.

**Entrega:** experimento isolado e descartável, num pacote próprio fora de `Sources/` para que descartá-lo não toque nos módulos permanentes, com um daemon de teste, SwiftTerm sem `LocalProcessTerminalView`, emulador sem interface, captura de tela restaurada e testes manuais com programas de tela cheia, incluindo Claude Code e Codex quando disponíveis.

**Verificação:** documentar os casos testados, comparar tela antes/depois de reanexar, medir comportamento com saída volumosa e decidir A5 (quem responde às consultas do terminal). Deve incluir tamanho igual nos dois emuladores e não ter lacuna/duplicação na troca de snapshot para saída ao vivo. O spec pede que três pontos sejam validados cedo, então entram aqui: o terminal em AppKit dentro de uma janela SwiftUI recebendo todas as teclas (R8); o daemon de teste iniciado pelo launchd abrindo o shell de login numa pasta dentro de `~/Documents`, com `claude` e `codex` encontrados e os pedidos de permissão do macOS observados (R3); e qual versão do SwiftTerm fixar (P3).

**Depende de:** Fase 0. Aprovação explícita do Lucas para iniciar a v1.

**Escopo:** v1, mas o código do experimento pode ser removido depois da decisão.

**Resultado:** executada em `Prototypes/TerminalPath`; detalhes na seção 11 do spec.

- Respondido com teste automático: o terminal que vive no daemon funciona pelo protocolo; a tela restaurada sai idêntica com shell, vim, less, top, Claude Code e Codex; não há lacuna nem duplicação; A5 tem resposta (só o daemon responde); a versão do SwiftTerm indicada é a publicada 1.99.0; o shell de login a partir do launchd encontra `claude` e `codex`; o macOS pede permissão em nome do daemon, uma caixa por pasta protegida.
- Pendente de teste manual pelo Lucas (roteiro em `Prototypes/TerminalPath/README.md`): o que aparece na janela, teclado de verdade, copiar e colar, foco entre SwiftUI e AppKit (R8) e atalhos do app.
- Não testado, movido para a fase 3: daemon cujo arquivo fica dentro de `~/Documents`, nova pergunta de permissão ao recompilar, permissão negada.
- A pasta do protótipo pode ser apagada quando a fase 2 tiver reaproveitado o que interessa (a peça da tela pronta, o rastreador de modos e os roteiros de teste).

## Fase 2 — Fundamentos permanentes do daemon e protocolo

**Objetivo:** criar a base testável para sessões de terminal, sem interface de produto completa.

**Entrega:** `SessionManager`, abstrações de PTY e emulador sem interface, a peça que gera a tela pronta ao reanexar (P3), rótulo por sessão e registro das sessões que terminaram sozinhas (seção 5.4 do spec), protocolo binário versionado, servidor Unix socket com permissões do dono e cliente do daemon; limites de histórico e testes de enquadramento/versão.

**Verificação:** testes cobrem criação, anexar/desanexar, entrada, saída, redimensionamento, término de sessão e incompatibilidade de protocolo. Uma sessão continua sendo lida sem cliente anexado.

**Acrescentado pelo protótipo:** além do que está na entrega, a fase 2 precisa de: rastreador de modos próprio e cópia da tela escondida por programas de tela cheia (o SwiftTerm não expõe nenhum dos dois); reenvio da tela pronta depois de redimensionar; só o daemon responde às consultas dos programas, e o app envia as cores do tema ao daemon; encerramento de sessão em dois passos (desligamento, depois forçado); fila limitada para cliente lento; SwiftTerm 1.99.0 fixado e compilado com otimização também em desenvolvimento; a comparação célula a célula do protótipo como teste automático permanente. O SwiftLint entra nesta fase, com aviso ao Lucas antes de instalar.

**Resultado:** executada; detalhes na seção 12 do spec.

- Entregue: protocolo binário com acordo de versão, transporte por Unix socket só para o dono, emulador sem interface com tela pronta, sessões com shell de login, `SessionManager`, servidor, cliente do app e os tratamentos dos achados da fase 1. SwiftLint 0.65.1 instalado pelo Homebrew e em uso no `make check`.
- Verificado por teste automático: tudo o que a verificação desta fase pede, mais um teste que sobe o executável do daemon, usa um terminal pelo cliente do app e o encerra.
- Em uso como hipótese de trabalho, aguardando confirmação explícita do Lucas: só o daemon responde às consultas dos programas, e SwiftTerm 1.99.0 fixado.
- Fora desta fase por decisão: nada de launchd, de permissões do macOS nem de janela.

**Depende de:** decisão e aprendizados da Fase 1.

**Escopo:** v1. WebSocket, autenticação e múltiplos clientes ficam para depois.

## Fase 3 — Ciclo de vida e ambiente do daemon

**Objetivo:** tornar o daemon independente do app sem interromper terminais de uso durante desenvolvimento.

**Entrega:** integração com launchd, empacotamento da versão de uso como `.app` instalada num local estável (o pacote Swift sozinho gera só executáveis soltos), identidades separadas para daemon de desenvolvimento e de uso, socket/pastas/dados isolados, negociação de versão e fluxo confirmado para atualização e parada explícita.

**Verificação:** fechar ou encerrar o app não mata uma sessão; desenvolvimento não encontra nem altera sessões de uso; incompatibilidade pede confirmação antes de trocar o daemon; shell de login encontra o ambiente esperado.

**Herdado da fase 2:** o lugar definitivo do socket e das pastas do daemon (hoje um arquivo provisório na pasta temporária); a versão do daemon informada no acordo de versão, que é a base do fluxo de atualização; compilar o daemon de desenvolvimento com otimização (`make run-daemon` já faz); o caso da pasta que existe mas não permite entrada, em que o shell abre na pasta do daemon sem avisar; e as duas hipóteses de trabalho que aguardam confirmação.

**Acrescentado pelo protótipo:** o macOS mostra uma caixa de permissão em nome do daemon para cada pasta protegida, na primeira vez. Falta verificar aqui: daemon instalado dentro de `~/Documents`, se recompilar faz o macOS perguntar de novo (pesa no daemon de desenvolvimento) e o comportamento quando a permissão é negada.

**Depende de:** Fase 2.

**Escopo:** v1. Assinatura, notarização e início automático no login ficam para depois.

## Fase 4 — Dados locais do app

**Objetivo:** persistir projetos e abas sem acoplar o restante do app ao JSON.

**Entrega:** modelos com IDs estáveis e versão de esquema, `ProjectStore`, escrita atômica, validação de diretório e reconciliação de abas/sessões ao iniciar.

**Verificação:** testes de leitura/escrita/migração inicial e recuperação de cenários da seção 5.4 do spec (sessão viva, terminada, ausente, órfã e órfã de projeto apagado).

**Depende de:** Fase 2; Fase 3 para a reconciliação com daemon real.

**Escopo:** v1. SQLite, chat e transferência da propriedade dos dados para o daemon ficam para depois.

## Fase 5 — TerminalSurface e UI mínima

**Objetivo:** entregar projetos e abas utilizáveis, mantendo SwiftTerm isolado do restante do app.

**Entrega:** estrutura SwiftUI, ponte AppKit por `TerminalSurface`, sidebar de projetos, abas com criar/fechar/renomear/trocar, foco e atalhos; confirmações e mensagens em pt-BR.

**Verificação:** um projeto abre uma aba na raiz, entrada/saída/resize chegam ao daemon, `exit` fecha a aba, fechar o app e reabrir restaura a tela, e apagar projeto nunca toca a pasta no disco.

**Depende de:** Fases 2, 3 e 4.

**Escopo:** v1. Painéis divididos, arrastar/reordenar, atividade, tipos de aba e atalhos para agentes ficam para depois.

## Fase 6 — Robustez para uso diário

**Objetivo:** validar o critério de pronto da v1 e os riscos operacionais restantes.

**Entrega:** tratamento de falhas do daemon e de diretório ausente, encerramento de árvore de processos, logs estruturados, limites de memória, documentação de permissões e roteiro de teste manual de um dia.

**Verificação:** usar o hub-agent durante um dia com Claude Code e Codex em terminais; atualizar uma versão sem derrubar sessões até a confirmação; reinício do daemon/Mac recria apenas as sessões perdidas conforme o spec.

**Depende de:** Fase 5.

**Escopo:** v1. Distribuição, CI em serviço externo e acesso de rede ficam para depois.

## Depois da v1

Chat, quadro de cards, atalhos de agente, múltiplos clientes por sessão, Android, WebSocket, Tailscale, autenticação, pareamento, SQLite e eventual migração de projetos/abas para o daemon não pertencem à v1. Cada um precisa de uma fase própria após reavaliar as fronteiras definidas nesta spec.
