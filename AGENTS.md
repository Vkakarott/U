# hub-agent

App pessoal para macOS que organiza projetos e terminais. A fonte de verdade do produto é [IDEIA.md](IDEIA.md) e, para a v1, [docs/SPEC-V1.md](docs/SPEC-V1.md). Leia ambos integralmente antes de alterar arquitetura ou escopo.

## Estrutura

- `Sources/HubAgentApp`: executável do app macOS. Hoje só tem o `DaemonClient`; no futuro, SwiftUI para a estrutura e AppKit atrás de `TerminalSurface`.
- `Sources/HubAgentDaemon`: executável separado dono das sessões de terminal; não conhece projetos, abas ou interface. `Emulator/` (estado da tela, atrás de `HeadlessEmulator`), `Sessions/` (terminais e `SessionManager`), `Server/` (socket e clientes).
- `Sources/HubAgentShared`: protocolo app–daemon (mensagens, formato binário, versão); não depende de UI, PTY ou transporte concreto.
- `Sources/HubAgentTransport`: Unix socket local, usado pelo servidor do daemon e pelo cliente do app.
- `Tests/*Tests`: testes por módulo.
- `Prototypes/TerminalPath`: protótipo descartável da fase 1, num pacote Swift separado. Não é base para código permanente; leia o `README.md` dele antes de mexer.
- `docs/`: especificação e plano de implementação.

O repositório usa apenas Swift Package Manager. O pacote pode ser aberto diretamente no Xcode e preserva módulos, testes e executáveis separados sem manter um `.xcodeproj` duplicado. O pacote gera executáveis soltos, não um `.app`: o empacotamento da versão de uso está previsto na Fase 3 do plano. Criar um projeto Xcode só se essa etapa mostrar que é necessário.

## Comandos

Use `make help` para a lista. Os principais são:

- `make build`
- `make test`
- `make format`
- `make lint`
- `make check`
- `make run` (app ainda vazio) e `make run-daemon` (daemon de verdade, compilado com otimização, num socket provisório)

`make lint` usa o `swift format` que acompanha a toolchain e o SwiftLint (`brew install swiftlint`) com `.swiftlint.yml`. Sem o SwiftLint instalado o `make lint` avisa e segue só com o formatador, então confira que ele está instalado antes de confiar no resultado. Não há CI externo por enquanto.

## Convenções

- Texto de interface em pt-BR. Código, identificadores, nomes de arquivos e comentários em inglês.
- Não implemente terminal, daemon, interface de produto ou protocolo da v1 sem autorização explícita do Lucas (o chat do Termhub conta).
- Mantenha as fronteiras do spec: UI ↔ `TerminalSurface`; app ↔ daemon somente pelo protocolo; app ↔ disco somente por `ProjectStore`; transporte ↔ `SessionManager`.
- O daemon roda inteiro numa fila serial; as classes dele são confinadas a essa fila. Não chame nada do daemon de outra thread.
- Nunca altere configuração global do processo no daemon (umask, pasta atual, variáveis de ambiente): todo terminal aberto herda.
- Testes que abrem terminais de verdade ficam dentro de `TerminalTests` (em `Tests/HubAgentDaemonTests/DaemonTestSupport.swift`), que os roda um de cada vez.
- Uma função tem uma responsabilidade. Não deixe `print` de depuração em produção; use logger quando existir implementação.
- Rode `make format` e `make check` antes de todo commit e não faça commit com teste falhando. Faça um commit por funcionalidade concluída, sem misturar mudanças não relacionadas.
- Commits usam Conventional Commits, em inglês e no imperativo, sem atribuição de IA ou coautoria.
- Nada toca um remoto sem pedido explícito do Lucas, a cada vez: sem push, PR, issue, comentário nem criação ou alteração de remoto. A autorização para uma ação não vale para a seguinte.
