# Revisão independente do Codex

Revisado até o commit `4043464fb1272a0fdb4b02106cdd8dac4a123531` (`feat: give each installation its own daemon, socket and folders`). A revisão considera somente arquivos desse commit e anteriores. O diretório de trabalho continha alterações não commitadas de outra fase, que não foram usadas como evidência.

## Achados abertos

### Alta — o novo fluxo de atualização não consegue parar o daemon da versão anterior

- **Arquivo e linha:** `Sources/HubAgentShared/ProtocolVersion.swift:7-8`; `Sources/HubAgentShared/MessageCoding.swift:60-71,90-106`; `Sources/HubAgentDaemon/Server/ClientConnection.swift:159-163`.
- **Cenário:** o daemon já em uso é o da fase 2 (`31d583e`), que anuncia protocolo 1 e não conhece o tipo de mensagem 11. O app/daemon novo ainda também anuncia protocolo 1, então o handshake tem sucesso e não há indicação de incompatibilidade pelo protocolo. Se o fluxo novo tentar substituí-lo enviando `shutdown`, o daemon antigo interpreta o tipo 11 como desconhecido, responde falha e continua rodando; o novo daemon não consegue tomar a trava da instalação. Portanto a promessa do comentário — parar um daemon que “não compartilha protocolo” — não vale para a versão anterior real, e a atualização fica bloqueada ou exige intervenção manual.
- **Correção sugerida:** versionar a capacidade de desligamento de forma negociável e ter um caminho de substituição compatível com o daemon anterior (por exemplo, o app usa o mecanismo de ciclo de vida/launchd para parar versões que não anunciam suporte a `shutdown`). Não tratar protocolo 1 como compatível depois de adicionar operação obrigatória sem capacidade negociada. Testar app novo contra o executável/servidor da fase 2 e confirmar que ele identifica a limitação e completa a troca sem tocar em terminais de outra instalação.
- **Confirmação:** somente por leitura. Os testes exercitam `shutdown` apenas contra o servidor novo e não cobrem um daemon da fase 2 (`Tests/HubAgentDaemonTests/LifecycleTests.swift:169-194`).

### Alta — encerrar uma sessão pode deixar processos dos trabalhos do shell vivos

- **Arquivo e linha:** `Sources/HubAgentDaemon/Sessions/Session.swift:94-101`; `Sources/HubAgentDaemon/Sessions/PseudoTerminal.swift:65-68`.
- **Cenário:** em uma aba, o usuário inicia um processo que ignora `SIGHUP` (por exemplo, `nohup sleep 1000 &`) ou um trabalho que o shell põe em outro grupo de processo. Ao fechar a aba, o código envia `SIGHUP` e, um segundo depois, `SIGKILL` somente para o PID do shell. Um trabalho em outro grupo pode ignorar o primeiro sinal e sobreviver ao segundo, porque o segundo mata apenas o shell. Isso contradiz o fluxo 5.3 e R4 do spec: fechar a aba precisa encerrar o shell **e tudo que roda nele**.
- **Correção sugerida:** tratar o terminal como uma árvore/sessão de processos ao encerrar: sinalizar o grupo de primeiro plano do PTY e todos os grupos descendentes (inclusive trabalhos em segundo plano) e repetir com sinal forçado após o prazo; alternativamente, adotar um supervisor que mantenha essa árvore identificável. Cobrir ao menos trabalho em primeiro plano, trabalho em segundo plano com `nohup` e filho que ignora `SIGHUP`, verificando que nenhum PID permanece vivo.
- **Confirmação:** somente por leitura. Os testes atuais cobrem um shell que ignora o sinal, mas não um processo filho ou trabalho em outro grupo (`Tests/HubAgentDaemonTests/SessionTests.swift:78-87`).

### Alta — uma tela restaurada válida pode ultrapassar o limite do protocolo e desconectar o cliente

- **Arquivo e linha:** `Sources/HubAgentShared/Framing.swift:18-29`; `Sources/HubAgentDaemon/Server/ClientConnection.swift:74-93`; `Sources/HubAgentDaemon/Sessions/SessionManager.swift:39-44`.
- **Cenário:** o protocolo recusa ao receber corpos acima de 32 MiB, mas não há limite equivalente ao produzir `DaemonMessage.screen`. O tamanho aceito para o terminal chega a 1.000 colunas × 1.000 linhas e cada sessão conserva 10.000 linhas de histórico. Uma saída com muitos atributos alternados faz `ScreenSerializer` acrescentar sequências SGR para cada célula, portanto a tela pronta pode exceder 32 MiB mesmo com dados válidos. O servidor a enquadra e a coloca inteira na fila; o `DaemonClient` a rejeita como `frameTooLarge` e a reconexão falha. Pelo mesmo caminho, a primeira tela pode exceder sozinha a marca de 4 MiB da fila de cliente lento, que deixa de ser um limite de memória efetivo.
- **Correção sugerida:** definir e aplicar um único orçamento para a tela pronta antes de enfileirá-la, compatível com o limite de frame e com a fila. A solução que preserva a restauração é dividir a tela em mensagens/fatias com fronteiras seguras e protocolo explícito de reconstrução; como alternativa, reduzir e validar conjuntamente tamanho máximo, histórico e serialização. Testar uma tela no maior tamanho aceito com atributos alternados, confirmando que o cliente restaura sem desconectar e que a memória pendente nunca passa do orçamento.
- **Confirmação:** somente por leitura. O teste de cliente lento usa cerca de 2 MiB de saída e não alcança o limite de um snapshot (`Tests/HubAgentDaemonTests/ServerTests.swift:255-280`).

### Média — falha parcial de handshake impede tentativas posteriores de reconexão

- **Arquivo e linha:** `Sources/HubAgentApp/DaemonClient.swift:22-24,33-53,85-102`.
- **Cenário:** o daemon aceita a conexão e envia apenas uma parte do frame de `welcome`, então cai/reinicia. `connect()` lança ao receber o fechamento, mas o `FrameDecoder` de propriedade mantém os bytes parciais. Na próxima tentativa, ele concatena o começo da resposta do daemon novo com os bytes do daemon antigo; a decodificação fica corrompida (ou entrega uma resposta errada). Isso impede justamente a reconexão necessária quando o daemon é reiniciado.
- **Correção sugerida:** usar um decodificador e backlog locais durante cada tentativa de handshake e instalá-los no estado do cliente somente depois de receber um `welcome` válido; ao falhar, fechar a conexão e limpar todo estado de leitura da tentativa. Acrescentar teste que interrompe a primeira resposta no meio do cabeçalho e confirma que uma segunda conexão limpa funciona.
- **Confirmação:** somente por leitura. Os testes cobrem resposta completa, rejeição e ausência de daemon, não resposta truncada seguida de nova conexão (`Tests/HubAgentAppTests/HubAgentAppTests.swift:84-125`).

### Baixa — o servidor aceita `hello` depois do acordo de versão

- **Arquivo e linha:** `Sources/HubAgentDaemon/Server/ClientConnection.swift:159-198`.
- **Cenário:** depois de concluir o handshake, um cliente envia outro `hello`. O teste especial da linha 156 é avaliado antes da checagem de estado e o servidor envia outro `welcome`, embora o spec determine que a primeira mensagem da conexão é a troca de versão. Um cliente com leitura pendente pode interpretar esse `welcome` extra como resposta a outra operação e perder a sincronização do protocolo.
- **Correção sugerida:** aceitar `hello` somente quando `hasCompletedHandshake` é falso; qualquer `hello` posterior deve encerrar a conexão como mensagem malformada/protocolo inválido. Cobrir a sequência `hello`, `hello` e confirmar que a segunda é recusada.
- **Confirmação:** somente por leitura.
