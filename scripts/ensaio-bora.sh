#!/usr/bin/env bash
# Ensaio de encaixe deste fork num bora real, contra uma máquina ssh de verdade.
#
# Por que existe: em 2026-09-07 este ensaio foi feito à mão e quatro armadilhas
# medidas transformariam um ensaio honesto num ensaio mentiroso. Todas as
# quatro estão codificadas aqui, e é o único motivo deste arquivo não ser um
# punhado de comandos no histórico:
#
#   1. Registro de plugin é GLOBAL por namespace, não por sessão. `--session`
#      só move o data dir; `plugin link` numa sessão descartável escreveria no
#      registro que a sessão VIVA lê, e os hooks rodariam na sessão viva. Só
#      HERDR_NAMESPACE isola. Este script confere o sha256 do registro vivo
#      antes e depois e falha se ele mudou.
#   2. CARGO_TARGET_DIR é global em muitas máquinas, então dois clones do mesmo
#      crate dividem um target/release. --target-dir explícito, e a prova de
#      qual binário está na mão é um símbolo que só este fork contém.
#   3. Não existe `bora server start`. Verbo de CLI não sobe servidor; em host
#      headless o caminho é `nohup bora server`.
#   4. State (id map, tombstones, pidfile) é FIXO por máquina. Com o plugin
#      instalado de verdade, dividir esse diretório faz o ensaio ler um mapa
#      cujos ids são da sessão VIVA, tombstonear os espelhos dele e nem subir
#      daemon (o vivo segura o lock). HERDR_MIRROR_STATE_DIR isola, e o passo
#      8 confere que os espelhos e o daemon vivos sobreviveram — por
#      observação na sessão viva, não por hash do state, que muda de propósito
#      quando o daemon vivo reage ao host caindo.
#
# Uso: scripts/ensaio-bora.sh <host-ssh>     (default: work)
# Requer: o host alcançável por `ssh -o BatchMode=yes`, com bora instalado.

set -uo pipefail

HOST="${1:-work}"
NS="mirror-ensaio"
CFG="$HOME/.config/$NS"
SOCK="$CFG/sessions/$NS/herdr.sock"
PLUGCFG="$CFG/plugins/config/mirror"
# State (id map, tombstones, pidfile) é FIXO por máquina de propósito, e é a
# quarta armadilha: com o plugin instalado de verdade, um ensaio que divide
# este diretório lê um mapa cujos ids locais são da sessão VIVA, decide que
# os espelhos dele "foram fechados localmente", faz tombstone — e o daemon
# dele nem sobe, porque o vivo segura o lock do pidfile. Medido 2026-09-07:
# o ensaio passava só enquanto era o único mirror da máquina.
LIVE_STATE="$HOME/.local/state/herdr-mirror"
STATE="$HOME/.local/state/herdr-mirror-ensaio"
LIVE_REGISTRY="$HOME/.config/bora/plugins.json"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/target/release/herdr-mirror"
TOKEN="frota"

fails=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fails=$((fails + 1)); }
step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# Toda invocação local do bora fala com a sessão descartável, nunca com a viva.
ens() { env -u HERDR_ENV -u HERDR_CLIENT_SOCKET_PATH HERDR_NAMESPACE="$NS" \
        HERDR_SOCKET_PATH="$SOCK" bora "$@"; }
# O mirror precisa do mesmo socket, do config de ensaio e do state isolado.
mir() { env HERDR_SOCKET_PATH="$SOCK" HERDR_PLUGIN_CONFIG_DIR="$PLUGCFG" \
        HERDR_MIRROR_STATE_DIR="$STATE" HERDR_MIRROR_LOCAL_BIN=bora "$BIN" "$@"; }
rem() { ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" "$@"; }
# Token do host na workspace espelhada, ou vazio.
tok() { ens workspace list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for w in d.get('result',{}).get('workspaces',[]):
    if w.get('visual_group') == '$HOST':
        print((w.get('tokens') or {}).get('$TOKEN',''))
        break"; }
# Só os ControlMasters DESTE ensaio: o ctl vive sob o state dir, e com o
# plugin instalado de verdade o daemon vivo mantém legitimamente um master por
# host. Contar por nome do binário acusava o master do vivo e reprovava um
# teardown correto (medido 2026-09-07).
orphans() { pgrep -af "ssh .*$STATE.*\.ctl" 2>/dev/null | wc -l | tr -d ' '; }
# Espelho da instalação VIVA para o host, como a sessão viva o vê.
live_mirror() { bora workspace list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(sorted(w.get('workspace_id','') for w in d.get('result',{}).get('workspaces',[])
             if w.get('visual_group') == '$HOST'))"; }

step "0. guardas: sessão viva e registro global intactos"
live_before="$(shasum -a 256 "$LIVE_REGISTRY" 2>/dev/null | cut -d' ' -f1)"
[ -n "$live_before" ] && echo "  registro vivo: ${live_before:0:16}…" || echo "  (sem registro vivo)"
remote_was_up=false
rem '~/.local/bin/bora status --json' 2>/dev/null | grep -q '"running":true' && remote_was_up=true
echo "  $HOST tinha servidor rodando: $remote_was_up"
# O state vivo NÃO pode ser comparado por hash: o daemon vivo está rodando e
# reage de verdade ao host caindo (que este ensaio provoca), então mapa, log e
# token mudam por projeto. O que tem de sobreviver é observável na sessão
# viva: os mesmos espelhos, com os mesmos ids, e o mesmo daemon.
live_mirror_before="$(live_mirror)"
live_daemon_before="$(cat "$LIVE_STATE/daemon.pid" 2>/dev/null || echo none)"
echo "  instalação viva: daemon $live_daemon_before, espelhos $live_mirror_before"

step "1. build do fork em target do repo (armadilha 2)"
(cd "$REPO" && cargo build --release --target-dir target 2>&1 | tail -2)
[ -x "$BIN" ] || { fail "binário não saiu em $BIN"; exit 1; }
# Sonda em python, sem pipe: `strings "$BIN" | grep -q` sob `set -o pipefail`
# reprova o fork CERTO — o grep fecha o pipe no primeiro casamento, o strings
# morre de SIGPIPE e o pipefail entrega o status dele. Medido aqui: o símbolo
# estava no binário e o teste dizia que não.
if python3 -c "
import sys
sys.exit(0 if b'HERDR_MIRROR_LOCAL_BIN' in open('$BIN','rb').read() else 1)"; then
  pass "binário é o fork (símbolo HERDR_MIRROR_LOCAL_BIN presente)"
else
  fail "binário NÃO é o fork — target compartilhado entregou o upstream"
  exit 1
fi

step "2. namespace descartável com o token na sidebar (armadilha 1)"
mkdir -p "$PLUGCFG" "$CFG"
# Declarar rows SUBSTITUI os defaults: o default inteiro é restatado aqui.
cat > "$CFG/config.toml" <<TOML
[ui.sidebar.spaces]
rows = [["state_icon", "workspace", "\$$TOKEN"], ["branch", "git_status"]]
TOML
cat > "$PLUGCFG/hosts.toml" <<TOML
poll_seconds = 60
autostart = false
close_remote_on_local_close = false
always_control = false

[hosts.$HOST]
target = "$HOST"
# remote_bin de proposito AUSENTE: o ensaio exercita o auto-resolver, que e o
# que a frota vai usar. Com remote_bin = "bora" literal o converge morre com
# "command not found: bora", porque o PATH de um ssh nao-interativo nao tem
# ~/.local/bin (medido 2026-09-07). Sem backtick nem $ aqui: este heredoc e
# NAO-quotado de proposito (precisa expandir $HOST/$TOKEN), entao a shell
# avalia o que estiver entre backticks dentro do comentario.
TOML
ens session stop "$NS" >/dev/null 2>&1
ens server stop >/dev/null 2>&1
sleep 1
env -u HERDR_ENV -u HERDR_SOCKET_PATH -u HERDR_CLIENT_SOCKET_PATH \
  HERDR_NAMESPACE="$NS" bora --session "$NS" server >/dev/null 2>&1 &
for _ in $(seq 1 20); do [ -S "$SOCK" ] && break; sleep 0.5; done
[ -S "$SOCK" ] && pass "sessão de ensaio no ar ($SOCK)" || { fail "sessão não subiu"; exit 1; }

step "3. servidor no $HOST (armadilha 3: não existe server start)"
if ! $remote_was_up; then
  rem 'nohup ~/.local/bin/bora server </dev/null >/dev/null 2>&1 & sleep 3' >/dev/null 2>&1
fi
rem '~/.local/bin/bora status --json' 2>/dev/null | grep -q '"running":true' \
  && pass "$HOST com servidor rodando" || { fail "$HOST sem servidor"; exit 1; }

step "4. converge: a máquina remota aparece como pasta local"
mir once 2>&1 | tail -3
ens workspace list | python3 -c "
import json,sys
ws=[w for w in json.load(sys.stdin)['result']['workspaces'] if w.get('visual_group')=='$HOST']
print(f'  {len(ws)} workspace(s) na pasta \"$HOST\":', [w['label'] for w in ws])
sys.exit(0 if ws else 1)" && pass "pasta por máquina via visual_group" || fail "nenhuma workspace agrupada"

step "5. daemon vivo, e a máquina cai"
mir daemon >/tmp/.ensaio-daemon.log 2>&1 &
dpid=$!
sleep 5
[ -z "$(tok)" ] && pass "token limpo enquanto conectado" || fail "token sujo com host no ar: '$(tok)'"
rem '~/.local/bin/bora server stop' >/dev/null 2>&1
for _ in $(seq 1 24); do [ -n "$(tok)" ] && break; sleep 1; done
if [ -n "$(tok)" ]; then pass "linha da sidebar avisa: '$(tok)'"
else fail "host caído e a linha não mudou (era exatamente o buraco do #171)"; fi

step "6. volta do host limpa o aviso"
rem 'nohup ~/.local/bin/bora server </dev/null >/dev/null 2>&1 & sleep 2' >/dev/null 2>&1
for _ in $(seq 1 40); do [ -z "$(tok)" ] && break; sleep 1; done
[ -z "$(tok)" ] && pass "token limpo na reconexão" || fail "aviso ficou colado: '$(tok)'"

step "7. teardown não vaza ControlMaster"
kill "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null
mir teardown 2>&1 | tail -2
sleep 2
n="$(orphans)"
[ "$n" = "0" ] && pass "zero ssh órfão depois do teardown" || fail "$n ControlMaster órfão(s) sobrando"

step "8. restauração"
if ! $remote_was_up; then rem '~/.local/bin/bora server stop' >/dev/null 2>&1; fi
ens session stop "$NS" >/dev/null 2>&1
ens server stop >/dev/null 2>&1
for d in "$STATE" "$CFG"; do
  case "$(basename "$d")" in
    # `herdr-mirror` (sem sufixo) é o state VIVO e não entra nesta lista de
    # propósito: se o override algum dia parar de valer, o ensaio para em
    # falha visível em vez de apagar o mapa da instalação real.
    herdr-mirror-ensaio | "$NS") rm -rf "$d" ;;
    *) fail "guarda: não removo $d" ;;
  esac
done
live_after="$(shasum -a 256 "$LIVE_REGISTRY" 2>/dev/null | cut -d' ' -f1)"
[ "$live_before" = "$live_after" ] && pass "registro de plugin da sessão viva intacto" \
  || fail "o ensaio ESCAPOU para a sessão viva (registro mudou)"
# A instalação viva reconecta sozinha depois do passo 6, mas pode levar uma
# passada de backoff: esperar é medir o mesmo fato mais tarde, não afrouxar.
live_mirror_after="$(live_mirror)"
for _ in $(seq 1 30); do
  [ "$live_mirror_after" = "$live_mirror_before" ] && break
  sleep 1
  live_mirror_after="$(live_mirror)"
done
live_daemon_after="$(cat "$LIVE_STATE/daemon.pid" 2>/dev/null || echo none)"
[ "$live_mirror_after" = "$live_mirror_before" ] \
  && pass "espelhos da instalação viva intactos ($live_mirror_after)" \
  || fail "o ensaio mexeu nos espelhos VIVOS: $live_mirror_before -> $live_mirror_after"
[ "$live_daemon_before" = "$live_daemon_after" ] && pass "daemon vivo segue o mesmo ($live_daemon_after)" \
  || fail "daemon vivo era $live_daemon_before e agora é $live_daemon_after"

printf '\n'
[ "$fails" = "0" ] && { printf '\033[32mensaio verde\033[0m\n'; exit 0; }
printf '\033[31m%s falha(s)\033[0m\n' "$fails"; exit 1
