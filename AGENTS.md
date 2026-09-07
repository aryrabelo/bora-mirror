# bora-mirror — fork de encaixe do herdr-mirror

Plugin que espelha workspaces de máquinas ssh dentro de um bora local: um
daemon por host, uma workspace local real por workspace remota, agrupadas por
máquina na sidebar. Fork de [`nikok6/herdr-mirror`](https://github.com/nikok6/herdr-mirror)
(MIT), cujo alvo é o herdr upstream; este fork existe para encaixá-lo no fork
`bora` e na frota do dono. Branch de trabalho: `bora-fit`. Upstream em
`git remote upstream`.

**Não reescreva a arquitetura do upstream.** O valor deste fork é herdar o que
já funciona (reconciliação por evento com debounce, id-map persistido, backoff,
transporte ssh com ControlMaster, relay socat/python quando não há forward) e
pagar só a diferença de encaixe. Antes de escrever qualquer módulo novo, leia o
comentário de topo do arquivo correspondente — o upstream documenta o *porquê*
de cada decisão, e a maioria das ideias "óbvias" de melhoria já está respondida
lá.

## O contrato deste fork

Cinco defeitos de encaixe, todos medidos contra máquina real (2026-09-07). São
a razão do fork existir e nenhum deles é opinião:

1. **O binário local não se chama `herdr`.** `HERDR_MIRROR_LOCAL_BIN` manda; sem
   ele, os candidatos são probados em ordem e um binário AUSENTE cai pro nome
   seguinte — um que rodou e se comportou mal é erro de verdade, não motivo pra
   tentar outro nome (`src/util.rs`, `Env::resolve`).
2. **O binário remoto também não.** O auto-resolver tenta `bora`, `herdr`,
   `~/.local/bin/bora`, `~/.local/bin/herdr` e falha com 127 explícito
   (`src/config.rs`, `remote_herdr_expr`). O PATH de um `ssh host cmd`
   não-interativo NÃO tem `~/.local/bin` no macOS, então sem isso um remoto
   chamado `bora` morre com `command not found` e chega como snapshot vazio.
   O teste roda a expressão sob um `sh` real contra binários de mentira — não
   compara com uma segunda cópia dela mesma.
3. **O diretório de config segue o namespace do servidor.** Num fleet bora a
   config do plugin mora em `~/.config/bora/plugins/config/mirror`, não em
   `~/.config/herdr/...`. `candidate_dirs` (`src/util.rs`) sonda
   `HERDR_NAMESPACE`, `bora` e `herdr`, nessa ordem. A divergência é invisível
   do lado do daemon: o bora injeta `HERDR_PLUGIN_CONFIG_DIR` em ação de
   plugin, mas NÃO num shell — então `herdr-mirror status` digitado no
   terminal respondia "no hosts.toml found" enquanto o daemon espelhava do
   arquivo real.
4. **A pasta por máquina não precisa de banda nova de sidebar.** Passar `group`
   no `workspace.create` faz o Folders do bora agrupar de graça. Qualquer
   proposta de `ViewMode` novo, cópia do Folders ou `SectionDescriptor` pra
   isto está morta por medição (ceo-bora#167): custaria 3 quebras de
   compilação, 11 guardas herdadas em silêncio e 3 goldens de frame, para
   entregar o que uma linha entrega.
5. **O binário tem que estar em `./target/release/herdr-mirror`, e nesta frota
   não estaria.** As ~20 linhas de `command` do `herdr-plugin.toml` são
   relativas à raiz do plugin, e `~/.cargo/config.toml` desta máquina pina um
   `target-dir` GLOBAL — então `cargo build --release` nu escreve em
   `~/.cargo/target` e o caminho prometido nunca existe. Medido: `bora plugin
   link` **não** roda `[[build]]` (`src/cli/plugin.rs`, `plugin_link` só
   valida o manifesto e registra), então o binário precisa estar lá ANTES do
   link; `plugin install` roda, e cai no `scripts/install.sh`, que neste fork
   não tem Release para baixar. Daí `--target-dir target` explícito em toda
   invocação e o fallback de compilar do source no `install.sh` — com o
   MISMATCH de checksum seguindo `fail` duro, porque cair pra build num
   download adulterado transformaria o único sinal de segurança do script num
   aviso que ninguém lê.

## Regras de código deste fork

- **Uma linha vinda do host remoto é entrada não-confiável.** O upstream digita
  o id de pane remoto num `exec …` no shell de um pane LOCAL (`mirror.rs`, via
  `pane.send_text`), e o `sh_quote` dele não filtra caractere de controle: host
  comprometido = execução local. `reject_control` recusa (não sanitiza) e tem
  teste. Ao adicionar qualquer caminho novo que leve texto do remoto pro shell
  local, passe por ele.
- **Id local pode ser reciclado.** Depois de restart do servidor local, um id
  que o map guarda pode pertencer a outra workspace — o próprio upstream
  confessa "cannot tell" (`mirror.rs:311-313`). Toda destruição passa por
  `still_ours`, que compara a marca de identidade em token. Nunca feche por id
  sozinho.
- **Decisão em função pura, execução em volta dela.** `token_ops`,
  `control_exit_argv`, `candidate_dirs`: a regra sai testável sem rede e sem
  env global, e o laço do daemon só executa o plano. Teste que precisa de
  `HERDR_*` mutado no processo é sinal de que a decisão não foi extraída.
- **Marcador de estado não expira.** O token de host caído (`state_token`,
  default `frota`) é escrito na transição e limpo na reconexão, sem TTL: um
  aviso que expira sozinho volta a mostrar máquina morta como saudável, e a
  mentira otimista é pior que o aviso velho.
- **Só o daemon toca em processo de máquina alheia.** `remote_autostart`
  (default on, override por host) faz o daemon subir um servidor num host que
  responde ssh e não tem nenhum — sem isso a pasta só aparece se um humano
  tiver rodado `bora server` lá, e o mirror reporta "not running" e faz
  backoff pra sempre. `once`, as ações remotas e o CLI **nunca** sobem nada:
  olhar uma máquina não pode gerar processo nela. Duas coisas seguram a regra:
  o cooldown de 5 min mora no laço do daemon (um `RemoteHost` novo nasce a cada
  reconexão, então guardar isso nele viraria um spawn a cada 5s contra uma
  máquina que não consegue rodar servidor), e o carimbo do cooldown sai da
  TENTATIVA, não da permissão — host que estava no ar não gasta orçamento só
  por ser pollado.
- Sem dependência nova. Sem `unwrap()` em produção. Comentário explica o
  *porquê* (o upstream é rigoroso nisso; mantenha o tom).

## Verificação

```bash
cargo test  --target-dir target              # 231 testes, ~1s
cargo build --release --target-dir target
scripts/ensaio-bora.sh work                  # ensaio contra máquina real, ~25s
```

**`--target-dir` explícito não é preciosismo.** `CARGO_TARGET_DIR` é global
nesta máquina, então dois clones do mesmo crate dividem um `target/release` e o
build de um sobrescreve o binário do outro sem avisar — um ensaio pode medir o
upstream acreditando que mediu o fork. `scripts/ensaio-bora.sh` prova qual
binário tem na mão por um símbolo que só este fork contém, e o script carrega,
em comentário, as outras duas armadilhas medidas (registro de plugin é global
por NAMESPACE e não por sessão; não existe `bora server start`).

**O ensaio roda COM a instalação viva no ar, e é isso que o torna honesto.**
O state (id map, tombstones, pidfile) é fixo por máquina de propósito, então um
ensaio que dividisse esse diretório leria um mapa cujos ids locais são da
sessão viva, tombstonearia os espelhos dela e não subiria daemon nenhum (o
vivo segura o lock) — foi exatamente o que aconteceu no minuto seguinte ao
primeiro link de verdade, e até ali o ensaio só passava porque era o único
mirror da máquina. `HERDR_MIRROR_STATE_DIR` existe para esse único chamador.
Duas consequências que não são detalhe: contar ControlMaster órfão pelo nome
do binário acusa o master legítimo do daemon vivo, então conte só os que estão
sob o state do ensaio; e o state vivo **não** pode ser comparado por hash,
porque o daemon vivo reage de verdade ao host caindo que o próprio ensaio
provoca — o que tem de sobreviver é observável na sessão viva (mesmos
espelhos, mesmos ids, mesmo daemon), e o passo 8 confere isso.

Ao mudar regra defendida por teste, prove que o teste acusa: mutação por
regra, uma por vez, cada uma reddening o teste NOMEADO. Foi assim que as três
regras de `token_ops`, as três de `remote_herdr_expr` e as duas de
`candidate_dirs` entraram.

## Sincronizar com o upstream

`git fetch upstream && git merge upstream/main`. Classes de conflito
esperadas, todas do mesmo rename:

- Strings de usuário e docs voltam a dizer `herdr`; renomeie só o que é
  nome de binário/dir do fork, deixando `nikok6/herdr-mirror`, nomes de
  arquivo (`herdr-mirror`) e identificadores internos em paz.
- `remote_herdr_expr` e `config_candidates` são os dois pontos que o upstream
  mais mexe e que este fork reescreveu. Reaplique a lista de candidatos.
- Depois de qualquer merge: `cargo test --target-dir target` e
  `scripts/ensaio-bora.sh work`. O ensaio é o que pega regressão de encaixe;
  os testes não falam com máquina nenhuma.

## Mapa

Este fork é execução de um esforço cartografado no CEO do time:

- PROJETO [`aryrabelo/ceo-bora#162`](https://github.com/aryrabelo/ceo-bora/issues/162) — a frota como uma máquina
- MAPA [`aryrabelo/ceo-bora#163`](https://github.com/aryrabelo/ceo-bora/issues/163) — a frota SSH aparece como uma máquina na sidebar
