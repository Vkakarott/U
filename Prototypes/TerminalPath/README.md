# Protótipo da fase 1 — caminho do terminal

Protótipo **descartável** da fase 1 do [plano](../../docs/PLANO-IMPLEMENTACAO.md). É um pacote Swift separado: apagar esta pasta não afeta o pacote principal. Os resultados estão registrados na seção 11 do [spec](../../docs/SPEC-V1.md).

## O que tem aqui

- `Sources/proto-daemon`: programa de fundo de teste. Cria o terminal de verdade, mantém a tela num emulador sem janela e atende um cliente por socket.
- `Sources/proto-app`: janela SwiftUI com o terminal do SwiftTerm em AppKit, alimentado só pelo daemon.
- `Sources/proto-probe`: cliente sem janela usado nos testes automáticos. Faz o papel do app e compara, célula a célula, a sua tela com a do daemon.
- `Sources/ProtoCore`: protocolo de mensagens, a peça que gera a tela pronta (`ScreenSerializer`), o rastreador de modos e a comparação de telas.
- `Checks/`: roteiros dos testes automáticos e `run.sh`.
- `manual-test.sh`: abre a janela para o teste manual.

## Testes automáticos

```sh
Checks/run.sh                 # shell, vim, less, top, consultas e saída volumosa
Checks/run.sh --with-agents   # também abre Claude Code e Codex, sem enviar nenhum prompt
```

`SAME` significa que a tela do cliente ficou idêntica à do daemon (texto, cores, atributos, histórico, cursor e modos). `DIFF` lista as diferenças.

## Teste manual da janela

```sh
./manual-test.sh        # compila, inicia o daemon de teste e abre a janela
./manual-test.sh stop   # encerra o daemon de teste ao terminar
```

O daemon de teste **não** usa launchd e não instala nada: é um processo comum, que continua rodando quando a janela fecha e termina com `./manual-test.sh stop`.

O que observar:

1. **Abrir.** A janela mostra uma barra lateral e o terminal, com a mensagem "Anexado: terminal novo". O prompt aparece na raiz do repositório.
2. **Digitar.** `ls -G` mostra cores. Acentos (`ação`, `é`) e emoji aparecem certos. Colar com ⌘V e copiar uma seleção com ⌘C funcionam.
3. **Teclas especiais.** Seta para cima traz o comando anterior; Tab completa; Ctrl-C interrompe `sleep 100`; Ctrl-R abre a busca no histórico; Option+seta anda por palavra.
4. **Redimensionar.** Arraste a borda da janela e rode `stty size`: os números acompanham o tamanho. O texto não fica cortado nem embaralhado.
5. **Tela cheia.** Abra `vim Package.swift` (setas, Esc, `:q!`) e depois `claude` (setas nos menus, Shift+Tab, rolagem do mouse). Tudo responde como num terminal comum.
6. **Foco.** Clique no "Campo de teste de foco" e digite: o texto vai para o campo, não para o terminal. Clique no terminal: volta a digitar nele.
7. **Atalho do app.** Com o foco no terminal, aperte ⌘T: o contador "⌘T recebido" sobe e nenhum `t` aparece no terminal.
8. **Fechar e reabrir.** Com o `claude` aberto, feche a janela com ⌘Q e rode `./manual-test.sh` de novo. A mensagem deve ser "terminal que já estava vivo, tela restaurada" e a tela deve estar igual à de antes. Saia do `claude`: o histórico do shell que estava por trás volta com as cores.
9. **Histórico.** Rode `seq 1 500`, feche, reabra e role para cima: o histórico está lá.
10. **Encerrar.** `exit` no terminal mostra "Terminal encerrado".

## Limitações conhecidas do protótipo

- Um terminal só, sem abas nem projetos.
- Se o cliente for lento, o daemon espera por ele e o terminal fica lento junto.
- Redimensionar enquanto sai muito texto pode deixar o histórico do app diferente do histórico do daemon até a próxima reconexão.
- A cor de fundo que o daemon informa aos programas é a padrão dele, não a do tema da janela.
