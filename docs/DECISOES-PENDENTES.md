# Decisões pendentes

Escrito enquanto o Lucas estava fora (a partir de 2026-10-10). Aqui fica tudo o que foi escolhido sem consulta, o que cada escolha custa se estiver errada, e os passos que só ele pode fazer. O estado de cada fase está em [PLANO-IMPLEMENTACAO.md](PLANO-IMPLEMENTACAO.md).

## 1. Passos que esperam o Lucas

Nada aqui foi executado. Cada item tem o comando exato.

*(preenchido ao longo das fases; ver o fim de cada seção de fase abaixo)*

## 2. Hipóteses de trabalho herdadas (ainda sem confirmação)

| Hipótese | Custo de reverter |
|---|---|
| Só o programa de fundo responde às consultas dos programas (A5) | Pequeno: um ponto no código e dois testes. Traz de volta o problema medido: com o app fechado os programas ficam sem resposta. |
| SwiftTerm 1.99.0 fixado | Cerca de um dia, quase todo em refazer os testes de restauração de tela. |
| Histórico de 10.000 linhas, 150 ms antes de reenviar a tela, fila de 4 MB por cliente, 1 s antes do encerramento forçado | Trocar um número em `SessionConfiguration` ou `ServerConfiguration`. |

## 3. Escolhas feitas na fase 3

| # | Escolha | Outra leitura possível | Custo se estiver errada |
|---|---|---|---|
| 3.1 | As duas cópias (uso e desenvolvimento) se distinguem assim: o app empacotado, com identificador `com.hubagent.app`, é a de uso; qualquer coisa rodando do código-fonte é a de desenvolvimento. A variável `HUBAGENT_ENVIRONMENT` força uma ou outra. | Escolher por argumento ou por configuração de compilação. | Pequeno: a regra está numa função só (`Installation.kind`). |
| 3.2 | Pastas: `~/Library/Application Support/HubAgent` (uso) e `HubAgent-Dev` (desenvolvimento). Dentro de cada uma: `daemon.sock`, `daemon.lock`, `daemon.log`, `projects.json`. Nomes no launchd: `com.hubagent.daemon` e `com.hubagent.daemon.dev`. | Socket na pasta temporária; dados em `~/.hub-agent`. | Pequeno enquanto não houver dados de verdade: tudo sai de `Installation`. Depois de usar, mudar exige mover o arquivo de projetos. |
| 3.3 | Uma só instância por cópia é garantida por uma trava de arquivo, não pelo launchd. | Confiar só no launchd. | Nenhum: a trava continua valendo com o launchd e cobre o caso de iniciar o programa de fundo como processo comum. |
| 3.4 | A parada explícita é uma mensagem do protocolo (`shutdown`), aceita mesmo antes do acordo de versão, para que um app incompatível consiga trocar o programa de fundo. Quem consegue conectar no socket já pode rodar comandos como o dono, então isso não abre nada novo. | Parar só pelo launchd (`launchctl bootout`). | Pequeno: remover a mensagem e usar o launchd. |
| 3.5 | Ao parar, o programa de fundo encerra os terminais e só então sai (espera no máximo 2 s). | Sair na hora. | Nenhum relevante. |
| 3.6 | Pasta que existe mas não deixa entrar: o programa de fundo agora recusa abrir o terminal e o app recebe um erro próprio (`workingDirectoryNotAccessible`). A checagem abre a pasta como o shell abriria, então numa pasta protegida pelo macOS é nesse momento que a caixa de permissão aparece, em nome do programa de fundo. | Deixar o shell abrir em outra pasta. | Pequeno. Não foi testado com permissão negada pelo macOS, só com permissão de arquivo. |
| 3.7 | Sem argumentos, o programa de fundo serve a cópia de desenvolvimento. | Exigir o argumento. | Nenhum: evita que um processo solto alcance os terminais de uso. |
