#!/usr/bin/env bash
# 판본: mempute/yac-data-pipeline@9bfe956646b1f67c65e18395ea002d48e08cbc30 · 2026-10-29T04:16:12Z · 자동 동기화(TASK-573, 허브 워크플로 reworker_mirror) — 원본 scripts/reworker.sh · 손 편집 금지
# reworker.sh — 워커 **유일 진입**(멱등, 재실행 안전). TASK-107.
#
# 사용(상태가 어떻든 언제나 같은 한 줄):
#   bash scripts/reworker.sh
#   bash scripts/reworker.sh <워커> [--control-node] [--non-interactive]
#                            [--account <계정>] [--once-per-boot] [--report]
#                            [--deep] [--renew <id>[,<id>…]] [--no-attach]
#   bash scripts/reworker.sh --fill-expected   ⓪ 절만(러너 자동 증설이 부른다, TASK-333)
#   bash ~/reworker.sh <워커> <소유자/저장소>  저장소 **없는** 새 기계(TASK-549 자급 부트스트랩 —
#                            이 파일 하나를 scp 로 가져다 놓고 돌리면 토큰 숨김 입력 한 번 뒤
#                            clone → bootstrap → clone 안 자기 재진입까지 한 번에 간다)
#
# **한 번이 끝까지 간다(TASK-238, 사용자 2026-09-24 16:39 "명령 한 개로").**
# ⓪ 이 기계에 있어야 할 인스턴스(`config/instances.yml` `expected_instances`,
# 기계 이름 키)를 실재(`$YAC_ROOT/*/.yac_instance`)와 대조해 없는 것만
# `inst_add` 로 세우고(host 만·멱등·잡 안은 보고만), ⑥ 대화형·잡 밖·TTY 면
# ⑤ 요약 뒤 알씨 tmux 창으로 `exec tmux attach`(tmux 안이면
# `switch-client`) 한다 — 종전의 `--add-worker` 손 단계(RECOVERY 6-1)와
# `tmux attach -t rc` 로그인 단계가 이 한 줄에 흡수됐다. `--no-attach` 로
# 끄고, 부팅 훅(`--non-interactive`·`--once-per-boot`)·잡·이관 활성화(m6b)
# 는 자동으로 접속하지 않는다.
#
# `--renew` 는 ①-0 창구가 지정 항목만 값이 있어도(have) 다시 묻게 한다 —
# 계정 변경·만료처럼 이미 있는 값을 갈 때의 유일 통로다(TASK-233).
#
# `--deep` 은 1-10 동작 프로브의 paid 항목(러너 잡 1회 실제 완주)까지
# 잰다 — 기본은 무해한 free 항목만이다(TASK-130, CR-0024).
#
# 사용자 확정 2026-08-31: "나는 무조건 reworker 하나만 하면 되게".
# 종전에는 고장 종류마다 진입이 달랐다 — 초기 셋업·재부팅은 restore.sh,
# 중간 고장은 reworker.sh, 관측 창은 obsv_boot.sh, 알씨 관제 거처는
# rc_boot.sh, 전면 불통은 rescue_runner.sh. 2026-08-31 회선 장애에서
# 그 분업이 실패했다: reworker 가 "[OK] 정상 7·복구 8"을 통보한 **뒤에도**
# root 소유 유령 러너·알씨 원격 다리 사망·funnel 미복구가 남아 사용자가
# restore→rescue→수동 rc_boot 3단을 손으로 밟았다(JL-2026-08-0292·0298).
# 원인은 각 스크립트가 자기 영역만 보고 자기 방식으로 판정한 것이므로,
# ①진입을 하나로 모으고 ②판정을 코어 하나(`scripts/core/liveness.sh`)로
# 모은다. restore.sh 는 이 파일의 별칭이 됐고 rescue_runner.sh 는 ②절에
# 흡수됐다.
#
# 절 순서는 고정이다(뒤 절이 앞 절의 결과에 기댄다):
#   ⓪ 인스턴스 보충    — 기대 목록(사전) − 실재(디스크) 만 inst_add(host, TASK-238)
#   ① 환경 점검·보충  — 최신화·해제·의존·셋업·크론·티스케일·러너 자격·부팅 훅
#                        + 1-10 동작 프로브(존재가 아니라 동작, TASK-130)
#   ② 상주 재기동      — 전 소유자 유령 정리 + 래퍼·데몬 신판 재기동
#   ③ 관측             — obsv_boot(게이트웨이·funnel·워치독) + 판정
#   ④ 알씨 세션        — rc_boot(다리 상태·회전 대기 포함) + 판정
#   ⑤ 통보 1줄         — [OK]/[WARN] 정상 N·복구 N·잔여 N + 고친 항목 + 입력 필요
#   ⑥ 알씨 접속        — 대화형·잡 밖·TTY 면 exec tmux attach(TASK-238, --no-attach 로 끔)
#
# **입력이 필요한 것은 중단 사유가 아니다.** dpipe 토큰·암호구·Tailscale
# authkey·Claude 토큰(TASK-113 5)이 없으면 "무엇을 어디에 넣어라" 한
# 줄을 남기고 그 절만 건너뛴 뒤 나머지를 끝까지 수행한다(부분 부활 >
# 전무). 비대화 모드에서 입력이 남았으면 마지막에 텔레그램 1통 + 비0(3)
# 종료로 알린다.
#
# git 자체의 Username/Password 프롬프트는 아예 뜨지 않게 차단한다
# (GIT_TERMINAL_PROMPT=0 — "Password" 문구가 계정 비번을 묻는 것으로
# 오독되는 실사고 2026-08-18). 토큰을 묻는 창구는 이 스크립트의 숨김
# 프롬프트 하나뿐이며 자격증명 실패가 실측될 때만 뜬다. 비밀 값은
# 화면·로그·통보 어디에도 남기지 않는다.
#
# **잡 안 실행**: 러너·게이트웨이·알씨 세션의 **재기동은 전부 건너뛰고**
# 판정·보고만 한다(TASK-097 ⑤⑥ 자기 살해 방지, TASK-107 제약). 나머지
# (git 정리·인증·최신화·리스너/워치독 재기동)는 그대로 수행한다.
set -u
export GIT_TERMINAL_PROMPT=0

# ── 순수 함수(부작용 없음 — 라이브러리 모드 겸용) ─────────────────────
# `YAC_REWORKER_LIB=1 . scripts/reworker.sh` (구 `YAC_RESTORE_LIB=1 .
# scripts/restore.sh` 와 같은 면)로 source 하면 이 절의 함수만 정의하고
# 아무것도 실행하지 않은 채 돌아온다. 잡 안에서 이 파일을 통째로 돌릴
# 수 없으므로 검증은 이 면을 통해 함수 단위로 모의한다.

# 이 파일이 사는 저장소 루트. 본 실행은 아래에서 `ROOT` 로 다시 확정하고
# 값이 같다 — 라이브러리 모드(시험)에도 같은 사실이 필요해 먼저 잡는다.
REWORKER_ROOT="${REWORKER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"
# 경로·신원 결정은 코어 한 통로다(TASK-136, CR-0015). 아래 순수 판정
# (`inst_sweep_targets`)이 인스턴스 사전(`.yac_instance`)을 읽어야 하므로
# 라이브러리 모드에서도 여기서 확보한다. 본 실행 경로에서는 뒤의
# `liveness.sh` 가 같은 파일을 다시 source 하지만 결정은 멱등이다.
if ! command -v yac_decl >/dev/null 2>&1 && [ -f "$REWORKER_ROOT/scripts/core/instance.sh" ]; then
  # shellcheck disable=SC1091
  YAC_INSTANCE_REPO="$REWORKER_ROOT" . "$REWORKER_ROOT/scripts/core/instance.sh"
fi

# ── 자급 부트스트랩 (TASK-549, PROTOCOL 4-2·13) ──────────────────────────
# **저장소 밖(clone 전 기계)에서 이 파일 하나만 들고 돌 때의 입구.** 종전에는
# 단일 입구가 저장소 안에만 있어 저장소 없는 기계는 입구를 얻을 길이
# 문서의 손 절차 7줄뿐이었고(닭-달걀), clone 자격 기입이 입구 밖(사람 손)에
# 있어 비공개 저장소 clone 에서 git 기본 프롬프트 `Username for …` 가
# 사람에게 닿았다(vast2 편입 실측 2026-10-15 03:47~04:06, JL-2026-10-2136 —
# 사용자 「reworker 하나면 다되게 하는 것이 기본」). 사람이 치는 것은
# `bash ~/reworker.sh <워커> <소유자/저장소>` 한 줄 + 숨김 토큰 입력 한 번이다.
#
# 순서(한 순서, AD-0010): ⓐ 워커·저장소 좌표 ⓑ 토큰(숨김 입력 — 환경변수
# `GITHUB_TOKEN` 이 있으면 묻지 않는다) ⓒ `~/.git-credentials` 기입(원천 하나,
# `x-access-token` 서식·600·비어 있을 때만 — 값이 **있는데** 인증 실패면 되묻는다,
# 1-2 절과 같은 insufficient 어휘) + `credential.helper store` ⓓ 자격 없는 깨끗한
# URL 로 clone(bootstrap_worker.sh 와 같은 ROOT 규칙) ⓔ clone 안
# `scripts/bootstrap_worker.sh <워커>` ⓕ clone 안 `scripts/reworker.sh <워커> <나머지
# 인자>` 로 `exec` 재진입 — 그 뒤는 종전 코어 경로 그대로다(저장소 안 실행 경로는
# 변경 0). 이 절은 **코어 없이 셸 내장(read·printf·git)만** 쓴다 — 저장소 밖에는
# `scripts/core/*` 가 없다. 파일 머리의 `GIT_TERMINAL_PROMPT=0` 이 이 절에도 그대로
# 유효해 git 기본 프롬프트가 사람에게 닿는 경로는 0 이다.
#
# 드라이런(`YAC_SETUP_DRYRUN=1`, setup-wsl.sh 와 같은 어휘): ⓐ~ⓓ 는 실제로 하고
# ⓔⓕ 는 실행할 명령만 찍는다(시험·잡의 모의 편입). 편입 원장(AD-0054 — 효력을
# 재는 원장이 없으면 먼저 만든다): 끝에 `state/<워커>/enroll_ledger.jsonl` 에 행 1
# (`ts`·`worker`·`repo`·`hand_cmds`·`token_prompts`·`git_prompts`·`mode`·`sec`) —
# 자원 종류 `EnrollLedger`(config/resources.yml), 읽는 쪽은
# `core/effect_meter.ledger_rows(enroll_ledger.jsonl|…)`. 비밀 값은 화면·로그·원장
# 어디에도 싣지 않는다(PROTOCOL 4-1).
rw_outside_repo() {  # 0=저장소 밖(자급 필요) / 1=저장소 안
  [ -f "$REWORKER_ROOT/scripts/core/instance.sh" ] || return 0
  git -C "$REWORKER_ROOT" rev-parse --show-toplevel >/dev/null 2>&1 || return 0
  return 1
}

# clone 자리 규칙 — `scripts/bootstrap_worker.sh` 25~36행과 **같은 규칙**이다
# (/workspace 는 쓰기 가능할 때만, 아니면 `${YAC_HOME:-$HOME}`). 단일 원천은 그
# 파일이지만 이 절이 도는 기계에는 아직 그 파일이 없어 문면을 여기도 둔다 —
# 두 벌의 어긋남은 tests_reworker 549 절이 대조한다.
rw_boot_root() {  # $1=소유자/저장소 → clone 자리
  local repo="${1##*/}"
  if [ "$(uname -s)" = Linux ] && [ -d /workspace ] && [ -w /workspace ]; then
    printf '%s' "/workspace/$repo"
  else
    printf '%s' "${YAC_HOME:-$HOME}/$repo"
  fi
}

# 좌표 서식 — `소유자/저장소` 한 꼴(URL·경로 탈출 금지). 원장 JSON 에 그대로
# 실리므로 따옴표·역슬래시가 들어올 수 없는 문자 집합으로 막는다.
rw_repo_coord_ok() {  # $1=좌표
  case "$1" in
    */*/*|*://*|""|*[!A-Za-z0-9_./-]*|/*|*/|*..*) return 1 ;;
    *) return 0 ;;
  esac
}

# 편입 원장 행 1 — 값은 전부 검증된 문자 집합(워커 이름·좌표)과 정수라 JSON
# 이스케이프가 필요 없다. 기계 어디서나 같은 서식(ts 는 UTC ISO).
rw_enroll_ledger_append() {  # $1=원장 루트 $2=워커 $3=좌표 $4=토큰 입력 수 $5=mode $6=소요초
  local dir="$1/state/$2" gp=-1
  [ "${GIT_TERMINAL_PROMPT:-}" = 0 ] && gp=0   # 0 이 아니면 미계측(-1) — 0 으로 꾸미지 않는다
  mkdir -p "$dir" 2>/dev/null || return 1
  printf '{"ts": "%s", "worker": "%s", "repo": "%s", "hand_cmds": 1, "token_prompts": %s, "git_prompts": %s, "mode": "%s", "sec": %s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$3" "$4" "$gp" "$5" "$6" >> "$dir/enroll_ledger.jsonl"
}

rw_self_bootstrap() {  # $@=원 인자 — 돌아오지 않는다(exec 또는 exit)
  local t0 worker repo url root cred dry tok_prompts=0 rest=() ledger_root
  t0="$(date +%s)"
  dry=0; [ "${YAC_SETUP_DRYRUN:-0}" = 1 ] && dry=1
  sb_say() { echo "[reworker/자급] $*"; }
  sb_need() { echo "[reworker/자급] 입력 필요 — $*"; }

  sb_say "저장소 밖 실행 감지 — 자급 부트스트랩(clone → bootstrap → 재진입) 을 시작한다$([ "$dry" = 1 ] && echo ' (드라이런)')"

  # ⓐ 워커 이름·저장소 좌표. 비밀이 아니라 화면 입력이다(대화형일 때만 묻는다).
  worker="${1:-}"; [ $# -gt 0 ] && shift
  if [ -z "$worker" ] && [ -t 0 ]; then read -rp "워커 이름(예: vast2): " worker; fi
  if ! valid_instance_name "$worker"; then
    echo "[reworker/자급] 워커 이름이 없거나 서식 밖 — 사용: bash ~/reworker.sh <워커> <소유자/저장소>" >&2
    exit 1
  fi
  if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then repo="$1"; shift; else repo="${TARGET_REPO:-}"; fi
  if [ -z "$repo" ] && [ -t 0 ]; then read -rp "허브 저장소(소유자/저장소): " repo; fi
  if ! rw_repo_coord_ok "$repo"; then
    echo "[reworker/자급] 저장소 좌표가 없거나 서식 밖(소유자/저장소) — 사용: bash ~/reworker.sh <워커> <소유자/저장소>" >&2
    exit 1
  fi
  rest=("$@")
  url="${YAC_HUB_URL_BASE:-https://github.com}/${repo}.git"
  root="$(rw_boot_root "$repo")"
  cred="$HOME/.git-credentials"
  ledger_root="${YAC_ENROLL_LEDGER_ROOT:-$root}"

  # ⓑⓒ 자격 — 원천은 ~/.git-credentials 하나(PROTOCOL 4-2). 환경변수는 파일로
  # 옮겨 적는 비대화 경로일 뿐 URL 에 박지 않는다. 인증은 **실제로 시험**해
  # (`ls-remote`, 프롬프트 차단) 실패가 실측될 때만 묻는다 — 값이 있는데 실패면
  # insufficient 로 되묻고, 비대화면 need 한 줄 + rc 3 으로 멈춘다(규칙 14).
  git config --global credential.helper >/dev/null 2>&1 \
    || git config --global credential.helper store
  sb_write_cred() {  # $1=토큰 — 값은 파일로만 간다
    printf 'https://x-access-token:%s@github.com\n' "$1" > "$cred"
    chmod 600 "$cred"
  }
  sb_auth_ok() { GIT_TERMINAL_PROMPT=0 git ls-remote -q "$url" HEAD >/dev/null 2>&1; }
  if [ ! -s "$cred" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
    sb_write_cred "$GITHUB_TOKEN"
    sb_say "자격 파일 기입(GITHUB_TOKEN → ~/.git-credentials, 값 비출력)"
  fi
  if [ -s "$cred" ] && sb_auth_ok; then
    sb_say "원격 인증 정상(자격 파일, ls-remote)"
  else
    if [ -s "$cred" ]; then
      sb_say "자격 값은 있으나 원격 인증 실패(insufficient) — 정본 값이 아닐 수 있어 다시 묻는다"
    else
      sb_say "자격 파일 없음(missing)"
    fi
    if [ -t 0 ]; then
      local T=""
      read -rsp "dpipe PAT(GitHub fine-grained, Contents RW — 화면에 보이지 않는다): " T; echo
      tok_prompts=1
      if [ -z "$T" ]; then
        sb_need "dpipe 토큰 — 빈 입력이라 clone 할 수 없다. 다시: bash ~/reworker.sh $worker $repo"
        exit 3
      fi
      sb_write_cred "$T"; unset T
      if sb_auth_ok; then
        sb_say "자격 파일 기입 + 원격 인증 성공"
      else
        sb_need "dpipe 토큰 — 기입했으나 원격 인증 실패(토큰 권한·만료·저장소 좌표 $repo 확인). 다시: bash ~/reworker.sh $worker $repo"
        exit 3
      fi
    else
      sb_need "dpipe 토큰 — 비대화라 묻지 않는다. 대화형 셸에서 'bash ~/reworker.sh $worker $repo' 를 돌리면 숨김 창이 한 번 묻는다(또는 GITHUB_TOKEN 환경변수)"
      exit 3
    fi
  fi

  # ⓓ 깨끗한 URL clone(자격 임베드 0). 이미 있으면 그대로 쓴다(멱등, CR-0017).
  if [ -d "$root/.git" ]; then
    sb_say "clone 이미 있음 — 재사용: $root"
  else
    mkdir -p "$(dirname "$root")"
    if git clone -q "$url" "$root"; then
      sb_say "clone 완료: $root"
    else
      echo "[reworker/자급] clone 실패(좌표 $repo) — 자격·좌표·네트워크 확인 뒤 같은 명령 재실행" >&2
      exit 1
    fi
  fi

  # ⓔⓕ clone 안 bootstrap → 자기 재진입. 드라이런은 명령만 찍는다.
  rw_enroll_ledger_append "$ledger_root" "$worker" "$repo" "$tok_prompts" "$([ "$dry" = 1 ] && echo dry || echo live)" "$(( $(date +%s) - t0 ))" \
    || sb_say "편입 원장 기록 실패(무시) — $ledger_root/state/$worker/enroll_ledger.jsonl"
  if [ "$dry" = 1 ]; then
    sb_say "(드라이런) 실행 예정: cd $root && YAC_REWORKER_ACTIVE=1 bash scripts/bootstrap_worker.sh $worker"
    sb_say "(드라이런) 실행 예정: exec bash $root/scripts/reworker.sh $worker ${rest[*]:-}"
    exit 0
  fi
  cd "$root" || exit 1
  # 실패 분기는 rc 를 싣는다(TASK-581 — vast2 실측에서 사람이 본 것은 "crontab:
  # command not found" 한 줄과 이 문면뿐이라 어느 단계가 죽었는지 rc 로 가른다).
  # cron 부재 자체는 이제 bootstrap 안에서 경고 한 줄 + 건너뜀이라 여기로 오지 않는다.
  local brc=0
  YAC_REWORKER_ACTIVE=1 bash scripts/bootstrap_worker.sh "$worker" || brc=$?
  if [ "$brc" -ne 0 ]; then
    echo "[reworker/자급] bootstrap_worker.sh 실패(rc=$brc) — 위 출력 확인 뒤 clone 안에서 'bash scripts/reworker.sh $worker' 재실행(멱등 — 끝난 단계는 건너뛴다)" >&2
    exit 1
  fi
  sb_say "부트스트랩 완료 — clone 안 reworker 로 재진입"
  # YAC_REWORKER_SELFBOOT=1 은 「빈 기계 첫 편입」 표지다 — 1-5 unlock 이 추적
  # 변경을 stash 로 감싸는 갈래는 이 표지가 있을 때뿐이다(TASK-583, rw_vault_unlock).
  YAC_REWORKER_SELFBOOT=1 exec bash "$root/scripts/reworker.sh" "$worker" ${rest[@]+"${rest[@]}"}
}

# 잡(GitHub Actions 러너) 안인가. 러너 관련 단계의 자기 살해 방지 판정.
in_job() {
  [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${RUNNER_NAME:-}" ] \
    || [ -n "${RUNNER_OS:-}" ] || [ -n "${RUNNER_WORKSPACE:-}" ]
}

# 인자 파싱(전역 WORKER/CONTROL/NONINT/ONCE_PER_BOOT/ACCOUNT/REPORT).
# 워커 이름은 **생략 가능**하다(구 reworker 호출은 인자가 없었다) —
# 생략하면 `.worker_name` 에서 읽는다. 구 restore.sh 인자 서식
# (`<워커> --control-node --non-interactive`)은 그대로 받는다.
WORKER=""
CONTROL=0
NONINT=0
ONCE_PER_BOOT=0
ACCOUNT=""
REPORT=0
# 동작 프로브(1-10)의 paid 항목까지 재는가(TASK-130). 기본 off — paid 는
# 러너 잡을 실제로 태우므로 opt-in 이어야 안전한 기본값이다(CR-0024).
DEEP=0
# 인스턴스 원시(TASK-136). 셋 다 "이 실행이 무엇을 하는가"를 가르는
# **모드**이며, 주면 5절 부활 흐름 대신 그 동작만 하고 끝난다(--instance
# 만 예외 - 그 인스턴스의 clone 에서 5절을 그대로 돌린다).
ADD_WORKER=""
REMOVE_WORKER=""
INSTANCE=""
INST_CLASS=""
INST_HOST=0
# 이관 retire 걸음(TASK-223) — 이 기계 러너의 **자기 등록**(`.runner` 의
# agentId)만 해제하고 끝난다. 이름이 아니라 id 로 지우는 이유: 동명 이관이면
# 신기계가 같은 이름으로 이미 등록(--replace)했으므로 이름으로 지우면 신기계
# 러너가 사라진다. 옛 id 가 이미 없으면(교체됨) 무동작이다.
RETIRE_RUNNER=0
# 러너 등록 API 대조(TASK-234 범위 4) — 지역 .runner 의 agentId 가 API 에 없으면
# stale 로 옮긴다(재등록은 1-8 이 한다). rollback 의 구기계 복귀 첫 걸음.
RUNNER_API_CHECK=0
# 자격 갱신 지정(TASK-233) — 쉼표 목록. ①-0 창구가 이 항목들만 have 여도
# 묻는다. 비면 종전 그대로(멱등, CR-0017).
RENEW=""
# 이관 부트스트랩(TASK-235 범위 6, 런 35968818253 실측) — 확인증·retire 전의 신기계는
# 러너를 등록하지 않고(--no-runner) 상주를 띄우지 않는다(--no-residents). 그 전에
# 등록하면 잡이 미로그인 신기계로 흘러 [FAIL] 하고, 같은 이름 등록 갈래가 (상주 정지로
# offline 인) 구기계 등록을 지운다. 둘은 MG-0130 m6b(retire 뒤)가 인자 없이 다시 돌려 한다.
NO_RUNNER=0
NO_RESIDENTS=0
# ⑥ 종단 알씨 접속 끄기(TASK-238). 기본은 켬 — 대화형·잡 밖·TTY 일 때만
# 요약 뒤 알씨 tmux 창으로 들어간다(판정은 `rc_attach_decide` 한 자리).
NO_ATTACH=0
# ⓪ 절만(TASK-333). 러너 자동 증설(`runner_health.py autoscale --apply`)이 기대
# 목록에 한 항을 더한 뒤 부르는 자리 — 5절 부활 흐름 전체(상주 재기동·관측·알씨)를
# 돌리지 않고 `inst_fill_expected` 하나만 돌고 끝난다(같은 원시, CR-0004).
FILL_EXPECTED=0
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --control-node)    CONTROL=1 ;;
      --non-interactive) NONINT=1 ;;
      --once-per-boot)   ONCE_PER_BOOT=1 ;;
      --report)          REPORT=1 ;;
      --deep)            DEEP=1 ;;
      --host)            INST_HOST=1 ;;
      --account)         ACCOUNT="${2:?--account 뒤에 계정 이름이 필요합니다}"; shift ;;
      --add-worker)      ADD_WORKER="${2:?--add-worker 뒤에 인스턴스 이름이 필요합니다}"; shift ;;
      --remove-worker)   REMOVE_WORKER="${2:?--remove-worker 뒤에 인스턴스 이름이 필요합니다}"; shift ;;
      --instance)        INSTANCE="${2:?--instance 뒤에 인스턴스 이름이 필요합니다}"; shift ;;
      --class)           INST_CLASS="${2:?--class 뒤에 부류(gpu|cpu|control)가 필요합니다}"; shift ;;
      --retire-runner)   RETIRE_RUNNER=1 ;;
      --runner-api-check) RUNNER_API_CHECK=1 ;;
      --no-runner)       NO_RUNNER=1 ;;
      --no-residents)    NO_RESIDENTS=1 ;;
      --no-attach)       NO_ATTACH=1 ;;
      --fill-expected)   FILL_EXPECTED=1 ;;
      --renew)           RENEW="${2:?--renew 뒤에 항목 id(쉼표 목록)가 필요합니다}"; shift ;;
      --*)               echo "알 수 없는 옵션: $1" >&2; return 1 ;;
      *)
        if [ -z "$WORKER" ]; then WORKER="$1"
        else echo "인자 과다: $1" >&2; return 1; fi ;;
    esac
    shift
  done
  if [ -n "$ADD_WORKER" ] && [ -n "$REMOVE_WORKER" ]; then
    echo "--add-worker 와 --remove-worker 는 함께 쓸 수 없습니다" >&2; return 1
  fi
  return 0
}

# 인스턴스 이름 서식. 러너 라벨·디렉터리 이름·claim holder 로 동시에
# 쓰이므로 셋 모두에 안전한 문자만 받는다(경로 탈출 `..`·`/` 차단이
# 이 판정의 첫 목적이다).
valid_instance_name() {  # $1=이름
  case "$1" in
    ""|*[!A-Za-z0-9_-]*) return 1 ;;
    -*|_*)               return 1 ;;
    *)                   return 0 ;;
  esac
}

# 부류 어휘·러너 필요 여부는 사전이 안다(config/instances.yml).
# 코드에 `if class == "control"` 을 새로 두지 않는다(CR-0010).
inst_class_ok() {  # $1=부류
  PYTHONPATH="$REWORKER_ROOT/scripts" python3 -c "
import sys
from core import instance
sys.exit(0 if sys.argv[1] in instance.runner_classes() else 1)
" "$1" 2>/dev/null
}
inst_class_has_runner() {  # $1=부류
  PYTHONPATH="$REWORKER_ROOT/scripts" python3 -c "
import sys
from core import instance
sys.exit(1 if sys.argv[1] in instance.no_runner_classes() else 0)
" "$1" 2>/dev/null
}

# 이 기계의 **다른** 인스턴스 중 러너 루프를 띄워 줘야 할 것들(TASK-136 9).
# 한 줄에 `<이름> <clone> <러너 디렉터리>`, 없으면 빈 출력.
#
# **목록의 진실은 디스크다**: `$YAC_ROOT/*/.yac_instance` 가 곧 이 기계의
# 인스턴스 목록이다 — 커밋되는 사전(`config/instances.yml`)에 기계 고유
# 사실을 두면 clone 마다 서로를 덮어쓴다(13-2 보강이 `YAC_TMP` 절대경로
# 결함에서 배운 것). 걸러내는 것은 셋이고 전부 판정에 근거가 있다:
#   ⓐ 자기 자신 — 자기 루프는 ②의 `ensure_resident` 가 이미 본다
#   ⓑ host 인스턴스 — 상주물 주체는 하나뿐이고 그것이 이 절을 돌리는 쪽이다
#   ⓒ 러너 없는 부류(control)·미등록 자리 — 띄울 러너가 없다(사전 판정)
inst_sweep_targets() {  # $1=저장소 디렉터리 이름 [$2=자기 인스턴스 이름]
  local repo_name="$1" self="${2:-}" id dir name cls host rd
  for id in "${YAC_ROOT:-/nonexistent}"/*/.yac_instance; do
    [ -f "$id" ] || continue
    dir="$(dirname "$id")"
    name="$(yac_decl "$id" NAME)"
    [ -n "$name" ] || continue
    [ -n "$self" ] && [ "$name" = "$self" ] && continue
    host="$(yac_decl "$id" HOST)"
    [ "$host" = 1 ] && continue
    cls="$(yac_decl "$id" CLASS)"
    inst_class_has_runner "$cls" || continue
    rd="$dir/actions-runner"
    [ -f "$rd/.runner" ] || continue
    printf '%s %s %s\n' "$name" "$dir/$repo_name" "$rd"
  done
}

# 다른 인스턴스로 들어가는 실행 앞에서 **걷어낼 환경변수 이름 전수**.
#
# 둘로 갈린다. ⓐ 경로·신원 변수: `core/instance.sh` 의 결정 순위가
# `환경변수 > 선언 > 파생` 이라, 물려주면 새 인스턴스가 남의 임시 구역·
# 남의 러너 자리를 문다(2026-09-05 실측: 새 러너 루프가 host 의 락을 보고
# "이미 실행 중"으로 조용히 종료). ⓑ **잡 표지**(`RUNNER_*`·`GITHUB_*`·
# `ACTIONS_*`): 물려주면 자식이 스스로를 "잡 안"으로 판정해 상주 기동을
# 건너뛰고, 러너의 잡 사후 정리가 그 표지를 단 무리를 함께 거둬 간다
# (잡이 끝나자 c1·c2 러너가 offline 이 된 경위, TASK-136 9). ⓑ 를 고정
# 목록으로 적지 않고 실행 시점 환경에서 전수하는 이유는 러너가 잡마다
# 다른 변수를 더하기 때문이다 — 손 목록은 새 변수 하나를 조용히 놓친다.
inst_env_clear_names() {
  printf '%s\n' YAC_HOME YAC_ROOT YAC_DATA YAC_TMP YAC_RUNNER_DIR \
    YAC_INSTANCE_REPO YAC_INSTANCE_NAME YAC_INSTANCE_CLASS \
    YAC_INSTANCE_HOST YAC_MACHINE
  env | sed -n 's/^\(RUNNER_[A-Za-z0-9_]*\|GITHUB_[A-Za-z0-9_]*\|ACTIONS_[A-Za-z0-9_]*\)=.*/\1/p' \
    | sort -u
}

# ── 기대 인스턴스 보충 (TASK-238, 13-2 보강) ────────────────────────────
# "무엇이 있어야 하는가"는 사전(`config/instances.yml` `expected_instances`,
# **기계 이름 키** — 그래서 clone 끼리 덮어쓰지 않는다, 사용자 승인
# JL-2026-09-1037)이 답하고, "지금 무엇이 있는가"는 종전대로 디스크
# (`$YAC_ROOT/*/.yac_instance`, `inst_sweep_targets` 와 같은 열거·`yac_decl`
# 독취)가 답한다. 둘의 차이만 기존 `inst_add` 로 세운다(새 원시 0, CR-0004) —
# 있으면 무동작(멱등, CR-0017), 부류가 사전 어휘 밖이면 그 항만 잔여(코드에
# 이름·부류 하드코딩 0, CR-0010), 잡 안이면 보고만(러너 등록은 잡 밖 host 몫,
# 136 2차 ⓑ 그대로). 판정·집계는 순수 함수라 시험이 `inst_add` 를 모의로
# 갈아 끼워 "몇 번 불렸는가"를 실측한다.
inst_present_names() {  # [$1=자기 인스턴스 이름] → 실재 인스턴스 이름(한 줄 하나)
  local id name
  [ -n "${1:-}" ] && printf '%s\n' "$1"
  for id in "${YAC_ROOT:-/nonexistent}"/*/.yac_instance; do
    [ -f "$id" ] || continue
    name="$(yac_decl "$id" NAME)"
    [ -n "$name" ] && printf '%s\n' "$name"
  done
  return 0
}
# 사전 독취는 파이썬 면 한 자리(`instance.expected_instances`)다.
# `INST_EXPECTED_CONFIG` 는 시험 이음매(모의 사전 경로).
inst_expected_list() {  # $1=기계 → 한 줄에 `<이름> <부류>`
  PYTHONPATH="$REWORKER_ROOT/scripts" python3 "$REWORKER_ROOT/scripts/core/instance.py" \
    expected --machine "$1" ${INST_EXPECTED_CONFIG:+--config "$INST_EXPECTED_CONFIG"} 2>/dev/null
}
inst_expected_missing() {  # $1=기계 [$2=자기 이름] → 기대에는 있는데 실재하지 않는 `<이름> <부류>`
  local present name cls
  present=" $(inst_present_names "${2:-}" | tr '\n' ' ') "
  while read -r name cls; do
    [ -n "$name" ] || continue
    case "$present" in *" $name "*) continue ;; esac
    printf '%s %s\n' "$name" "$cls"
  done <<INST_EXP_EOF
$(inst_expected_list "$1")
INST_EXP_EOF
}
# `--add-worker <이름> --class <부류>` 와 **같은 원시**를 부류 인자로 부른다
# (host 아님). 전역 INST_CLASS/INST_HOST 는 그 모드의 인자 자리라 잠깐 빌려
# 쓰고 되돌린다.
inst_add_as() {  # $1=이름 $2=부류
  local _c="${INST_CLASS:-}" _h="${INST_HOST:-0}" rc=0
  INST_CLASS="$2"; INST_HOST=0
  inst_add "$1" || rc=$?
  INST_CLASS="$_c"; INST_HOST="$_h"
  return $rc
}
inst_fill_expected() {  # $1=기계 $2=자기 이름 $3=잡 안(1/0) → ok/fix/bad 에 집계
  local machine="$1" self="${2:-}" in_job="${3:-0}" name cls
  local n_exp n_miss=0 added="" failed="" unknown="" pending=""
  n_exp="$(inst_expected_list "$machine" | grep -c .)"
  if [ "${n_exp:-0}" = 0 ]; then
    ok "기대 인스턴스 사전 미선언(기계 $machine — config/instances.yml expected_instances) — 보충 대상 없음"
    return 0
  fi
  while read -r name cls; do
    [ -n "$name" ] || continue
    n_miss=$((n_miss + 1))
    if ! inst_class_ok "$cls"; then
      unknown="$unknown $name($cls)"; continue
    fi
    if [ "$in_job" = 1 ]; then
      pending="$pending $name($cls)"; continue
    fi
    say "기대 인스턴스 '$name'(부류 $cls) 미실재 — inst_add 로 세운다(--add-worker 와 같은 원시)"
    if inst_add_as "$name" "$cls"; then added="$added $name"; else failed="$failed $name"; fi
  done <<INST_MISS_EOF
$(inst_expected_missing "$machine" "$self")
INST_MISS_EOF
  if [ "$n_miss" = 0 ]; then
    ok "기대 인스턴스 전수 실재(${n_exp}개, 기계 $machine)"
  fi
  [ -n "$unknown" ] && bad "기대 인스턴스 부류 미등재(config/instances.yml runner_classes 밖) — 그 항만 잔여:$unknown"
  [ -n "$pending" ] && bad "기대 인스턴스 미실재 $(echo "$pending" | wc -w)개 — 잡 안이라 세우지 않음(host 셸에서 'bash scripts/reworker.sh'):$pending"
  [ -n "$added" ]   && fix "기대 인스턴스 $(echo "$added" | wc -w)개 보충(inst_add, 기대 $n_exp):$added"
  [ -n "$failed" ]  && bad "기대 인스턴스 보충 실패(inst_add 사유는 위 줄):$failed"
  return 0
}

# ── 활성 프로젝트 파이썬 의존 (TASK-238 범위 4, JL-2026-09-1062) ──────────
# 프레임 최소 의존(1-4, `config/py_requirements.txt`) 뒤에 프로젝트 고유
# 목록(`projects/<id>/config/py_requirements.txt` 가 있는 것 전부)을 **같은
# 통로**(`py_deps_ensure.sh`)로 확보한다 — 신기계에서 hrdk 정의서 parse
# 1,200건이 olefile·pypdf·torch 부재로 전부 실패해 잡이 시한 kill 된 실측.
# 잡 안이면 확인만(`YAC_PY_CHECK_ONLY=1`)·설치는 보고다. `py_deps_run` 은
# 시험 이음매(모의로 갈아 "무엇이 몇 번 불렸는가"를 잰다).
py_deps_run() { bash "$REWORKER_ROOT/scripts/py_deps_ensure.sh" "$@"; }
# 외부 import 전수 대조 검사 칸(TASK-576 범위 1) — agents/*.py 의 외부 import ⊆ py_requirements.txt ∪ py_optional.txt.
# 목록에 빠진 모듈은 설치 통로가 영영 모른다(소비처의 늦은 import 는 셋업 검사에 안 잡힌다 — 실측 reportlab rc 1 × 3회차).
# 잡 안·밖 같은 판정(설치 0 · 보고만) · 시험 이음매(`py_imports_run`)는 모의로 갈 수 있다.
py_imports_run() { python3 "$REWORKER_ROOT/scripts/py_imports_check.py" "$@"; }
project_py_imports_check() {  # $1=저장소 루트 → 목록 있는 프로젝트마다 ok/bad 한 칸(설치 0 · 판정만)
  local root="$1" req pid out
  for req in "$root"/projects/*/config/py_requirements.txt; do
    [ -f "$req" ] || continue
    pid="$(basename "$(dirname "$(dirname "$req")")")"
    if out="$(py_imports_run --root "$root" "$pid" 2>&1)"; then
      ok "프로젝트 $pid 외부 import 전수 등재(py_imports_check)"
    else
      bad "프로젝트 $pid 외부 import 미등재 — $(printf '%s\n' "$out" | grep '미등재 import' | head -3 | tr '\n' ' ')(projects/$pid/config/py_requirements.txt 또는 py_optional.txt 등재 뒤 'bash scripts/py_deps_ensure.sh projects/$pid/config/py_requirements.txt')"
    fi
  done
  return 0
}
project_py_deps_ensure() {  # $1=저장소 루트 $2=잡 안(1/0) → ok/fix/bad 에 집계
  local root="$1" in_job="${2:-0}" req pid rel n=0 out installed
  for req in "$root"/projects/*/config/py_requirements.txt; do
    [ -f "$req" ] || continue
    n=$((n + 1))
    pid="$(basename "$(dirname "$(dirname "$req")")")"
    rel="projects/$pid/config/py_requirements.txt"
    if [ "$in_job" = 1 ]; then
      if YAC_PY_CHECK_ONLY=1 py_deps_run "$req" >/dev/null 2>&1; then
        ok "프로젝트 $pid 파이썬 의존 확인($rel, 잡 안 — 확인만)"
      else
        bad "프로젝트 $pid 파이썬 의존 미확보($rel) — 잡 안이라 설치하지 않음: host 셸에서 'bash scripts/reworker.sh'(또는 'bash scripts/py_deps_ensure.sh $rel')"
      fi
      continue
    fi
    out="$(py_deps_run "$req" 2>&1)" && {
      installed="$(printf '%s\n' "$out" | grep -c '설치됨:')"
      if [ "${installed:-0}" -gt 0 ]; then
        fix "프로젝트 $pid 파이썬 의존 ${installed}건 설치($rel)"
      else
        ok "프로젝트 $pid 파이썬 의존 확보($rel)"
      fi
      continue
    }
    bad "프로젝트 $pid 파이썬 의존 일부 미확보 — 'bash scripts/py_deps_ensure.sh $rel' 출력의 실패 줄이 수동 설치 명령을 알려준다"
  done
  [ "$n" = 0 ] && ok "프로젝트 파이썬 의존 목록 없음(projects/*/config/py_requirements.txt 0건)"
  return 0
}

# ── 상태 원장 세우기 (TASK-687 범위 2) ───────────────────────────────────
# 사전 `config/instances.yml` `seed_state_ledgers`(저장소 루트 상대, 쉼표)의 원장이
# 없으면 빈 파일로 세운다 — 있으면 무변경(덮기 0, CR-0024) · 멱등(CR-0017). 새 기계
# 에서 행이 아직 없다는 이유로 계기 신호 좌표 실존(170b ⓐ)이 실패하던 것의 처방.
# 절대경로·`..` 항은 세우지 않고 잔여로 남긴다. 결과는 ok/fix/bad 한 줄(CR-0006).
state_ledger_seed() {  # $1=저장소 루트
  local root="$1" list p made="" have=0 rej=""
  list="$(sed -n 's/^seed_state_ledgers: *//p' "$root/config/instances.yml" 2>/dev/null | head -1 | sed 's/ *#.*//')"
  [ -n "$list" ] || { ok "상태 원장 세울 목록 없음(config/instances.yml seed_state_ledgers 비어 있음)"; return 0; }
  for p in $(printf '%s' "$list" | tr ',' ' '); do
    case "$p" in /*|*..*) rej="$rej $p"; continue ;; esac
    if [ -e "$root/$p" ]; then have=$((have + 1)); continue; fi
    if mkdir -p "$(dirname "$root/$p")" 2>/dev/null && : > "$root/$p" 2>/dev/null; then
      made="$made $p"
    else
      rej="$rej $p"
    fi
  done
  [ -n "$made" ] && fix "상태 원장 $(echo "$made" | wc -w)건 빈 파일로 세움(seed_state_ledgers):$made"
  [ "$have" -gt 0 ] && ok "상태 원장 ${have}건 실존(무변경)"
  [ -n "$rej" ] && bad "상태 원장 세우기 실패·거부(절대경로·'..'·쓰기 실패):$rej"
  return 0
}

# ── ⑥ 알씨 접속 판정 (TASK-238 범위 2) ──────────────────────────────────
# 순수 판정: 전역 NO_ATTACH/NONINT/ONCE_PER_BOOT/IN_JOB 과 TMUX 환경, 인자로
# 받은 TTY 여부만 본다 → `attach` | `switch`(이미 tmux 안) | `skip:<사유>`.
# 부팅 훅(`--non-interactive`·`--once-per-boot`)·잡·이관 활성화(m6b 는
# `--non-interactive`)는 전부 skip 갈래다 — 사람이 앉아 있는 터미널에서만
# 들어간다. TTY 판정은 호출자가 잰다(`-t 0`·`-t 1` 둘 다).
rc_attach_decide() {  # $1=tty(1/0) → attach|switch|skip:<사유>
  local tty="${1:-0}"
  if [ "${NO_ATTACH:-0}" = 1 ]; then echo "skip:--no-attach"; return 0; fi
  if [ "${NONINT:-0}" = 1 ]; then echo "skip:비대화 모드(--non-interactive)"; return 0; fi
  if [ "${ONCE_PER_BOOT:-0}" = 1 ]; then echo "skip:부팅 훅(--once-per-boot)"; return 0; fi
  if [ "${IN_JOB:-0}" = 1 ]; then echo "skip:잡 안"; return 0; fi
  if [ "$tty" != 1 ]; then echo "skip:TTY 아님"; return 0; fi
  if [ -n "${TMUX:-}" ]; then echo switch; else echo attach; fi
}
# TTY 는 **전역 변수로** 잰다(RC_TTY) — 명령 치환 `$( … [ -t 1 ] … )` 안에서
# 재면 stdout 이 파이프라 `-t 1` 이 언제나 거짓이고, 그래서 사람이 앉은
# 터미널에서도 "TTY 아님" 으로 물러난다(238 재발사 검토 실측 —
# 1차 [WIP] 25c67776 의 결함). 판정 함수는 이 값만 인자로 받는다.
rc_tty_probe() {  # → RC_TTY=1(표준입력·출력 둘 다 터미널)|0
  RC_TTY=0
  if [ -t 0 ] && [ -t 1 ]; then RC_TTY=1; fi
  return 0
}

# 저장소 설정(TASK-125)을 이 인스턴스가 **적용**해도 되는가.
# 변수 `WORKER` 는 기계 하나에 한 벌이라 비-host 가 적용하면 자기 이름으로
# 되쓴다(TASK-136 10 실측) — 비-host 는 보되 손대지 않는다.
repo_settings_mode() {  # $1=host 여부(1/0)
  if [ "${1:-1}" = 1 ]; then echo apply; else echo diff; fi
}

# 계정 기본값: root 로 실행 중일 때만 $SUDO_USER 를 대행 계정으로 본다.
# (일반 계정 세션에도 $SUDO_USER=root 가 남아 있는 환경이 있다 — vast1
# 실측. 그걸 그대로 믿으면 훅 문구가 `su - root` 로 나가 자기 자신을
# 계정으로 되돌리지 못한다.)
default_account() {
  if [ "$(id -u)" = 0 ]; then echo "${SUDO_USER:-root}"; else id -un; fi
}

# 사람 입력 단계의 분기 판정. 완료 표식 파일과 모드만 보는 순수 함수다.
#   have  : 디스크에 이미 있음 — 통과
#   human : 없고 비대화 모드 — 안내 1줄 남기고 그 절만 건너뜀
#   ask   : 없고 대화 모드 — 사람에게 묻는다
input_gate() {
  if [ -s "$1" ]; then echo have
  elif [ "${NONINT:-0}" = 1 ]; then echo human
  else echo ask
  fi
}

# 부팅 훅에 넣을 줄 조립(전역 WORKER/CONTROL/ACCOUNT/ROOT/REVIVE_LOG 만
# 읽는 순수 함수 — 문자열을 stdout 으로 낼 뿐 어디에도 기입하지 않는다).
#   revive_line root : /root/onstart.sh 용(root 로 돌므로 계정에 위임)
#   revive_line user : ~/.bashrc·crontab @reboot 용(--once-per-boot 로
#                      둘이 겹쳐 쏘는 것을 막는다)
# 훅 문구는 **`restore.sh` 를 그대로 부른다**(TASK-107 2): 별칭이라
# 종착은 이 파일이고, 이미 등재된 훅 줄을 건드리지 않아 재등록·중복
# 위험이 없다(멱등 판정의 근거인 표식 문구도 그대로다).
revive_line() {
  local args="$WORKER"
  [ "${CONTROL:-0}" = 1 ] && args="$args --control-node"
  args="$args --non-interactive --account $ACCOUNT"
  case "${1:-user}" in
    root) printf "su - %s -c 'cd %s && bash scripts/restore.sh %s' >> %s 2>&1\n" \
            "$ACCOUNT" "$ROOT" "$args" "$REVIVE_LOG" ;;
    user) printf 'cd %s && bash scripts/restore.sh %s --once-per-boot >> %s 2>&1\n' \
            "$ROOT" "$args" "$REVIVE_LOG" ;;
    *)    echo "revive_line: root|user 중 하나" >&2; return 1 ;;
  esac
}

# 부팅 훅 줄에 붙이는 표식. 멱등 판정(재실행 시 중복 append 방지)의
# 유일한 근거이므로 문구를 바꾸면 기존 등재분이 미등록으로 오판된다.
REVIVE_MARK="# yac-revive(TASK-097) — 재부팅 자동 부활. restore.sh 가 관리하는 줄"

# 권한 대행. onstart 훅은 root 소유(0700 /root 아래)라 존재·중복 검사부터
# 권한이 필요하다 — 권한 없이 검사하면 "읽기 실패=미등록"으로 오판해
# 재실행마다 같은 줄을 덧붙인다(멱등 파괴).
priv() { if [ -n "${SUDO:-}" ]; then $SUDO "$@"; else "$@"; fi; }

# 관리 줄 멱등 등재. 표식이 이미 있으면 무변화(2회 실행해도 파일 동일).
register_revive_line() {  # $1=파일 $2=줄 [$3=라벨]
  local file="$1" line="$2" label="${3:-부팅 훅}"
  if grep -q 'yac-revive' "$file" 2>/dev/null; then
    echo "$label 이미 등록됨 — 건너뜀($file)"
    return 0
  fi
  printf '\n%s\n%s\n' "$REVIVE_MARK" "$line" >> "$file" \
    && echo "$label 등록($file)" \
    || { echo "경고: $file 기입 실패" >&2; return 1; }
}

# onstart 훅(1순위) 등재. 0=등재됨(또는 이미 등재) / 1=미등재(폴백 필요).
register_onstart() {  # $1=파일 $2=줄
  local file="$1" line="$2"
  if [ "${ROOTOK:-0}" != 1 ]; then
    echo "안내: root 권한이 없어 $file 등록을 건너뜁니다(계정 쪽 폴백으로 대신). root 셸에서 1회:"
    echo "  grep -q yac-revive $file || printf '\\n%s\\n%s\\n' \"$REVIVE_MARK\" \"$line\" >> $file"
    return 1
  fi
  if ! priv test -e "$file"; then
    echo "$file 없음 — 계정 쪽 폴백으로 등록"
    return 1
  fi
  if priv grep -q 'yac-revive' "$file"; then
    echo "부팅 훅 이미 등록됨($file) — 건너뜀"
    return 0
  fi
  if printf '\n%s\n%s\n' "$REVIVE_MARK" "$line" | priv tee -a "$file" >/dev/null; then
    echo "부팅 훅 등록($file)"
    return 0
  fi
  echo "경고: $file 기입 실패" >&2
  return 1
}

# 크론 3종의 등재 여부(문자열이 아니라 **패턴 존재**로만 본다 — 줄
# 문면의 단일 원천은 bootstrap_worker.sh 다). 미등재 항목 이름을
# 공백으로 나열해 낸다(전부 있으면 빈 문자열).
#
# **크론은 기계 하나에 한 벌이다(TASK-136).** crontab 은 OS 계정 소유라
# 같은 기계의 인스턴스들이 통째로 공유한다 — 인스턴스마다 등재하면 30분
# 체크포인트가 N중으로 돌며 서로를 덮어쓴다. 그래서 비-host 인스턴스에는
# 등재 대상 자체가 없다(공백 0).
#
# `crontab` 명령 자체가 없는 기계(cron 없는 컨테이너, TASK-581 vast2 실측)는
# 3종 이름 대신 원인 하나 `crontab없음` 을 낸다 — bootstrap 은 그 기계에서
# 등재를 건너뛰므로(치명 아님) 잔여 공백의 문면이 "무엇이 빠졌나"가 아니라
# "왜 못 채우나"여야 사람이 다음 손(cron 설치)을 안다(CR-0016·CR-0123).
missing_cron() {
  local out="" tab
  [ "${YAC_INSTANCE_HOST:-1}" = 1 ] || { printf '%s' ""; return 0; }
  command -v crontab >/dev/null 2>&1 || { printf '%s' "crontab없음"; return 0; }
  tab="$(crontab -l 2>/dev/null || true)"
  printf '%s' "$tab" | grep -q 'checkpoint\.sh'    || out="$out checkpoint"
  printf '%s' "$tab" | grep -q 'yac_tmp_clean\.sh' || out="$out yac_tmp_clean"
  if [ -f "${YAC_OBSV_HOME:-${YAC_HOME:-$HOME}/obsv}/CONTROL_NODE" ]; then
    printf '%s' "$tab" | grep -q 'obsv_boot\.sh'   || out="$out obsv_boot"
  fi
  printf '%s' "${out# }"
}

# 셋업 공백 목록(워커 신원·claude·임시 구역·크론 3종). 판정만 하는
# 함수라 시험에서 그대로 부를 수 있다 — 채우는 것은 호출자가
# bootstrap_worker.sh 에 위임한다(줄 문면의 단일 원천이 거기다).
setup_gaps() {  # $1=저장소 루트
  local root="$1" out="" cm
  [ -s "$root/.worker_name" ] || out="$out 워커이름"
  ( cd "$root" 2>/dev/null && git config user.name >/dev/null 2>&1 ) || out="$out git신원"
  command -v claude >/dev/null 2>&1 || [ -x "$HOME/.local/bin/claude" ] || out="$out claude"
  if [ -z "${YAC_TMP:-}" ] || [ ! -d "$YAC_TMP/scratch" ] || [ ! -d "$YAC_TMP/live" ]; then
    out="$out 임시구역"
  fi
  cm="$(missing_cron)"
  [ -n "$cm" ] && out="$out 크론($cm)"
  printf '%s' "${out# }"
}

# ⑤ 통보 한 줄 조립. 전역 OK/FIX/BAD/NEED 배열만 읽는다 — 순수 함수라
# 시험이 배열을 채워 놓고 문면을 그대로 확인할 수 있다.
#
# **고친 항목 이름을 반드시 싣는다**: 숫자만으로는 무엇이 죽어 있었는지
# 알 수 없어 "정상 7·복구 8"이 2026-08-31 처럼 안심 신호로 오독된다.
# 괄호 안의 상세(PID·경로 등)는 잘라 이름만 남긴다.
fix_names() {
  local out="" m
  for m in "${FIX[@]:-}"; do
    [ -n "$m" ] || continue
    out="$out, ${m%%(*}"
  done
  printf '%s' "${out#, }"
}
# 입력 필요 항목은 "이름 — 어디에 넣어라" 서식이므로 이름만 뽑는다.
need_names() {
  local out="" m
  for m in "${NEED[@]:-}"; do
    [ -n "$m" ] || continue
    out="$out, ${m%% —*}"
  done
  printf '%s' "${out#, }"
}
# unlock 전 상태에서 난 잔여의 수(TASK-582 범위 2). RW_LOCKED=1 이고
# RW_LOCKED_BAD_FROM(unlock 실패 직후 BAD 길이) 이후 항목 중 암호문·모듈
# 부재 표지(ImportError·ModuleNotFoundError·No module named·Traceback·
# 암호문)가 있는 것만 센다 — 다른 원인의 잔여는 접지 않는다(정직, CR-0016).
# 순수 함수(전역 배열·두 변수만 읽는다).
#
# 표지 목록은 사전 `config/rebuild.yml` `reworker_locked_bad_markers`(쉼표 구분)
# 가 갖는다(TASK-663 ⓒ, CR-0010). 실측 2026-10-23 05:1x vast2: unlock 전 항은
# 9건(core 모듈 import 오류 7 · yac-state 「저장소 키 확보 후 재실행」 · 로컬 LLM)
# 인데 종전 손 목록 다섯은 그중 3건만 세어 묶음 줄이 「unlock 전 3건」으로 났다
# — 사람이 잔여 9건을 여섯 원인으로 읽게 하는 오계수다(CR-0016). 사전을 못
# 읽으면 종전 다섯 표지로 폴백한다(CR-0024).
locked_bad_markers() {  # -> 쉼표 구분 표지 한 줄
  local f="${REWORKER_ROOT:-.}/config/rebuild.yml" v=""
  v="$(sed -n 's/^reworker_locked_bad_markers:[[:space:]]*//p' "$f" 2>/dev/null | head -1 | sed 's/[[:space:]]*$//')"
  [ -n "$v" ] || v="ImportError,ModuleNotFoundError,No module named,Traceback,암호문"
  printf '%s' "$v"
}
locked_bad_fold() {
  local i n=0 m mk hit
  [ "${RW_LOCKED:-0}" = 1 ] || { printf 0; return 0; }
  local IFS_SAVE="$IFS" markers=()
  IFS=',' read -r -a markers <<< "$(locked_bad_markers)"
  IFS="$IFS_SAVE"
  for ((i = ${RW_LOCKED_BAD_FROM:-0}; i < ${#BAD[@]}; i++)); do
    m="${BAD[$i]}"; hit=0
    for mk in "${markers[@]}"; do
      mk="${mk# }"; mk="${mk% }"
      [ -n "$mk" ] || continue
      case "$m" in *"$mk"*) hit=1; break ;; esac
    done
    [ "$hit" = 1 ] && n=$((n + 1))
  done
  printf '%s' "$n"
}
summary_line() {  # $1=워커 이름
  local w="${1:-worker}" msg f n lk
  f="$(fix_names)"; n="$(need_names)"; lk="$(locked_bad_fold)"
  msg="${w} reworker: 정상 ${#OK[@]}·복구 ${#FIX[@]}·잔여 ${#BAD[@]}"
  [ -n "$f" ] && msg="$msg | 고침: $f"
  [ -n "$n" ] && msg="$msg | 입력 필요: $n"
  [ "$lk" -gt 0 ] 2>/dev/null && msg="$msg | 잔여 중 ${lk}건은 unlock 전(저장소 키 미전달 — ENROLL §2 전달 뒤 재실행에서 다시 판정)"
  if [ ${#BAD[@]} -eq 0 ] && [ ${#NEED[@]} -eq 0 ]; then
    printf '[OK] %s' "$msg"
  else
    printf '[WARN] %s' "$msg"
  fi
}

# ── 중단 내성 (TASK-116f 범위 0, PROTOCOL 4-1 "중단 계약") ────────────
#
# 사람은 창구 중간에 손을 뗀다 — 2026-09-12 05:52 실측: 두 번째 실행
# (PID 3462153)이 Ctrl+Z 로 STAT T(일시정지)에 13분 매달렸고 자식
# `timeout` 은 좀비로 남았다. 좀비의 원인은 하나다: **정지된 부모는
# 거두지 못한다**. 그리고 bash 는 스크립트를 점진 읽기 하므로, 정지된
# 옛 프로세스를 나중에 재개하면 그 사이 갱신된 파일의 뒷부분을 이어
# 읽는다 — 반쯤 한 상태가 반쯤 다른 코드로 이어지는 갈래다.
#
# 그래서 정지 상태로 매달리는 갈래 자체를 없앤다. TSTP 도 **받아서**
# 중단 처리로 넘긴다(무시만 하면 부모는 안 멈춰도 터미널이 같은
# 프로세스 그룹에 보낸 TSTP 로 자식이 멈춰 부모가 그것을 기다리며
# 매달린다 — 같은 증상이 자리만 옮긴다).
#
# 중단이 남기지 않는 것 셋: 좀비·반쯤 쓴 임시 표지·무엇을 하다 말았는지
# 모를 침묵(CR-0006). 재실행은 멱등이므로(TASK-107) 이어 하면 된다는
# 사실을 그 한 줄에 같이 싣는다.
REWORKER_PHASE="${REWORKER_PHASE:-시작 전}"   # 지금 어느 절인가(중단 문면의 본문)
REWORKER_TEMPS=""                              # 이 실행이 만든 임시 표지·락(가진 것만)
REWORKER_INTERRUPTED=0
RW_WAIT_PID=""                                 # rw_wait 가 지금 기다리는 자식

rw_phase() { REWORKER_PHASE="$1"; }

# 오래 걸리는 외부 명령은 **이 원시로** 돈다(TASK-116f 범위 0).
#
# 실측(2026-09-12): 포그라운드로 직접 기다리면 bash 는 트랩을 **그 명령이
# 끝날 때까지 미룬다**("If bash is waiting for a command to complete and
# receives a signal for which a trap has been set, the trap will not be
# executed until the command completes"). 그리고 `timeout` 은 관리 대상을
# **새 프로세스 그룹**에 넣으므로 터미널의 Ctrl+C 가 거기엔 닿지도 않는다 —
# 둘이 겹쳐, `timeout 300 bash obsv_boot.sh` 중의 Ctrl+C 는 300초 동안
# 아무 일도 일으키지 않았다(rc=중단 없음·자식 2 잔존·중단 문면 0).
# `wait` 는 다르다: 트랩이 오면 즉시 깨어나고 rc>128 을 돌려준다.
#
# `timeout` 쪽을 `--foreground` 로 바꾸는 길도 있었으나 그것은 "COMMAND 의
# 자식은 타임아웃 대상이 아니다"라는 **다른 계약 변경**을 끌고 온다 —
# 중단을 고치자고 시한 계약을 흔들지 않는다(CR-0003 확산 차단).
rw_wait() {  # $@=명령 — 명령의 rc 를 그대로 돌려준다
  local rc=0
  "$@" &
  RW_WAIT_PID=$!
  wait "$RW_WAIT_PID" || rc=$?
  RW_WAIT_PID=""
  return $rc
}

# 정리 대상 등록. 지우는 것은 **이 실행이 스스로 만든 것**뿐이다 —
# 남이 쥔 락을 중단 처리가 걷어내면 그것이 곧 다음 사고다.
rw_temp_track() { REWORKER_TEMPS="$REWORKER_TEMPS $1"; }

# 회수 대상 자식 = 포그라운드 자식뿐. `&` 로 띄운 상주물(러너 루프·
# 리스너·워치독)은 **살려 둔다** — 중단이 그것들을 함께 죽이면 부분
# 부활조차 남지 않는다(①의 부분 부활 > 전무 원칙과 같은 결). 백그라운드
# 잡은 bash 가 `jobs -p` 로 알므로 그 차집합이 곧 포그라운드 자식이다.
rw_foreground_children() {
  local bg p
  bg=" $(jobs -p 2>/dev/null | tr '\n' ' ') "
  # `rw_wait` 가 기다리는 자식은 문법상 배경 잡이지만 뜻은 포그라운드다 —
  # 그것을 상주물로 오인해 남겨 두면 중단이 정확히 그 긴 명령을 남긴다.
  [ -n "${RW_WAIT_PID:-}" ] && printf '%s\n' "$RW_WAIT_PID"
  for p in $(pgrep -P $$ 2>/dev/null); do
    [ "$p" = "${RW_WAIT_PID:-}" ] && continue
    case "$bg" in *" $p "*) continue ;; esac
    printf '%s\n' "$p"
  done
}

# 자식 회수. TERM 뒤에 **CONT 를 반드시 보낸다** — 정지(T)된 자식은
# TERM 을 받아 두기만 하고 깨어나지 않으면 처리하지 않는다(Ctrl+Z 갈래의
# 좀비가 정확히 그 상태였다). 목록은 첫 계측에서 고정한다: 두 번째
# 계측은 이 함수 자신의 `sleep` 을 자식으로 세기 때문이다.
rw_reap_children() {
  local kids p n=0
  kids="$(rw_foreground_children)"
  for p in $kids; do
    kill -TERM "$p" 2>/dev/null || true
    kill -CONT "$p" 2>/dev/null || true
    n=$((n + 1))
  done
  REWORKER_REAPED="$n"
  [ "$n" = 0 ] && return 0
  sleep 1
  for p in $kids; do
    kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null || true
  done
  return 0
}

rw_cleanup_temps() {
  local f
  for f in $REWORKER_TEMPS; do
    [ -n "$f" ] || continue
    [ -e "$f" ] && rm -f "$f" 2>/dev/null
  done
  REWORKER_TEMPS=""
  return 0
}

# 중단 한 벌. 재진입(중단 처리 중에 또 오는 신호)은 첫 것만 산다.
rw_interrupt() {  # $1=신호 이름 $2=종료 코드
  local sig="${1:-INT}" rc="${2:-130}"
  [ "${REWORKER_INTERRUPTED:-0}" = 1 ] && return 0
  REWORKER_INTERRUPTED=1
  trap '' INT TERM HUP TSTP
  rw_reap_children
  rw_cleanup_temps
  echo "[reworker] 중단됨($sig) — ${REWORKER_PHASE} 까지 수행, 다시 실행하면 이어진다(멱등 — 끝난 절은 다시 손대지 않는다)"
  exit "$rc"
}

# 신호→종료 코드는 128+번호 관례 그대로다(INT 2·HUP 1·TERM 15).
#
# **TSTP 는 잡지 않고 막는다.** 잡는 길(`trap 'rw_interrupt TSTP 148'`)을
# 먼저 재 봤고 그 길은 서지 않는다(2026-09-12 실측): Ctrl+Z 는 포그라운드
# **그룹 전체**에 가므로 자식이 먼저 멈추고, 트랩은 "그 명령이 끝날 때까지"
# 미뤄지는데 멈춘 자식은 끝나지 않는다 — 부모는 T 대신 S 로 매달릴 뿐
# 매달리는 것은 같았다(rc=hang·자식 정지 1). `set -m`(작업 제어)으로 그
# 정지를 인지시키는 길도 재 봤는데, 그러면 이번엔 자식이 멈춘 채로 다음
# 절이 진행됐다 — 더 나쁘다.
#
# 반면 `trap '' TSTP`(무시)는 **자식에게 상속된다**(무시 처분은 fork·exec
# 를 건너 전해진다 — 실측: 자식 SigIgn 에 SIGTSTP 비트). 그래서 Ctrl+Z 로
# 멈출 수 있는 프로세스가 이 계보에 하나도 남지 않는다. 정지 상태로
# 매달리는 갈래를 "처리"하는 대신 **존재하지 않게** 하는 쪽이 원천이다
# (CR-0001). 멈추고 싶은 사람에게는 Ctrl+C 가 있고, 그쪽은 위 중단 처리가
# 깨끗이 받는다 — 그 사실을 시작 한 줄로 알린다(무소음 금지, CR-0006).
rw_install_traps() {
  trap 'rw_interrupt INT 130'  INT
  trap 'rw_interrupt TERM 143' TERM
  trap 'rw_interrupt HUP 129'  HUP
  trap '' TSTP
}

# ── 자격 갱신(TASK-233, PLN-1022) ─────────────────────────────────────
# ①-0 창구는 멱등이라 have 를 묻지 않는다 — 그래서 **값이 있는데 갈아야
# 하는** 경우(계정이 바뀐 Vast 키 등)를 받을 자리가 없었다. 새 입력 자리를
# 만들지 않고 같은 창구에 "이 항목은 have 여도 묻는다" 는 지정만 얹는다
# (CR-0015). 기입 뒤 지문 재기준도 종전 갈래 그대로 탄다 — 창구 밖 직접
# fill 이 건너뛰던 그 걸음이다.
renew_wanted() {  # $1=id -> 0=갱신 지정됨
  case ",${RENEW:-}," in *",$1,"*) return 0 ;; esac
  return 1
}
renew_hint() {  # $1=id -> 사전 renew_hint 한 줄(문면 원천은 사전 하나)
  PYTHONPATH="$REWORKER_ROOT/scripts" python3 \
    "$REWORKER_ROOT/scripts/core/cred_intake.py" renew-hint "$1" 2>/dev/null
}
# 실행 첫머리 관문 — 반쯤 돈 뒤에 거부하지 않는다. 등재 판정(미등재·폐기·
# interactive_only·handler 없음)이 TTY 판정보다 먼저다. $1=tty(1|0),
# 생략하면 이 셸의 stdin 을 본다. 0=통과(또는 --renew 없음) / 2=거부.
renew_gate() {
  [ -n "${RENEW:-}" ] || return 0
  local tty="${1:-}"
  if [ -z "$tty" ]; then
    tty=1
    { [ "${NONINT:-0}" = 1 ] || [ ! -t 0 ]; } && tty=0
  fi
  local flag=""
  [ "$tty" = 1 ] || flag="--nontty"
  PYTHONPATH="$REWORKER_ROOT/scripts" python3 \
    "$REWORKER_ROOT/scripts/core/cred_intake.py" renew-check "$RENEW" $flag >&2 \
    || return 2
  return 0
}

# ── 1-5 허브 git-crypt unlock 원시(TASK-583, 편입 결함 소발주 3) ─────────
# 왜 함수인가: 시험(tests_reworker 583 절)이 **같은 본문**을 라이브러리
# 모드로 부른다(CR-0010 — 모의판을 따로 베끼면 그 차이가 곧 다음 결함이다).
#
# 실측(vast2 2026-10-18 15:1x): vault 가 ~/.secrets/gitcrypt.key 를 복원했는데도
# unlock 이 조용히 실패해 unlock 의존 잔여 9건이 남았다. 원인 고리 셋 —
#  ⓐ `.worker_name` 이 추적 파일(커밋값 vast1)이라 bootstrap 이 vast2 를 쓰는
#     순간 트리가 더러워졌다(→ 색인 제거 + .gitignore, 이 커밋).
#  ⓑ `git-crypt unlock` 은 **추적 파일** 변경이 하나라도 있으면 "Working
#     directory not clean" 으로 거부한다(미추적은 무관). 빈 기계 첫 편입(자급
#     갈래)에서 bootstrap 이 방금 손댄 추적 파일이 그 변경일 수 있어 **자급
#     갈래에서만** stash → unlock → stash pop 으로 감싼다. 저장소 안 재실행은
#     코더 WIP 가 있을 수 있어 종전 그대로다(발주 예견 ②, CR-0024).
#  ⓒ 종전 `2>/dev/null` 이 그 사유를 숨겨 "저장소 키 확보 후 재실행" 으로
#     오진됐다 — 사유를 bad 문면에 그대로 싣는다(CR-0016 · CR-0006).
# 잠김→해제 **전이**가 나면 RW_UNLOCK_TRANSITION=1 — 호출부가 ① 절 unlock 의존
# 걸음의 재진입(1회)을 결정한다(범위 1). 반환 0=평문 · 1=잠김 잔존.
#
# **stash 실패 갈래(TASK-663 ⓑ, 실측 2026-10-23 05:1x vast2)**: 자급 갈래의
# `git stash push` 가 실패하면 종전에는 사유 0 으로 「그대로 시도」해 git-crypt 가
# Working directory not clean 으로 거부했고, runtime 암호문이 남아 ImportError 7·
# 로컬 LLM·yac-state 등 잔여 9건이 한 원인으로 섰다. 자급 갈래의 트리는 **이
# 실행의 부트스트랩이 방금 만든 clone** 이라 추적 변경에 사람 산출이 없다 —
# 그래서 stash 가 실패하면 stash 의 사유와 `git status --short` 상위 줄을 요약에
# 싣고(CR-0006·CR-0016) `git checkout -- .` 로 추적 변경을 되돌린 뒤 unlock 한다.
# 되돌린 파일 목록은 fix 문면에 남는다(CR-0008 — 지운 것이 무엇인지 말한다).
# 저장소 안 재실행(비자급)은 종전 그대로 손대지 않는다(코더 WIP 보존).
rw_vault_unlock() {  # $1=저장소 키 경로(기본 ~/.secrets/gitcrypt.key) · cwd=저장소 루트
  local key="${1:-$HOME/.secrets/gitcrypt.key}" err rc=0 stashed=0 reverted="" why serr status5
  RW_UNLOCK_TRANSITION=0
  if ! head -c 9 docs/PROTOCOL.md 2>/dev/null | grep -q GITCRYPT; then
    ok "보호 문서 평문(git-crypt 해제됨)"
    return 0
  fi
  if [ ! -s "$key" ]; then
    bad "unlock 실패: 저장소 키 없음($key) — vault 복원이 키를 놓지 못했다(위 1-5 vault 줄 참조)"
    return 1
  fi
  if [ "${YAC_REWORKER_SELFBOOT:-0}" = 1 ] \
     && [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    if serr="$(git stash push -q -m "reworker-583-unlock" 2>&1 >/dev/null)"; then
      stashed=1
    else
      serr="$(printf '%s' "$serr" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')"
      [ -n "$serr" ] || serr="사유 출력 없음"
      status5="$(git status --short --untracked-files=no 2>/dev/null | head -5 | tr '\n' ';' | sed 's/;$//')"
      say "자급 갈래: 추적 변경 stash 실패($serr) — 더러운 추적 파일(상위 5): ${status5:-없음}"
      reverted="$(git status --porcelain --untracked-files=no 2>/dev/null | awk '{print $NF}' | tr '\n' ' ' | sed 's/ $//')"
      if git checkout -q -- . 2>/dev/null \
         && [ -z "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        say "자급 갈래: 부트스트랩이 만든 트리라 추적 변경을 되돌림(git checkout -- .): $reverted"
      else
        say "자급 갈래: 추적 변경 되돌림 실패 — unlock 은 그대로 시도(사유는 아래 줄)"
        reverted=""
      fi
    fi
  fi
  err="$(git-crypt unlock "$key" 2>&1 >/dev/null)" || rc=$?
  if [ "$stashed" = 1 ]; then
    git stash pop -q >/dev/null 2>&1 \
      || say "자급 갈래: stash pop 실패 — 'git stash list' 로 확인(값은 보관돼 있다)"
  fi
  if [ "$rc" = 0 ]; then
    if [ "$stashed" = 1 ]; then
      fix "보호 문서 git-crypt 해제(자급 갈래: 추적 변경 stash → unlock → pop)"
    elif [ -n "$reverted" ]; then
      fix "보호 문서 git-crypt 해제(자급 갈래: stash 실패 → 추적 변경 되돌림 → unlock · 되돌린 파일: $reverted)"
    else
      fix "보호 문서 git-crypt 해제"
    fi
    RW_UNLOCK_TRANSITION=1
    return 0
  fi
  why="$(printf '%s' "$err" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')"
  [ -n "$why" ] || why="rc=$rc(사유 출력 없음)"
  status5="$(git status --short --untracked-files=no 2>/dev/null | head -5 | tr '\n' ';' | sed 's/;$//')"
  bad "unlock 실패: $why — 추적 변경이 사유면 'git status --short' 로 치운 뒤 재실행(상위 5: ${status5:-없음}), 키가 사유면 ~/.secrets/gitcrypt.key 를 확인"
  return 1
}

# `.worker_name` 은 색인 밖(.gitignore, TASK-583)이라 색인 제거 커밋을 당긴
# 기존 clone(값이 커밋값과 같던 자리)에서는 pull 이 그 파일을 지운다 — 없으면
# 되쓴다(발주 예견 ①). 값은 기계 이름(TASK-341: 보조 인스턴스도 같다). 있는
# 파일은 손대지 않는다(1-6 bootstrap·inst_share_ledgers 가 종전대로 맞춘다).
rw_identity_ensure() {
  local root="${ROOT:-$REWORKER_ROOT}"
  [ -n "${WORKER:-}" ] || return 0
  [ -s "$root/.worker_name" ] && return 0
  printf '%s\n' "${YAC_MACHINE:-$WORKER}" > "$root/.worker_name" \
    && fix ".worker_name 되씀(← ${YAC_MACHINE:-$WORKER}; 색인 밖 파일이라 pull 이 지웠다)"
}

# 색인 제거 전이의 뒤처리(TASK-583 실측): 로컬 값이 커밋값과 다른 clone 이 그
# 커밋을 `pull --autostash` 로 당기면 rc 0 인데도 미병합 `DU .worker_name` 과
# `autostash` 항목이 남아 다음 pull --rebase·git-crypt unlock 이 전부 막힌다.
# 판정·수행은 코어 원시 하나(`worktree_sync.repair_identity`, 인스턴스 sync 와
# 같은 것)이고 여기는 문면만 — repaired 는 fix, 그 밖은 [WARN] 한 줄(CR-0006).
rw_identity_repair() {  # $1=자리 표지(pull 앞|pull 뒤)
  local out
  out="$(python3 "$REWORKER_ROOT/scripts/core/worktree_sync.py" identity-repair "${ROOT:-$REWORKER_ROOT}" 2>&1)"
  case "$out" in
    *" — repaired: "*)   fix ".worker_name 색인 제거 전이 뒤처리($1): ${out##* — repaired: }" ;;
    *" — clean: "*)      : ;;
    *)                   say "[WARN] .worker_name 전이 뒤처리($1) 미완 — ${out##* — }" ;;
  esac
}

# 라이브러리 모드는 여기서 끝 — 아래 본 실행은 건드리지 않는다.
if [ "${YAC_REWORKER_LIB:-0}" = 1 ] || [ "${YAC_RESTORE_LIB:-0}" = 1 ]; then
  return 0
fi

# ── 본 실행 ──────────────────────────────────────────────────────────
# 저장소 밖이면 자급 절이 clone·bootstrap 뒤 clone 안의 자기를 exec 한다 —
# 돌아오지 않는다(TASK-549). 저장소 안이면 판정 하나(무출력)뿐이고 아래는 종전 그대로다.
if rw_outside_repo; then rw_self_bootstrap "$@"; fi
parse_args "$@" || exit 1

cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"

# `--renew` 는 어떤 절보다 먼저 판정한다(TASK-233) — 거부면 아무 것도
# 돌지 않은 채 사유 한 줄 + rc 2.
renew_gate || exit 2

# 중단 처리는 **첫 절보다 먼저** 선다(TASK-116f 범위 0) — 뒤에 달면 그
# 앞에서 끊긴 실행이 종전대로 좀비·침묵을 남긴다.
rw_install_traps

# 생존 판정 단일 원천(TASK-107 3) — ③④ 가 obsv_boot·rc_boot 과 같은
# 함수로 답한다.
LIVENESS_ROOT="$ROOT"
# shellcheck disable=SC1091
. "$ROOT/scripts/core/liveness.sh"

# 러너 등록·생존의 열쇠는 **인스턴스 이름**이다 — 보조 인스턴스의
# `.worker_name` 은 워커(원장) 이름이라 기계 이름과 같다(TASK-341).
[ -n "$WORKER" ] || WORKER="${YAC_INSTANCE_NAME:-}"
[ -n "$WORKER" ] || WORKER="$(cat "$ROOT/.worker_name" 2>/dev/null || true)"
[ -n "$ACCOUNT" ] || ACCOUNT="$(default_account)"

IN_JOB=0
in_job && IN_JOB=1

OK=(); FIX=(); BAD=(); NEED=()
say()  { echo "[reworker] $*"; }
# 절 표지는 화면에만 찍는 것이 아니라 **중단 문면의 본문**이기도 하다
# (TASK-116f 범위 0) — 어디까지 했는지를 두 자리에 적으면 한쪽이 낡는다.
step() { rw_phase "$*"; echo; echo "━━ $* ━━"; }
ok()   { OK+=("$1"); }
fix()  { FIX+=("$1"); say "복구: $1"; }
bad()  { BAD+=("$1"); }
# "무엇을 어디에 넣어라" 한 줄. 값은 절대 적지 않는다(비밀 규칙).
need() { NEED+=("$1"); say "입력 필요 — $1"; }

# 색인 밖 `.worker_name` 이 없으면 되쓴다(TASK-583 예견 ①; 함수 주석 참조).
# 1-3 pull 뒤에도 한 번 더 — 그 pull 이 지운 자리를 같은 실행 안에서 메운다.
rw_identity_ensure

# root 사용 가능 여부: 직접 root 이거나 무암호 sudo 가 실제로 통할 때만
# 참으로 본다. `command -v sudo` 만 보면 sudoers 미등재 계정(vast1 의 aa,
# 2026-08-29 실측)에서 매 sudo 호출이 암호 프롬프트로 빠져 비대화 실행이
# 그 자리에서 막힌다.
SUDO=""
ROOTOK=0
if [ "$(id -u)" = 0 ]; then
  ROOTOK=1
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  SUDO="sudo -n"
  ROOTOK=1
fi

# 부팅 1회성 판정(--once-per-boot). 스탬프는 커널 boot_id — 재부팅하면
# 값이 바뀌므로 디스크가 살아남아도 오판하지 않는다. 위치는 휘발 구역
# (YAC_TMP/live, CLAUDE.md 12 — 상주 상태라 scratch 청소 대상 밖).
BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
BOOT_STAMP="$LV_LIVE_DIR/restore_boot_id"
mkdir -p "$LV_LIVE_DIR" 2>/dev/null || true
if [ "$ONCE_PER_BOOT" = 1 ] && [ "$BOOT_ID" != unknown ] \
   && [ "$(cat "$BOOT_STAMP" 2>/dev/null || true)" = "$BOOT_ID" ]; then
  exit 0
fi
# ⓪ 절만 도는 증설 호출(--fill-expected, TASK-333)은 부팅 1회 스탬프를 찍지 않는다 —
# 리스너가 부팅 훅보다 먼저 부르면 그 훅의 5절 부활이 "이미 돌았다"로 건너뛰어진다.
[ "$FILL_EXPECTED" = 1 ] || printf '%s\n' "$BOOT_ID" > "$BOOT_STAMP" 2>/dev/null || true

if [ "$IN_JOB" = 1 ]; then
  say "잡(GITHUB_ACTIONS/RUNNER_*) 안 — 러너·게이트웨이·알씨 세션의 재기동은 건너뛰고 판정만 한다(자기 살해 방지, TASK-097·TASK-107)"
elif [ -t 1 ]; then
  # 중단 계약을 **쓰기 전에** 알린다(TASK-116f 범위 0) — Ctrl+Z 가 막혀
  # 있다는 사실을 눌러 본 뒤에 알게 하면 그것이 무소음이다(CR-0006).
  say "중단은 Ctrl+C 로(정리하고 어디까지 했는지 남긴다). Ctrl+Z 정지는 막혀 있다 — 멈춘 실행은 좀비와 반쯤 한 상태를 남긴다. 재실행은 멱등이다"
fi

# 사망 뒤 부팅 재개(TASK-685 범위 5) — 부팅 훅이면 ② 상주 재기동(load_guard 루프가 새 표본을 쓰기) **앞에서**
# 앞 부팅의 마지막 load_guard 표본·열린 task 계약으로 비정상 종료를 판정하고, 사망이면 원인 분류·처방 발주·
# 끊긴 런 재발사 갈래까지 같은 순환을 연다. 부팅당 1회(표지 파일 — 루프의 첫 표본이 먼저 돌았어도 무동작).
if [ "$ONCE_PER_BOOT" = 1 ] && [ "$IN_JOB" != 1 ] && [ -f scripts/core/load_guard.py ]; then
  LG_BOOT="$(PYTHONPATH=scripts timeout 300 python3 scripts/core/load_guard.py boot-check 2>&1 | tail -1)"
  say "load_guard 부팅 판정: ${LG_BOOT:-산출 0}"
fi

# ═══ ⓪ 인스턴스 원시(TASK-136) ═════════════════════════════════════
#
# 한 기계 안에 워커 인스턴스를 여럿 두기 위한 세 모드. **유일 진입은
# 그대로 reworker 다**(TASK-107) — 새 스크립트를 만들지 않고 이 파일의
# 모드로 얹는다(CR-0015 한 통로).
#
#   --add-worker <이름> --class gpu|cpu|control [--host]
#   --remove-worker <이름>
#   --instance <이름>            그 인스턴스의 clone 에서 5절을 돌린다
#
# 인스턴스 = `$YAC_ROOT/<이름>/` 하나로, 그 밑에 clone·actions-runner/·
# yac-tmp/·obsv/ 가 선다. 신원(이름·부류·host 여부·기계 이름)은 인스턴스
# 루트의 untracked `$YAC_HOME/.yac_instance` 가 갖는다 — `config/instance`
# 는 커밋돼 인스턴스끼리 공유되므로 거기 둘 수 없다.

# 러너 배포본 주소(같은 기계에 이미 받아 둔 것이 없을 때만 쓴다).
RUNNER_TARBALL_URL="${YAC_RUNNER_TARBALL_URL:-https://github.com/actions/runner/releases/download/v2.336.0/actions-runner-linux-x64-2.336.0.tar.gz}"

# **다른 인스턴스로 들어가는 모든 실행 앞에 이것을 붙인다.**
# `scripts/core/instance.sh` 의 결정 순위는 `환경변수 > 선언 > 파생`이라,
# 이 인스턴스가 export 해 둔 경로 변수가 그대로 따라 들어가면 새
# 인스턴스가 **남의 yac-tmp·남의 러너 자리**를 물어 버린다(2026-09-05
# 실측: 새 인스턴스의 runner_loop 이 host 의 `runner_loop.lock` 을 보고
# "이미 실행 중"으로 조용히 종료했다 — 무소음 고장 그 자체다). 자기
# 위치에서 파생하게 하려면 물려주지 말아야 한다.
# 이름 목록의 단일 원천은 위 라이브러리 함수다(시험이 그것을 그대로 잰다).
INST_ENV_CLEAR=(env)
while IFS= read -r _iv; do
  [ -n "$_iv" ] && INST_ENV_CLEAR+=(-u "$_iv")
done <<INST_ENV_EOF
$(inst_env_clear_names)
INST_ENV_EOF
unset _iv

# 이 기계의 허브 소유자/저장소.
inst_owner_repo() {
  git -C "$ROOT" remote get-url origin 2>/dev/null \
    | sed -E 's#.*github\.com[:/]##; s#\.git$##'
}

# 러너 등록·해제 API 자격(dpipe). 값은 stdout 으로만 흐르고 어디에도
# 기록하지 않는다(PROTOCOL 4-1). 1-8 절이 쓰던 3순위 탐색과 같은 규칙이다.
inst_hub_token() {
  local tk="${GITHUB_TOKEN:-}"
  [ -z "$tk" ] && [ -f "$HOME/.git-credentials-token" ] && tk="$(cat "$HOME/.git-credentials-token")"
  [ -z "$tk" ] && [ -f "$HOME/.git-credentials" ] \
    && tk="$(head -1 "$HOME/.git-credentials" | sed -E 's#.*:([^:@]+)@github\.com.*#\1#')"
  printf '%s' "$tk"
}

# 그 인스턴스가 임대를 보유 중인가(제거 거부 판정). holder 는 `<이름>`
# 또는 병렬 실행기의 하위 신원 `<이름>/<n>`(16-8) 둘 다 본다.
inst_holds_lease() {  # $1=이름 - 보유 중이면 목록을 stdout 에, rc=0
  PYTHONPATH="$ROOT/scripts" python3 -c "
import os, sys, datetime
name = sys.argv[1]
root = sys.argv[2]
found = []
for base in ('bus/claims', 'locks'):
    for dirpath, _dirs, files in os.walk(os.path.join(root, base)):
        for f in files:
            p = os.path.join(dirpath, f)
            try:
                txt = open(p, encoding='utf-8', errors='replace').read()
            except OSError:
                continue
            holder = expires = ''
            for line in txt.splitlines():
                if line.startswith('holder='):
                    holder = line.split('=', 1)[1].strip()
                elif line.startswith('expires='):
                    expires = line.split('=', 1)[1].strip()
            if holder != name and not holder.startswith(name + '/'):
                continue
            live = True
            try:
                live = datetime.datetime.strptime(
                    expires, '%Y-%m-%dT%H:%M:%SZ') > datetime.datetime.utcnow()
            except Exception:
                pass
            if live:
                found.append(os.path.relpath(p, root))
print(' '.join(sorted(found)))
sys.exit(0 if found else 1)
" "$1" "$ROOT" 2>/dev/null
}

# 한 인스턴스의 러너 루프가 **그 자리에서** 돌고 있는가. 판정 축은
# 이름이 아니라 경로다(TASK-136 8) — 상대경로로 띄운 루프는 인스턴스마다
# 명령줄이 글자 그대로 같아서, 이름으로 가리려 하면 남의 루프를 자기
# 것으로 센다(2026-09-05 실측의 교차 false-alive).
inst_loop_alive() {  # $1=clone $2=러너 디렉터리
  [ -n "$(lv_pids_scoped "runner_loo[p]\.sh" "$1" "$2")" ]
}

# 그 인스턴스의 러너 루프를 띄운다. **잡 밖에서만 부른다** — 잡 안에서
# 띄운 상주물은 잡의 사후 정리를 넘기지 못한다(TASK-136 9). 판정·기동
# 대상은 인자로 받은 자리 하나뿐이라 다른 인스턴스를 건드리지 않는다.
# 그 인스턴스의 작업트리를 origin/main 에 맞춘다(TASK-141 범위 3).
#
# **왜 기동 앞인가.** 인스턴스 트리는 잡 체크아웃이 아니면 아무도 갱신하지
# 않는다 — `reworker` 는 host 트리만 봤다. RUN-0007 ④ 실측: `vast1-c1` 의
# 트리가 전날 17:49(pre-138b) 상태라 옛 `graph_worker` 로 뛰었고, 그 산출은
# 틀렸는데도 성공처럼 보였다(사람이 SIGTERM·수동 pull 로 구제). 낡은 코드로
# 도는 것이 멈추는 것보다 나쁘므로, 맞추지 못하면 **기동하지 않고 사유를
# 낸다**(CR-0006). 판정·수행은 코어 원시 하나가 한다(두 벌 금지, CR-0010).
#
# **도구는 자기 저장소에서, 대상 트리는 인자로만**(TASK-136b, PLN-0427).
# 종전은 `$clone/scripts/core/worktree_sync.py` — 대상 트리 **자신의**
# 도구를 불렀다. 그러면 도구가 생기기 전(TASK-141 이전) 커밋에 멈춘 트리는
# 도구가 없어 "동기화 실패" → 기동 거부 → 아무도 갱신 안 함 → 영영 낡는
# 자기 순환에 갇힌다(JL-2026-09-0388 실측: vast1-c1 이 51778be 에서 09-12
# 부터 09-15 까지 그대로, 같은 자리 c2 는 726커밋 반영). 이 함수를 부르는
# 쪽(host 부활 주기)은 언제나 최신 트리이므로 도구는 여기(`REWORKER_ROOT`)
# 것을 쓰고 `$clone` 은 인자다 — worktree_sync.py 는 무변경(대상 repo
# 인자·autostash 는 처음부터 있었다, CR-0010 원시 한 벌).
#: 이번 실행에서 이미 맞춘 clone 들(한 바퀴에 fetch 를 두 번 하지 않는다).
INST_TREE_SYNCED=""

inst_tree_sync() {  # $1=이름 $2=clone → 0=최신(또는 맞춤) 1=실패
  local name="$1" clone="$2" out
  case " $INST_TREE_SYNCED " in *" $clone "*) return 0 ;; esac
  if [ ! -d "$clone/.git" ]; then
    say "[WARN] '$name' clone 이 git 저장소가 아님($clone) — 동기화 건너뜀"
    return 1
  fi
  if out="$("${INST_ENV_CLEAR[@]}" python3 "$REWORKER_ROOT/scripts/core/worktree_sync.py" \
             sync "$clone" 2>&1)"; then
    say "'$name' 작업트리 — ${out##*— }"
    INST_TREE_SYNCED="$INST_TREE_SYNCED $clone"
    return 0
  fi
  say "[WARN] '$name' 작업트리 낙후 — 동기화 실패: ${out##*— }"
  return 1
}

# 원장 공유(TASK-341 범위 0) — 인스턴스 clone 의 `state/`·`nav/` 를 호스트
# clone 으로 잇고(`config/jobtree.yml share_paths`, data 처럼 이미 다른 곳을
# 가리키는 링크는 그대로), `.worker_name` 을 워커 이름(기계 이름)으로 맞춘다.
# 한 워커 이름 = 원장 한 벌: 따로 자란 실물은 행을 호스트로 이관하고 원본은
# 보존한다(삭제 0). 판정·이관은 코어 원시 `jobtree.share_into` 하나이고
# 여기는 순서만 갖는다. 멱등 — 이미 이어진 자리는 `linked` 한 줄로 끝난다.
inst_share_ledgers() {  # $1=clone → 0=공유됨 1=실패
  # 원장 정본 자리 = 이 reworker 의 저장소(host 가 돌린다). YAC_LEDGER_HOST 는
  # 시험 이음매(샌드박스 인스턴스가 실 원장을 잇지 않게, 4-2).
  local clone="$1" host="${YAC_LEDGER_HOST:-$REWORKER_ROOT}" want out rc=0
  want="${YAC_MACHINE:-$WORKER}"
  if [ -n "$want" ] && [ "$(cat "$clone/.worker_name" 2>/dev/null)" != "$want" ]; then
    printf '%s\n' "$want" > "$clone/.worker_name" \
      && say "워커 이름 통일($clone/.worker_name → $want)"
  fi
  out="$("${INST_ENV_CLEAR[@]}" python3 "$REWORKER_ROOT/scripts/core/jobtree.py" share "$clone" \
           --host "$host" --worker "$want" 2>&1)" || rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" | while IFS= read -r ln; do say "$ln"; done
  [ "$rc" -eq 0 ] || say "[WARN] 원장 공유 실패($clone, rc=$rc) — 호스트 기구가 이 인스턴스의 잡을 못 본다"
  return "$rc"
}

inst_loop_start() {  # $1=이름 $2=clone $3=러너 디렉터리
  local name="$1" clone="$2" rd="$3"
  if [ ! -x "$rd/run.sh" ]; then
    say "'$name' 러너 배포본 없음($rd/run.sh) — 루프 기동 대상 아님"
    return 1
  fi
  # 트리를 먼저 맞춘다 — 실패면 기동 거부(위 `inst_tree_sync` 주석).
  # 이미 가동 중인 루프 판정보다 **앞**이다: 살아 있는 루프가 낡은 트리를
  # 물고 있는 것이 정확히 RUN-0007 ④ 의 상태였고, 그것을 "이미 가동"으로
  # 통과시키면 낙후가 영원히 안 보인다.
  inst_tree_sync "$name" "$clone" || return 1
  inst_share_ledgers "$clone" || return 1
  if inst_loop_alive "$clone" "$rd"; then
    say "'$name' 러너 루프 이미 가동"
    return 0
  fi
  # 절대경로로 띄운다 — 뒤이은 범위 판정이 명령줄 축으로도 갈리게 한다.
  "${INST_ENV_CLEAR[@]}" setsid nohup \
    bash "$clone/scripts/runner_loop.sh" >/dev/null 2>&1 &
  sleep 3
  if inst_loop_alive "$clone" "$rd"; then
    say "'$name' 러너 루프 기동"
    return 0
  fi
  say "[WARN] '$name' 러너 루프 기동 확인 실패 — $(dirname "$rd")/yac-tmp/live/runner.log 확인"
  return 1
}

inst_add() {  # $1=이름
  local name="$1" cls="${INST_CLASS:-}" dir clone repo_name token owner_repo
  local reg api old_id old_status rd

  valid_instance_name "$name" || { echo "인스턴스 이름 서식 위반: '$name'(영숫자·_-, 첫 글자는 영숫자)" >&2; return 2; }
  [ -n "$cls" ] || { echo "--class 가 필요합니다(gpu|cpu|control)" >&2; return 2; }
  inst_class_ok "$cls" || { echo "미등재 부류: '$cls' — config/instances.yml runner_classes 참조" >&2; return 2; }
  if [ "$name" = "${YAC_INSTANCE_NAME:-}" ]; then
    echo "'$name' 은 지금 실행 중인 인스턴스다 — 자기 자신은 추가 대상이 아니다" >&2; return 2
  fi

  repo_name="$(basename "$ROOT")"
  dir="$YAC_ROOT/$name"
  clone="$dir/$repo_name"
  rd="$dir/actions-runner"

  mkdir -p "$dir" || { echo "인스턴스 디렉터리 생성 실패: $dir" >&2; return 1; }

  # ⓐ clone — 통로는 코어 원시 하나다(15-16 보강): 신규는 임베드 자격을
  # 뗀 URL 로, 재사용 갈래에도 git-crypt unlock 보증과 원격 자격 정정을
  # 무조건 적용한다(PROTOCOL 4-2).
  [ -d "$clone/.git" ] && say "인스턴스 clone 이미 있음 — 재사용($clone)"
  if ! PYTHONPATH="$ROOT/scripts" python3 -c "
import sys
from core import hub_push
sys.exit(0 if hub_push.ensure_clone(sys.argv[1], sys.argv[2]) else 1)
" "$clone" "$ROOT"; then
    echo "clone 실패: $clone (허브 자격·네트워크 확인)" >&2; return 1
  fi

  # ⓑ 신원. `.worker_name` 은 clone 안(기존 규약)이고 **워커 이름**(=
  # 기계 이름)이다 — 원장 칸 `state/{워커}` 의 열쇠라 같은 기계의 잡·
  # 프레임이 한 이름을 써야 원장이 한 벌이다(TASK-341). 인스턴스 이름
  # (러너 등록·생존 판정의 열쇠)은 인스턴스 루트의 untracked 사전이 갖는다.
  printf '%s\n' "${YAC_MACHINE:-$WORKER}" > "$clone/.worker_name"
  {
    echo "# 워커 인스턴스 신원 (TASK-136). 커밋 대상 아님 — 인스턴스마다 다르다."
    echo "NAME=$name"
    echo "CLASS=$cls"
    echo "HOST=$INST_HOST"
    echo "MACHINE=${YAC_MACHINE:-$WORKER}"
  } > "$dir/.yac_instance"
  chmod 600 "$dir/.yac_instance"

  # ⓒ 기계 공유 데이터. `data/` 는 저장소 루트 상대라 clone 마다 따로
  # 생긴다 — YAC_DATA 가 이 clone 밖을 가리키면 심링크 하나로 잇는다
  # (코드 경로는 종전 그대로 두고 파일시스템에서 푼다, CR-0005).
  case "$YAC_DATA" in
    "$clone"/*|"$clone") : ;;
    *)
      if [ ! -e "$clone/data" ]; then
        mkdir -p "$YAC_DATA" 2>/dev/null || true
        ln -s "$YAC_DATA" "$clone/data" 2>/dev/null \
          && say "데이터 공유 연결($clone/data → $YAC_DATA)"
      fi ;;
  esac
  inst_share_ledgers "$clone" || return 1

  # ⓓ 러너. control 부류는 러너가 없다(사전 판정 — 코드 분기 아님).
  if ! inst_class_has_runner "$cls"; then
    say "부류 '$cls' — 러너 없음(관제 거처)"
  elif [ -f "$rd/.runner" ]; then
    say "러너 이미 등록됨 — 건너뜀($rd)"
  else
    token="$(inst_hub_token)"
    owner_repo="$(inst_owner_repo)"
    if [ -z "$token" ] || [ -z "$owner_repo" ]; then
      echo "러너 등록 자격 없음(dpipe 토큰·origin 원격 확인)" >&2; return 1
    fi
    api="https://api.github.com/repos/$owner_repo/actions/runners"
    read -r old_id old_status <<EOF_RUNNER
$(curl -s -H "Authorization: Bearer $token" "$api" | python3 -c "
import sys, json
rs = json.load(sys.stdin).get('runners', [])
m = [r for r in rs if r['name'] == '$name']
print((str(m[0]['id']) + ' ' + m[0]['status']) if m else '- -')" 2>/dev/null || echo '- -')
EOF_RUNNER
    if [ "$old_id" != "-" ] && [ "$old_status" = "online" ]; then
      echo "같은 이름($name) 러너가 이미 온라인 — 워커 이름 유일성 규약(13-2). 등록 중단" >&2
      return 1
    fi
    [ "$old_id" != "-" ] && curl -s -X DELETE -H "Authorization: Bearer $token" "$api/$old_id" >/dev/null
    reg="$(curl -s -X POST -H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json" \
      "$api/registration-token" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null || true)"
    if [ -z "$reg" ]; then
      echo "러너 등록 토큰 발급 실패 — dpipe 토큰의 Administration 권한 확인" >&2
      unset token; return 1
    fi
    mkdir -p "$rd"
    ( cd "$rd" || exit 1
      if [ ! -x ./config.sh ]; then
        # 같은 기계의 다른 인스턴스에 이미 받아 둔 배포본이 있으면
        # 복사한다(같은 기계·같은 아키텍처라 재다운로드는 낭비다).
        #
        # 제외 두 갈래 — ⓐ **점 파일 전부**(`./.*`): `.runner`·
        # `.credentials`·`.runner_migrated`·`.env`·`.path` 는 전 인스턴스의
        # **등록 상태**라 딸려 오면 `config.sh` 가 "already configured" 로
        # 거절한다(2026-09-05 실측 — `.runner` 만 빼서는 부족했다).
        # ⓑ 판올림 잔재인 **버전 접미 디렉터리**(`bin.2.*`·`externals.2.*`):
        # 러너 자기 판올림이 남긴 사본이고 `bin`·`externals` 심링크가 그중
        # 현행을 가리킨다 — 둘 다 복사하면 인스턴스마다 1GB 를 헛되이 쓴다.
        #
        # **`-h`(심링크 역참조)가 불변식이다**(2026-09-05 실측). 심링크를
        # 심링크째로 두면 `bin -> /home/aa/actions-runner/bin.2.337.0` 이
        # 되고, 러너는 자기 루트를 **실행 파일의 실경로**에서 파생하므로
        # 새 인스턴스의 `config.sh` 가 host 인스턴스의 `.runner` 를 보고
        # "already configured" 로 거절한다(등록 자체가 불가능해진다).
        if [ -x "$YAC_RUNNER_DIR/config.sh" ]; then
          tar -C "$YAC_RUNNER_DIR" -chf - \
            --exclude='./.*' --exclude=./_work --exclude=./_diag \
            --exclude='./bin.2.*' --exclude='./externals.2.*' . | tar -xf -
        else
          curl -sLo r.tar.gz "$RUNNER_TARBALL_URL"
          tar xzf r.tar.gz
          rm -f r.tar.gz
        fi
      fi
      # 기계 범위 풀 라벨(TASK-622, 사전 pool_label_format) — 풀 라우팅이 이 라벨로 쏘므로
      # 등록 시점에 달아야 그 인스턴스가 후보가 된다(서식이 비면 종전 셋뿐).
      pool_lb="$(python3 "$ROOT/scripts/core/instance.py" pool-label "$cls" 2>/dev/null || true)"
      env $(runner_root_env) ./config.sh --unattended --url "https://github.com/$owner_repo" \
        --token "$reg" --name "$name" --labels "self-hosted,$name,$cls${pool_lb:+,$pool_lb}" --work _work )
    unset reg token
    [ -f "$rd/.runner" ] || { echo "러너 등록 실패($name)" >&2; return 1; }
  fi

  # ⓔ 러너 환경. YAC_HOME 을 러너 `.env` 에 주입해야 잡의 첫 스텝
  # (`cd "${YAC_HOME:-$HOME}/<저장소>"`)이 이 인스턴스의 clone 으로 간다.
  if [ -d "$rd" ]; then
    touch "$rd/.env"
    grep -q "^YAC_HOME=" "$rd/.env" 2>/dev/null \
      || echo "YAC_HOME=$dir" >> "$rd/.env"
    grep -q "^ACTIONS_RUNNER_HOOK_JOB_STARTED=" "$rd/.env" 2>/dev/null \
      || echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=$clone/scripts/runner_job_started.sh" >> "$rd/.env"
  fi

  # ⓕ 러너 루프 기동. 그 인스턴스의 clone 에서 돌므로 instance.sh 가
  # YAC_HOME 을 스스로 파생한다(주입 불요).
  #
  # **잡 안에서는 등록까지다(TASK-136 9, 2026-09-05 실측).** 1차 판은 잡
  # 안에서도 `setsid` 로 띄웠고 "새 세션이라 잡의 정리에 걸리지 않는다"고
  # 적었는데, 실측은 반대였다 — 잡이 끝나자 `vast1-c1`·`c2` 러너가 곧바로
  # offline 이 됐다(리스너 프로세스 0). 러너의 잡 사후 정리는 세션이 아니라
  # 잡이 남긴 프로세스 무리를 거두므로, **잡 안에서 띄운 상주물은 잡보다
  # 오래 살 수 없다**고 보는 것이 옳은 전제다. 그래서 기동은 잡 밖 주체
  # (host 의 부활 주기 = 이 파일 ②절의 비-host 인스턴스 전수)로 넘긴다.
  # 검증도 잡 **종료 후** 러너 API 로 한다 — 잡 안의 online 은 증거가 아니다.
  if [ "$IN_JOB" = 1 ] && [ -d "$rd" ]; then
    say "'$name' 잡 안 — 등록까지만(기동은 잡 밖 host 부활 주기가 한다: bash scripts/reworker.sh)"
  elif [ -d "$rd" ]; then
    inst_loop_start "$name" "$clone" "$rd" || true
  fi

  say "인스턴스 준비 완료: $name (부류 $cls, host=$INST_HOST, $dir)"
  return 0
}

# 러너 config.sh 는 root 에서 RUNNER_ALLOW_RUNASROOT 가 없으면 거부한다(JL-2026-
# 09-1027 ④). 붙이는 것은 EUID 0 일 때만이다 — 대상 계정(aa)으로 도는 정상
# 경로에서는 아무 것도 붙이지 않는다(TASK-234). 출력은 `env` 인자 한 벌.
runner_root_env() { if [ "$(id -u)" = 0 ]; then echo RUNNER_ALLOW_RUNASROOT=1; fi; }

# 러너 등록 해제 API 한 벌 — HTTP 상태 코드를 stdout 에 낸다(inst_remove·
# --retire-runner 공용, TASK-223). 토큰 값은 인자로만 흐르고 기록하지 않는다.
inst_runner_delete() {  # $1=토큰 $2=소유자/저장소 $3=러너 id
  curl -s -o /dev/null -w '%{http_code}' -X DELETE \
    -H "Authorization: Bearer $1" "https://api.github.com/repos/$2/actions/runners/$3"
}

# 이관 retire(TASK-223): 이 기계 러너의 자기 등록(agentId)을 해제한다.
# 204=해제 · 404=이미 없음(신기계가 --replace 로 교체) 둘 다 성공이다.
retire_runner() {
  local rdir="${YAC_RUNNER_DIR:-${YAC_HOME:-$HOME}/actions-runner}" rid token owner_repo code
  rid="$(python3 -c "
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding='utf-8-sig')).get('agentId', ''))
except Exception:
    print('')" "$rdir/.runner" 2>/dev/null)"
  if [ -z "$rid" ]; then
    say "러너 자기 등록 없음($rdir/.runner) — 해제 건너뜀"; return 0
  fi
  token="$(inst_hub_token)"; owner_repo="$(inst_owner_repo)"
  if [ -z "$token" ] || [ -z "$owner_repo" ]; then
    echo "러너 해제 실패 — 허브 자격 없음(retire 는 비밀 파기 전에 이 걸음을 둔다)" >&2; return 1
  fi
  code="$(inst_runner_delete "$token" "$owner_repo" "$rid")"; unset token
  case "$code" in
    2*)  say "러너 자기 등록 해제(id $rid)"; return 0 ;;
    404) say "러너 id $rid 이미 없음(교체됨) — 무동작"; return 0 ;;
    *)   echo "러너 해제 실패(id $rid, HTTP $code)" >&2; return 1 ;;
  esac
}

# 러너 지역 등록의 API 실존 대조(TASK-234 범위 4, JL-2026-09-1027). 동명 이관의
# 신기계가 같은 이름으로 등록하면서 구기계 등록을 지우면 구기계의 지역 `.runner`
# 는 남은 채 API 에는 없다 — 지역 파일만 보는 1-8 은 "자격 보유" 로 지나가고
# 러너는 영영 붙지 않는다(04:38 관제 손 복귀). 판정을 API 실존으로 옮긴다:
# agentId 가 API 목록에 없으면 등록 상태 파일을 stale-<시각>/ 로 **옮기고**(삭제
# 0) 1-8 이 재등록한다. 자격·API 가 없으면 판정하지 않고 지역 파일을 그대로 둔다
# (계측 불가는 stale 판정이 아니다). 반환 0=유효·계측 불가 / 10=stale 로 옮김.
runner_stale_check() {  # $1=러너 디렉터리
  local rdir="$1" rid token owner_repo body verdict stale
  [ -f "$rdir/.runner" ] || return 0
  rid="$(python3 -c "
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding='utf-8-sig')).get('agentId', ''))
except Exception:
    print('')" "$rdir/.runner" 2>/dev/null)"
  token="$(inst_hub_token)"; owner_repo="$(inst_owner_repo)"
  if [ -z "$rid" ] || [ -z "$token" ] || [ -z "$owner_repo" ]; then
    say "러너 API 대조 계측 불가(id·자격·저장소 중 없음) — 지역 등록 유지"; unset token; return 0
  fi
  body="$(curl -s -f -H "Authorization: Bearer $token" \
    "https://api.github.com/repos/$owner_repo/actions/runners?per_page=100")"; unset token
  verdict="$(printf '%s' "$body" | python3 -c "
import json, sys
try:
    rs = json.load(sys.stdin).get('runners')
except Exception:
    rs = None
print('unknown' if rs is None else ('live' if any(str(r.get('id')) == sys.argv[1] for r in rs) else 'stale'))" "$rid" 2>/dev/null)"
  case "$verdict" in
    live)  say "러너 등록 API 실존(id $rid)"; return 0 ;;
    stale)
      stale="$rdir/stale-$(date -u +%Y%m%dT%H%M%SZ)"
      mkdir -p "$stale"
      for f in .runner .credentials .credentials_rsaparams; do
        [ -e "$rdir/$f" ] && mv "$rdir/$f" "$stale/"
      done
      say "러너 지역 등록 stale(id $rid 가 API 에 없음) → $stale 로 옮김 — 1-8 이 재등록"
      return 10 ;;
    *)     say "러너 API 대조 계측 불가(응답 판독 실패) — 지역 등록 유지"; return 0 ;;
  esac
}

inst_remove() {  # $1=이름
  local name="$1" dir clone token owner_repo api rid leases
  valid_instance_name "$name" || { echo "인스턴스 이름 서식 위반: '$name'" >&2; return 2; }
  if [ "$name" = "${YAC_INSTANCE_NAME:-}" ]; then
    echo "'$name' 은 지금 실행 중인 인스턴스다 — 자기 자신은 제거할 수 없다" >&2; return 2
  fi
  dir="$YAC_ROOT/$name"
  clone="$dir/$(basename "$ROOT")"

  # 삭제 대상 경로 가드(CLAUDE.md 규칙 5 의 정신 — 좁게, 확인 가능하게).
  # ① 절대경로 ② `$YAC_ROOT/` 바로 밑 ③ 인스턴스 표식(.yac_instance)이
  # 실제로 있는 디렉터리 ④ 심링크 아님. 넷 중 하나라도 아니면 거부한다.
  case "$dir" in /*) : ;; *) echo "절대경로가 아니다: $dir" >&2; return 2 ;; esac
  case "$dir" in "$YAC_ROOT"/*) : ;; *) echo "YAC_ROOT($YAC_ROOT) 아래가 아니다: $dir" >&2; return 2 ;; esac
  if [ ! -d "$dir" ]; then
    say "인스턴스 '$name' 없음 — 이미 제거됨(멱등)"
  elif [ -L "$dir" ]; then
    echo "심링크는 제거 대상이 아니다: $dir" >&2; return 2
  elif [ ! -f "$dir/.yac_instance" ]; then
    echo "인스턴스 표식(.yac_instance)이 없다 — 이 도구가 만든 디렉터리가 아니므로 지우지 않는다: $dir" >&2
    return 2
  fi

  # 임대 보유 중이면 거부. 지금 무언가를 수행 중인 인스턴스를 지우면
  # 그 임대가 TTL 만료까지 유령으로 남아 다른 인스턴스를 막는다.
  if leases="$(inst_holds_lease "$name")"; then
    echo "'$name' 이 임대 보유 중 — 제거 거부($leases). 해제(bus_claim.py release) 후 재시도" >&2
    return 1
  fi

  # 러너 해제(등록이 있으면). 해제에 실패하면 디렉터리는 그대로 둔다 —
  # 등록이 남은 채 디스크만 지우면 GitHub 이 영원히 offline 러너를 본다.
  token="$(inst_hub_token)"
  owner_repo="$(inst_owner_repo)"
  if [ -n "$token" ] && [ -n "$owner_repo" ]; then
    api="https://api.github.com/repos/$owner_repo/actions/runners"
    rid="$(curl -s -H "Authorization: Bearer $token" "$api" | python3 -c "
import sys, json
rs = json.load(sys.stdin).get('runners', [])
m = [r for r in rs if r['name'] == '$name']
print(m[0]['id'] if m else '')" 2>/dev/null || true)"
    if [ -n "$rid" ]; then
      if inst_runner_delete "$token" "$owner_repo" "$rid" | grep -q '^2'; then
        say "러너 등록 해제($name)"
      else
        unset token
        echo "러너 등록 해제 실패($name) — 디렉터리는 그대로 둔다(등록만 남는 유령 방지)" >&2
        return 1
      fi
    else
      say "러너 등록 없음($name) — 해제 건너뜀"
    fi
  else
    say "[WARN] 허브 자격 없음 — 러너 등록 해제를 확인하지 못했다(디렉터리만 제거)"
  fi
  unset token

  # 루프·리스너 정지 후 디렉터리 제거. **그 인스턴스 자리의 것만**
  # 거둔다(TASK-136 8) — 종전 명령줄 패턴은 상대경로로 띄운 루프를 놓쳐
  # 디렉터리만 사라지고 프로세스가 남는 갈래가 있었다.
  if [ -d "$dir" ]; then
    for _rp in $(lv_pids_scoped "runner_loo[p]\.sh" "$clone" "$dir/actions-runner") \
               $(lv_pids_scoped "[R]unner.Listener" "$clone" "$dir/actions-runner"); do
      kill -TERM "$_rp" 2>/dev/null || true
    done
    unset _rp
    sleep 1
    rm -rf "$dir" || { echo "디렉터리 제거 실패: $dir" >&2; return 1; }
    say "인스턴스 제거 완료: $name ($dir)"
  fi
  return 0
}

if [ -n "$ADD_WORKER" ]; then
  inst_add "$ADD_WORKER"; exit $?
fi
if [ -n "$REMOVE_WORKER" ]; then
  inst_remove "$REMOVE_WORKER"; exit $?
fi
if [ "$RETIRE_RUNNER" = 1 ]; then
  retire_runner; exit $?
fi
if [ "$RUNNER_API_CHECK" = 1 ]; then
  runner_stale_check "${YAC_RUNNER_DIR:-${YAC_HOME:-$HOME}/actions-runner}"
  RC=$?; [ "$RC" = 10 ] && RC=0; exit "$RC"
fi
if [ "$FILL_EXPECTED" = 1 ]; then
  # ⓪ 절 하나(TASK-333) — 아래 본 흐름의 ⓪ 절과 같은 판정·같은 함수다. host 만
  # 세우고 잡 안은 보고만(inst_fill_expected 의 in_job 갈래 그대로).
  if [ "${YAC_INSTANCE_HOST:-1}" != 1 ]; then
    echo "[reworker] --fill-expected: 비-host 인스턴스 — 기대 인스턴스 보충은 host 몫(대상 아님)"
    exit 0
  fi
  inst_fill_expected "${YAC_MACHINE:-$WORKER}" "${YAC_INSTANCE_NAME:-$WORKER}" "$IN_JOB"
  for _l in "${OK[@]}";  do echo "[reworker] 정상: $_l"; done
  for _l in "${BAD[@]}"; do echo "[reworker] 잔여: $_l"; done
  [ "${#BAD[@]}" = 0 ]; exit $?
fi
if [ -n "$INSTANCE" ] && [ "$INSTANCE" != "${YAC_INSTANCE_NAME:-}" ]; then
  # 그 인스턴스의 clone 에서 5절을 그대로 돌린다 — 새 실행 경로를 만들지
  # 않는다(CR-0004). 상주 항목 스킵 판정은 그 clone 의 `.yac_instance`
  # (HOST=0)가 하므로 여기서 넘길 것이 없다.
  INST_CLONE="$YAC_ROOT/$INSTANCE/$(basename "$ROOT")"
  if [ ! -d "$INST_CLONE/.git" ]; then
    echo "인스턴스 '$INSTANCE' 의 clone 이 없다($INST_CLONE) — 먼저 --add-worker" >&2
    exit 2
  fi
  say "인스턴스 '$INSTANCE' 의 clone 에서 재실행($INST_CLONE)"
  INST_ARGS=("$INSTANCE")
  [ "$CONTROL" = 1 ] && INST_ARGS+=(--control-node)
  [ "$NONINT" = 1 ]  && INST_ARGS+=(--non-interactive)
  [ "$DEEP" = 1 ]    && INST_ARGS+=(--deep)
  # 이 모드는 그 인스턴스의 점검이 목적이라 종단 알씨 접속(⑥)은 종전대로
  # 하지 않는다(기존 모드 무변경, TASK-238 제약).
  INST_ARGS+=(--no-attach)
  cd "$INST_CLONE" || exit 1
  exec "${INST_ENV_CLEAR[@]}" bash scripts/reworker.sh "${INST_ARGS[@]}"
fi

# 이 인스턴스가 상주물(관측 창·알씨 세션·크론·서빙)을 담당하는가.
# host 가 아니면 ②의 상주 데몬·③④ 는 대상 자체가 아니다 — 한 기계에서
# 여럿이 같은 게이트웨이·같은 알씨 세션을 두고 다투면 그 순간 둘 다
# 고장이다(13-6 "봇 큐마다 소비자는 한 시점에 정확히 하나"의 확장).
IS_HOST="${YAC_INSTANCE_HOST:-1}"
[ "$IS_HOST" = 1 ] || say "비-host 인스턴스(${YAC_INSTANCE_NAME:-?}) — 상주물(리스너·메일 감시·워치독·체크포인트 루프)·관측·알씨 절은 host 몫으로 건너뛴다"

# ═══ ⓪ 인스턴스 보충(TASK-238) ══════════════════════════════════════
# 이 기계에 있어야 할 인스턴스(사전 `expected_instances`, 기계 이름 키)와
# 실재(`$YAC_ROOT/*/.yac_instance`)의 차이만 `inst_add` 로 세운다 — 종전
# RECOVERY 6-1 의 `--add-worker` 손 단계가 여기로 흡수됐다. host 만 한다
# (인스턴스를 세우는 주체는 기계 유일 상주물 주체와 같다, 13-2 보강).
# 러너 기동은 종전대로 ② 2-2b(host 부활 주기)가 맡으므로 이 절은 등록까지다.
step "⓪ 인스턴스 보충"
if [ "$IS_HOST" != 1 ]; then
  ok "비-host 인스턴스 — 기대 인스턴스 보충은 host 몫(대상 아님)"
elif [ "$NO_RUNNER" = 1 ] || [ "$NO_RESIDENTS" = 1 ]; then
  ok "기대 인스턴스 보충 보류(--no-runner/--no-residents — 이관 m6b 활성화가 인자 없이 다시 돌려 한다)"
else
  inst_fill_expected "${YAC_MACHINE:-$WORKER}" "${YAC_INSTANCE_NAME:-$WORKER}" "$IN_JOB"
fi
# ⓪-능력) 기계 능력 선언 기입(TASK-668) — 사전 `capability_seed_by_machine`(예: vast2
# gpu=2)을 host 인스턴스 사전 `.yac_instance` 의 `CAP_<필드>` 로 멱등 기입한다. 실측
# (`capability_probes`, nvidia-smi)이 다르거나 계측 불가여도 선언값을 쓰고 고지 한 줄을 낸다.
# 선언 없는 기계(vast1)는 무변경이다. 잡 안에서는 기입하지 않는다(인스턴스 사전은 호스트 몫).
if [ "$IS_HOST" = 1 ] && [ "$IN_JOB" != 1 ]; then
  if CAPSEED="$(python3 "$ROOT/scripts/core/instance.py" cap-seed 2>&1)"; then
    case "$CAPSEED" in
      *"기입("*) fix "능력 선언 기입 — $(printf '%s' "$CAPSEED" | tail -n 1)" ;;
      *) ok "능력 선언 — $(printf '%s' "$CAPSEED" | tail -n 1)" ;;
    esac
    case "$CAPSEED" in *"고지"*) printf '%s\n' "$CAPSEED" | grep '고지' | sed 's/^/    /' ;; esac
    # 실측 ≠ 사전 선언(TASK-731) — 원장 행은 cap-seed 가 남기고, 여기는 잔여 한 줄(요약 통보).
    case "$CAPSEED" in
      *"고지 — 어긋남"*) bad "능력 사전·실측 어긋남 — $(printf '%s\n' "$CAPSEED" | grep -m1 '고지 — 어긋남' | sed 's/^.*고지 — //') · config/instances.yml 정정(TASK-731)" ;;
    esac
  else
    bad "능력 선언 기입 실패 — 'python3 scripts/core/instance.py cap-seed' 재실행: $(printf '%s' "$CAPSEED" | tail -n 1)"
  fi
fi

# ═══ ① 환경 점검·보충 ═══════════════════════════════════════════════
step "① 환경 점검·보충"

# ①-지문) 자격 파일 되쓰기 감지의 기준점(TASK-116c ③). `credential.helper`
# 가 `store` 인 것은 정상 운용 경로라 그대로 두되, 실행 **중** 자격 파일이
# 조용히 바뀌는 일(원격 URL 임베드 자격이 되써 넣는 그 현상 — 2026-09-03
# 실측: 심은 지 8분 만에 저절로 원복)을 무소음으로 넘기지 않는다.
# 지문은 표식 파일 안에만 두고 화면·로그에는 절대 내지 않는다(값도 해시도
# 아니고 "바뀌었다/아니다"만 말한다 — 발주 제약).
CRED_STAMP="$LV_LIVE_DIR/gitcred_fp"
cred_stamp_save() {
  PYTHONPATH="$ROOT/scripts" python3 scripts/core/remote_cred.py \
    fingerprint --save "$CRED_STAMP" >/dev/null 2>&1 || true
}
# 우리가 스스로 자격 파일을 쓴 자리(①-0 창구 기입·1-2 GITHUB_TOKEN
# 재기입)에서만 기준을 다시 잡는다 — 그 변화는 예상된 것이라 경보 대상이
# 아니다. **설명되지 않는** 변화만 ⑤-지문에서 [WARN] 로 남는다(①-원격 의
# 원격 URL 정정은 자격 파일을 쓰지 않으므로 재기준 대상이 아니다 — 그
# 구간에 파일이 바뀌었다면 그것이 곧 되쓰기이고, 그때 울려야 맞다.
# 유일한 예외는 그 절의 need 갈래이고, 사유는 그 자리에 적었다).
cred_stamp_save

# ①-원격) 원격 URL 임베드 자격 검출·정정(TASK-116c ①②, 절 순서 시정
# TASK-116d ①, PROTOCOL 4-2).
#
# **이 절은 값 입력(①-0)과 첫 git 통신(1-2)보다 반드시 앞선다** — 불변식은
# `원격 URL 정정 → 값 입력 → 첫 git 통신` 이다. 116c 는 이 절을 1-2 뒤
# (옛 1-2c)에 두었는데, 임베드 URL 이 있는 기계에서는 ①-0 에 심은 정본
# 값이 스물몇 줄 뒤 1-2 의 fetch 한 번에 옛 값으로 되돌아가 **1회차 입력이
# 통째로 버려졌다**(2026-09-03 18:12 실측 — 사람이 순서를 미리 읽고
# "Enter 로 건너뛰고 다시 돌리라"고 우회해 두 번 돌려야 했다). 빈 기계
# 청정 재구축에는 우회해 줄 사람이 없으므로 1회로 수렴해야 한다.
#
# **자격 원천은 파일 하나여야 한다.** 원격 URL 에 자격이 박혀 있으면
# credential.helper=store 가 git 인증 때마다 그 값을 ~/.git-credentials 에
# 되써 넣어, 아래 1-2b 가 "부족"을 정확히 짚고 ①-0 창구가 정본 값을 심어도
# **다음 git 통신 한 번에 옛 값으로 되돌아간다**(2026-09-03 실측 —
# 116·116b 가 증상을 정확히 보여준 뒤 116c 에서 드러난 원천).
#
# 검출되면 자동으로 정정한다(대화형·비대화형 모두). 파괴 행위가 아니라
# 자격 원천을 파일 하나로 되돌리는 복구이고, URL 에서 **자격만** 떼며
# 원격 자체는 유지한다(`git remote set-url` 하나 — 원격을 지우거나
# 재생성하지 않는다). 정정 뒤 fetch 로 인증이 여전히 되는지 확인하고,
# 실패하면 need(값 입력 요구)다 — URL 에 박혀 있던 값이 이 기계의 유일한
# 자격이었던 갈래이고, 자격 파일이 아예 없는 빈 기계에서도 같은 갈래다.
# 그 need 는 **뒤따르는 ①-0 창구를 막지 않는다**(need() 는 목록에 한 줄을
# 쌓을 뿐 흐름을 끊지 않는다 — 값을 넣으면 해소되는 갈래라 그래야 맞다).
# 같은 실행 안에서 need → ①-0 입력 → 1-2 fetch 로 ok 에 수렴하는 것이
# 이 순서의 목적이다(TASK-116d ②).
#
# **검사 범위는 허브 하나가 아니라 이 기계의 모든 로컬 클론이다**
# (TASK-116e ①). 116c·116d 는 cwd(허브)만 봤고, 그래서 $YAC_TMP/scratch/
# 아래 상주 작업 클론 3개(등재 push·관제 임대·게이트 잠금)의 origin URL 에
# 박힌 옛 토큰이 그대로 살아남아 — 허브를 정정하고 정본 값을 심어도 —
# 다음 등재 push 한 번에 자격 파일을 되썼다(2026-09-03 19:00 실측: 새
# 세션 첫 controller.py status 하나로 재현). 대상 목록은 사전
# (config/credentials.yml remote_repos)이 갖고, 사전 밖에서 새로 생긴
# 클론은 lint_all.sh 의 sweep 이 등재 누락 경고로 잡는다.
#
# 보고 문면에는 URL 원문도 토큰 값도 싣지 않는다(저장소 id·원격 이름만 —
# 이번 사고가 정확히 원격 URL 을 출력한 자리에서 났다).
REMOTE_OUT="$(PYTHONPATH="$ROOT/scripts" python3 scripts/core/remote_cred.py fix-all 2>&1)"
REMOTE_LAST="$(printf '%s\n' "$REMOTE_OUT" | tail -1)"
case "$REMOTE_LAST" in
  ok)
    ok "원격 URL 임베드 자격 없음(자격 원천 단일)" ;;
  fix*)
    printf '%s\n' "$REMOTE_OUT"
    fix "원격 URL 임베드 자격 제거 ${REMOTE_LAST#fix} — 자격 원천을 ~/.git-credentials 하나로 되돌림(PROTOCOL 4-2)" ;;
  need*)
    printf '%s\n' "$REMOTE_OUT"
    need "원격 URL 임베드 자격 제거 ${REMOTE_LAST#need} 후 인증 실패 — URL 에 박혀 있던 값이 이 기계의 유일한 자격이었다: 바로 아래 ①-0 창구가 같은 실행 안에서 정본 dpipe 값을 묻는다(비대화·비TTY 면 GITHUB_TOKEN 환경변수로 재실행하거나 대화형 셸에서 'bash scripts/reworker.sh')"
    # 지문 기준 재설정(①-지문, TASK-116d ③). 이 갈래에서만 다시 잡는다 —
    # 인증이 **실패**했다는 것은 store 가 값을 승인·기입하지 않았다는
    # 뜻이고(store 는 성공한 자격만 approve 한다), 대신 git 이 실패한
    # 자격을 reject 로 지워 파일이 바뀌었을 수 있다. 그 변화는 우리
    # 확인이 부른 **설명되는** 변화라 ⑤-지문의 경보 대상이 아니다.
    # ok·fix 갈래는 재기준하지 않는다: 거기서 파일이 바뀌었다면 그것이
    # 곧 설명되지 않는 되쓰기이고, 그때는 울려야 맞다.
    cred_stamp_save ;;
  *)
    printf '%s\n' "$REMOTE_OUT"
    bad "원격 URL 임베드 자격 검출 $REMOTE_LAST — 자동 정정 실패(수동: git remote set-url <원격> https://github.com/<소유자>/<저장소>.git)" ;;
esac

# ── vault 선행(TASK-237, 사용자 지적 2026-09-24 23:42) ──────────────────
# 1-4(의존)·1-5(vault 개봉)는 ①-0 값 입력 창구보다 **앞에** 온다. 빈 기계에서
# 창구가 먼저 돌면 vault 에 이미 봉인된 값(ts_authkey·vast_api_key·
# pc_ssh_pubkey·dpipe 등)까지 전부 missing 으로 판정해 하나하나 묻는다 —
# 암호구 하나로 열릴 것을 사람이 Enter 로 넘겨야 했다. 순서는
# `원격 URL 정정 → 의존 → 암호구·vault 개봉 → 값 입력(vault 에도 없는 것만)
# → 첫 git 통신` 이다. vault 개봉은 클론 안 파일만 읽어 git 통신이 없으므로
# TASK-116d 불변식(정정 → 입력 → 첫 git 통신)을 깨지 않는다. 1-5b(이관 data)
# 는 허브 최신 runs/ 를 읽어야 하므로 1-3 최신화 뒤 제자리에 남는다.
# 1-4) 의존 패키지·cron 데몬·NOPASSWD sudo
rw_phase "① 환경 점검·보충 · 1-4 의존 패키지"
MISS=""
command -v age >/dev/null || MISS="$MISS age"
command -v git-crypt >/dev/null || MISS="$MISS git-crypt"
command -v crontab >/dev/null || MISS="$MISS cron"
if [ -z "$MISS" ]; then
  ok "의존 패키지(age·git-crypt·cron) 설치됨"
elif [ "$ROOTOK" = 1 ]; then
  $SUDO apt-get update -qq
  # shellcheck disable=SC2086
  if $SUDO apt-get install -y -qq $MISS; then fix "의존 패키지 설치:$MISS"; else bad "의존 패키지 설치 실패:$MISS"; fi
else
  need "root 권한 — 미설치 패키지($MISS)는 root 셸에서 'apt-get install -y$MISS'"
fi
# 파이썬 최소 의존(config/py_requirements.txt 단일 원천). 실패해도 복구
# 자체는 계속한다 — 정말 필요한 것은 뒤 절에서 그 자리에 다시 드러난다.
# 호스트 파이썬 의존(시험·분석의 openpyxl 등, TASK-687)도 같은 목록 한 벌이다 —
# import 로 재고 없는 것만 설치(재시도 3회), 못 깐 수는 「미설치 N」 으로 싣는다.
if PY_DEPS_OUT="$(bash "$ROOT/scripts/py_deps_ensure.sh" 2>&1)"; then
  PY_DEPS_NEW="$(printf '%s\n' "$PY_DEPS_OUT" | grep -c '설치됨:')"
  if [ "${PY_DEPS_NEW:-0}" -gt 0 ]; then
    fix "파이썬 의존 ${PY_DEPS_NEW}건 설치(config/py_requirements.txt)"
  else
    ok "파이썬 의존 확보(config/py_requirements.txt)"
  fi
else
  bad "파이썬 의존 일부 미확보 · $(printf '%s\n' "$PY_DEPS_OUT" | grep -o '미설치 [0-9]*' | tail -1) — 'bash scripts/py_deps_ensure.sh' 출력의 실패 줄이 수동 설치 명령을 알려준다(오프라인이면 망 복구 뒤 재실행)"
fi
# 1-4c) 상태 원장 세우기(TASK-687 범위 2) — 사전 계기 신호가 가리키는 원장 중 없는 것만 빈 파일로.
state_ledger_seed "$ROOT"
# 활성 프로젝트 파이썬 의존은 종전 이 자리(1-4)에서 1-5 뒤 1-5a 로 옮겼다
# (TASK-283 독자 전수): `projects/*/config/**` 가 git-crypt 경계에 들어
# 빈 기계의 잠긴 클론에서는 그 목록이 암호문이다 — unlock 뒤에 읽는다.
# 로컬 소형 LLM 실물(TASK-247 범위 1, JL-2026-09-1062 근원 ⓐ) — 이관은 venv·모델
# 영구 자리를 옮기지 않으므로 신기계마다 재발한다. 사전이 로컬 LLM 을 선언한
# 인스턴스(enabled · serve_role_enabled · roles.yml gpu-serve 등재)면 `setup`
# (멱등·이어받기)으로 확인·설치하고, 비대상은 그 사유 한 줄이다. 잡 시한 밖
# 통로라 느린 망에서도 끝까지 간다 — 판정은 core/local_llm_serve.declared 한 벌.
LL_OUT="$(python3 "$ROOT/scripts/core/local_llm.py" setup --if-declared 2>&1)" && LL_RC=0 || LL_RC=$?
LL_LAST="$(printf '%s\n' "$LL_OUT" | tail -n 1)"
if [ "$LL_RC" = 0 ]; then
  ok "로컬 LLM 실물 — ${LL_LAST:-확인}"
else
  bad "로컬 LLM setup 실패(rc $LL_RC) — ${LL_LAST:-사유 없음}; 'python3 scripts/core/local_llm.py setup' 재실행(이어받기)"
fi
# cron 데몬(컨테이너는 부팅 서비스가 없어 설치만으로 안 돈다 — crontab
# 항목이 남아 있어도 데몬이 없으면 전부 무력이다. 부활의 첫 단추).
if [ "$(lv_cron_state)" = 가동 ]; then
  ok "cron 데몬 가동"
elif [ "$ROOTOK" = 1 ]; then
  $SUDO service cron start >/dev/null 2>&1 || $SUDO cron >/dev/null 2>&1 || true
  if [ "$(lv_cron_state)" = 가동 ]; then fix "cron 데몬 기동"; else bad "cron 데몬 기동 실패"; fi
else
  need "root 권한 — cron 데몬 기동(root 셸에서 'service cron start')"
fi
# NOPASSWD sudo 편입: 이것이 있어야 다음 재부팅에서 계정 쪽 복원이
# cron 데몬 기동 같은 root 단계를 스스로 밟는다.
SUDOERS_FILE="/etc/sudoers.d/$ACCOUNT"
if [ "$ACCOUNT" = root ]; then
  :
elif [ -f "$SUDOERS_FILE" ]; then
  ok "NOPASSWD sudo 등재됨"
elif [ "$ROOTOK" = 1 ]; then
  SUDOERS_TMP="$(mktemp)"
  rw_temp_track "$SUDOERS_TMP"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$ACCOUNT" > "$SUDOERS_TMP"
  if visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
    $SUDO install -m 0440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_FILE" \
      && fix "NOPASSWD sudo 편입($SUDOERS_FILE)" \
      || bad "$SUDOERS_FILE 설치 실패"
  else
    bad "sudoers 문법 검사 실패 — 편입 취소(기존 설정 무변경)"
  fi
  rm -f "$SUDOERS_TMP"
else
  need "root 권한 — NOPASSWD sudo 편입(root 셸에서 \"echo '$ACCOUNT ALL=(ALL) NOPASSWD:ALL' > $SUDOERS_FILE && chmod 440 $SUDOERS_FILE\")"
fi

# 1-5) vault 복원(암호구→개인키→개봉) + 보호 문서 잠금 해제
rw_phase "① 환경 점검·보충 · 1-5 vault 복원"
case "$(input_gate "$HOME/.secrets/gitcrypt.key")" in
have)
  ok "저장소 키 보유(~/.secrets/gitcrypt.key)" ;;
human)
  need "암호구 — vault 개봉이 필요하다. 대화형 셸에서 'bash scripts/reworker.sh $WORKER' 를 한 번 돌려 암호구를 입력하라" ;;
*)
  EXPECT="$(grep -o 'age1[a-z0-9]*' config/vault_recipients.txt 2>/dev/null | head -1)"
  if [ -z "$EXPECT" ]; then
    bad "config/vault_recipients.txt 에서 수신자 공개키를 읽지 못함 — vault 복원 건너뜀"
  else
    KEYF="$(mktemp)"
    # 이 파일은 암호구에서 파생한 **개인키**다 — 중단이 여기를 남기면
    # 그것이 곧 평문 비밀 잔류다(PROTOCOL 4-1). 아래 정상 경로의
    # `rm -f` 와 같은 일을 중단 갈래에서도 하도록 등록한다.
    rw_temp_track "$KEYF"
    TRY=1
    while :; do
      OUT="$(python3 scripts/vault_keygen.py --out "$KEYF")"
      PUB="$(printf '%s\n' "$OUT" | grep -o 'age1[a-z0-9]*' | head -1)"
      if [ "$PUB" = "$EXPECT" ]; then
        say "공개키 일치 — 개봉 진행"
        bash scripts/secrets_import.sh -i "$KEYF" && fix "vault 개봉·비밀 복원" || bad "vault 개봉 실패"
        # vault 가 ~/.git-credentials 를 복원했으면 그것은 설명되는 변화다
        # (①-지문 재기준, TASK-237 — 개봉이 창구 앞으로 옮겨 왔으므로).
        cred_stamp_save
        break
      fi
      echo "암호구가 봉인 시점과 다릅니다(파생 공개키가 수신자와 불일치). 다시 입력하세요. ($TRY/5)"
      if [ "$TRY" -ge 5 ]; then
        bad "암호구 5회 불일치 — vault 복원 중단(암호구 확인 필요)"
        break
      fi
      TRY=$((TRY+1))
    done
    # 개인키 파일은 1-5b(이관 data 복호)가 같은 키로 한 번 더 쓰고 거기서
    # 지운다(TASK-223) — 중단 갈래는 위 rw_temp_track 이 그대로 지운다.
    MIG_KEYF="$KEYF"
  fi ;;
esac
# 허브 unlock 본문은 `rw_vault_unlock`(라이브러리 절, TASK-583) — 자급 갈래의
# stash 감싸기·실패 사유 노출이 거기 있다. 잠김이 남으면(반환 1) 이 뒤에 나는
# 잔여는 대개 암호문 설정/모듈을 읽지 못해 생기는 한 원인의 파생이다(TASK-582
# 범위 2 — vast2 첫 완주의 13건 중 9건). 요약에서 그 묶음을 한 줄로 접는다
# (locked_bad_fold). 값은 바꾸지 않는다.
rw_vault_unlock "$HOME/.secrets/gitcrypt.key" || {
  RW_LOCKED=1
  RW_LOCKED_BAD_FROM=${#BAD[@]}
}
# 범위 1(TASK-583): 잠김→해제 **전이**가 났으면 ① 절의 unlock 의존 걸음(①-지문·
# ①-원격 `remote_cred.py`·1-4b local_llm — 전부 1-5 **앞**이라 이 실행에서는 잠긴
# 채 지나갔다, PLN-3997)을 같은 실행 안에서 한 번 더 돌린다. 방식은 **재진입 1회**
# (사전 `config/rebuild.yml` `reworker_unlock_reentry: once|none`) — 걸음을 1-5 뒤로
# 옮기는 길은 ①-지문·①-원격의 「창구 앞」 순서 불변식(TASK-116d·237)과 충돌한다.
# 꼴은 1-3 의 자기 갱신 재실행과 같고, 둘째 패스는 평문이라 전이가 없어 끝난다
# (표지 REWORKER_UNLOCK_REENTRY 가 루프를 막는다). exec 앞에 이 실행이 만든
# 임시 표지(1-5 의 개인키 파일)를 지운다 — exec 는 트랩을 타지 않는다(4-1).
RW_REENTRY="$(sed -n 's/^reworker_unlock_reentry: *\([a-z]*\).*/\1/p' config/rebuild.yml 2>/dev/null)"
if [ "${RW_UNLOCK_TRANSITION:-0}" = 1 ] && [ "${RW_REENTRY:-once}" != none ] \
   && [ -z "${REWORKER_UNLOCK_REENTRY:-}" ]; then
  say "보호 문서 해제됨 — ① 절 unlock 의존 걸음 재진입(1회, 사전 reworker_unlock_reentry=${RW_REENTRY:-once})"
  rw_cleanup_temps
  REWORKER_UNLOCK_REENTRY=1 exec bash scripts/reworker.sh "$@"
fi
# yac-state 저장 암호화 경계 배선(TASK-124). **순서가 불변식이다** —
# vault 복원 → 저장소 키 → 허브 unlock → **여기(yac-state unlock)** →
# checkpoint 재개. 앞 절들 뒤에 두는 이유가 그것이고, 이 절이 빠지면
# checkpoint 가 잠김을 만나 백업을 거부한다(무소음 중단이 아니라 [WARN]).
# 허브와 같은 저장소 키를 쓰므로 새 암호구·새 입력이 생기지 않는다.
# 멱등: 이미 배선·경계가 맞으면 쓰기 0.
STATE_LOCAL_PATH="$YAC_HOME/$(sed -n 's|^STATE_REPO=.*/||p' config/instance | head -1)"
if [ -z "${STATE_LOCAL_PATH#"$YAC_HOME"/}" ] || [ ! -d "$STATE_LOCAL_PATH/.git" ]; then
  ok "yac-state 클론 없음 — 경계 배선 건너뜀(첫 checkpoint 가 clone 한다)"
elif PYTHONPATH=scripts python3 scripts/core/gitcrypt.py setup "$STATE_LOCAL_PATH" --repo yac_state >/dev/null 2>&1; then
  ok "yac-state 저장 암호화 경계 배선·해제됨"
else
  bad "yac-state 경계 배선 실패 — 저장소 키 확보 후 재실행(그때까지 checkpoint 의 인증 백업이 거부된다)"
fi

# 1-5a) 활성 프로젝트 파이썬 의존(TASK-238 범위 4, JL-2026-09-1062 근원 ⓑ) —
# 프레임 목록(1-4) 뒤, 같은 통로(`py_deps_ensure.sh`). 잡 안이면 확인만(설치는
# 보고). 판정·집계는 라이브러리 함수 하나다(시험이 `py_deps_run` 을 모의로
# 갈아 호출을 센다). **자리는 1-5 unlock 뒤가 불변식이다(TASK-283 범위 0
# 독자 전수)**: `projects/*/config/**` 는 git-crypt 경계 안이라 빈 기계의 잠긴
# 클론에서 `projects/*/config/py_requirements.txt` 는 암호문이다 — 1-4 자리에서
# 읽으면 목록이 아니라 \0GITCRYPT 바이트를 pip 에 넘긴다.
rw_phase "① 환경 점검·보충 · 1-5a 프로젝트 의존(unlock 뒤)"
project_py_deps_ensure "$ROOT" "$IN_JOB"
# 1-5b) 외부 import 전수 대조 검사 칸(TASK-576 범위 1) — 목록에 빠진 모듈은 위 통로가 영영 모른다(늦은 import 는 회차에서야 rc 1 · JL-2026-10-2473).
project_py_imports_check "$ROOT"


# ①-0) 값 입력 창구 단일화(TASK-116 ③, 판정 축 승격 TASK-116b ①).
# config/credentials.yml 의 intake 목록(단일 원천)을 core/cred_intake.py
# 가 읽어 **이 자리
# 하나에서만** 숨김 입력을 받는다 - 아래 개별 절(1-2 dpipe·1-7
# Tailscale)은 이제 자기 자리에서 손수 `read -rsp` 로
# 사용자를 내보내지 않고, 상태만 보고 이미 채워졌으면 그대로 통과한다
# (재질문 없음). 판정은 존재·스코프 두 축이라 **missing(값 없음)과
# insufficient(값은 있는데 정본 자격이 아님) 양쪽에서 묻는다** - 부족을
# have 에 섞어 묻지 않던 것이 TASK-116 의 결함이었다. 대상은
# required:true 항목만(dpipe·ts_authkey 등 - 나머지는 각자 자리가
# 있다: vault 암호구는 1-5 절이 vault_keygen.py 로 직접 받고, Claude 로그인
# (`rc_login`, 잡·알씨 공통 단일 원천 — TASK-154)은 interactive_only 라 이
# 창구가 대신 받을 수 없다. 옛 `claude_token` 항은 폐기 표기라 순회 밖). 비대화 모드·비TTY 에서는 절대 묻지 않는다
# (CLAUDE.md 규칙 14) - 그 경우 아래 개별 절이 종전대로 need 안내만
# 남긴다.
#
# **사람이 손을 떼는 자리가 여기다**(TASK-116f) — 숨김 입력 앞에서
# 끊긴 실행이 "어디까지 했는지"를 말하려면 이 소절도 절 이름을 갱신해야
# 한다(step 이 갱신하는 것은 ①~⑤ 다섯뿐이고 ①은 길다).
rw_phase "① 환경 점검·보충 · ①-0 값 입력 창구"
if [ "$NONINT" = 0 ] && [ -t 0 ]; then
  # `--renew` 지정 항목은 required 가 아니어도 순회에 든다(첫머리 관문이
  # 창구가 받을 수 있는 항목인지 이미 판정했다).
  INTAKE_IDS="$(YAC_RENEW="$RENEW" PYTHONPATH="$ROOT/scripts" python3 -c "
import os
from core import cred_intake as ci
renew = set(x for x in os.environ.get('YAC_RENEW', '').split(',') if x)
for it in ci.load_intake():
    if it.get('handler') and (it.get('required') or it['id'] in renew) \
            and not it.get('interactive_only') and not ci.retired_reason(it):
        print(it['id'])
" 2>/dev/null)"
  for IID in $INTAKE_IDS; do
    ISTATE="$(PYTHONPATH="$ROOT/scripts" python3 -c "
from core import cred_intake as ci
print(ci.status('$IID'))
" 2>/dev/null)"
    case "$ISTATE" in
      have)
        if renew_wanted "$IID"; then
          # 갱신 지정(TASK-233) — 값이 있어도 묻고 아래 기입 갈래(지문
          # 재기준 포함)를 그대로 탄다.
          say "$IID 갱신 요청(--renew) — 값이 있어도 다시 묻는다"
        else
          # have 통과 줄이 갱신 방법을 말한다(무소음 금지, CR-0006).
          ok "$IID 값·자격 확인(통합 창구) · 갈아야 하면 $(renew_hint "$IID")"
          continue
        fi ;;
      unknown)
        # 판정 자체를 못 한 갈래(네트워크·훅 실패). 값을 묻지 않는다 —
        # 멀쩡한 값을 "모른다"는 이유로 다시 받게 하지 않기 위함이다.
        bad "$IID 상태 조회불가(통합 창구) — 프로브가 판정을 못 냈다(네트워크·훅 확인)"
        continue ;;
      insufficient)
        # 값은 있는데 정본 자격이 아니다(TASK-116b). 이 갈래를 have 로
        # 삼키던 것이 "창구가 묻지 않는" 결함이었다 — 여기서 묻는다.
        say "$IID 값은 있으나 정본 자격이 요구하는 권한이 없다(스코프 부족) — 정본 값이 아닐 수 있어 다시 묻는다(그래도 부족하면 그 토큰의 권한 편집)" ;;
    esac
    IOUT="$(PYTHONPATH="$ROOT/scripts" python3 scripts/core/cred_intake.py fill "$IID")"
    case "$IOUT" in
      OK)             fix "$IID 값 입력·기입 완료(통합 창구)"; cred_stamp_save ;;
      "FAIL(빈 입력)") need "$IID — 통합 창구에서 건너뜀(빈 입력) - 아래 개별 절 안내 참고" ;;
      *)              bad "$IID 값 입력 실패(통합 창구): $IOUT" ;;
    esac
  done
else
  say "값 입력 창구 절 건너뜀(비대화·비TTY) - 개별 절의 need 안내로 대신한다"
fi

# ①-0a) PC 공개키를 이 기계에 붙인다(TASK-259, 사용자 2026-09-26 03:36 "ssh key 가
# 등록 안 돼 접속이 안 되는데 … 이 절차는 reworker 에 있을 텐데 왜 안 됐지").
# 첨부(vast_api.attach_key)·대상 계정 authorized_keys 등재는 이관 m0 에만 있었고
# ①-0 창구는 pc_ssh_pubkey **파일만** 받았다 — 이관 없이 만들어졌거나 그 항이
# 생긴 뒤(TASK-234)의 기존 기계에는 키가 영영 붙지 않는 결함(CR-0002). 여기서
# 창구가 받은 파일이 있으면 m0 과 **같은 원시**(한 통로, CR-0015)로 ⓐ 자기
# 인스턴스 첨부 ⓑ 대상 계정(config/migrate.yml remote_user) authorized_keys 멱등
# 등재(700/600) ⓒ Vast 계정 수준 등록(비어 있을 때만)을 하고 결과 한 줄을 남긴다.
# 파일이 없으면 need 한 줄(창구 안내)뿐이다. 대화형 여부와 무관하다 — 판정
# 재료는 파일이지 TTY 가 아니다. 키 본문은 어느 문면에도 없다(종류·주석만).
PCK_OUT="$(PYTHONPATH="$ROOT/scripts" python3 scripts/migrate.py pc-key 2>&1)"
PCK_RC=$?
PCK_LINE="${PCK_OUT##*$'\n'}"
case "$PCK_RC" in
  0) ok "$PCK_LINE" ;;
  3) need "$PCK_LINE" ;;
  *) bad "PC 공개키 첨부·등재(rc $PCK_RC): $PCK_LINE" ;;
esac

# ①-0b) tg2(텔레그램 방식2) 로그인(TASK-088c). 값은 바로 위 ①-0 창구가
# 받지만, 그 값으로 여는 **세션**은 사람이 1회용 코드를 읽어 줘야 서는
# 자리다 — 종전에는 그 코드를 관제 세션이 채팅으로 릴레이하는 별도
# 경로였고, 값 입력이 이 창구로 모인 이상 로그인도 같은 자리에서
# 끝나는 것이 한 통로 원칙이다(CR-0015). **새 통로는 없다**: 이 절은
# 기존 `tg2_login` 도구가 쓰는 그 원시(`scripts/tg2_util.py` 의
# `login()` 3단계)를 부를 뿐이고, 도구 쪽은 그대로다.
#
# **의존도 이 자리에서 닫는다**(TASK-088d): 방식2는 telethon 위에 서는데
# 그것은 필수 의존이 아니라 선택 기능 의존이라 셋업이 깔지 않는다 — 그래서
# 088c 의 이 절은 라이브러리 없는 기계에서 "계측 불가"로 끝났고 사용자가
# pip 를 따로 쳐야 했다. 한 명령·한 순서(CR-0025)가 되려면 창구가 스스로
# 확보해야 한다. 사전은 `config/py_optional.txt`, 확보는 아래
# `py_optional_ensure` 가 기존 통로로 한다.
#
# 코드·2단계 비밀번호는 `getpass` 로만 받아 화면·로그·통보 어디에도
# 남기지 않는다(PROTOCOL 4-1). 비대화·비TTY 면 묻지 않고 need 한 줄만
# 남긴다(CLAUDE.md 규칙 14).

# 선택 의존 확보 원시(TASK-088d). 인자는 **pip 이름 하나**이고, 그 짝인
# import 이름은 사전(`config/py_optional.txt`)이 안다 — 호출부에 두 번
# 적으면 그 두 벌의 차이가 곧 어긋남의 저수지다(CR-0010). 설치 통로도
# 새로 만들지 않고 기존 `py_deps_ensure.sh` 에 목록 파일·항목 인자를 얹어
# 그대로 쓴다(CR-0004 프리미티브 조립 · CR-0015 한 통로).
#
# 판정은 설치기의 rc 가 아니라 **이 자리의 소비 조건**이다(CR-0016):
# py_deps_ensure 는 이 기계에서 허브를 돌릴 수 있는 인터프리터 **전부**를
# 대상으로 삼아 그중 하나만 막혀도(PEP 668 등) rc=1 인데, 로그인 절이
# 실제로 쓰는 것은 아래가 부르는 그 `python3` 하나다 — 거기서 import 가
# 서면 이 절은 선다. 실패 사유는 `PY_OPT_WHY` 에 담는다(값이 아니라 사유다).
PY_OPT_WHY=""
py_optional_ensure() {  # $1=pip 이름 -> 0=확보됨 / 1=미확보(PY_OPT_WHY 에 사유)
  local pkg="$1" list="$ROOT/config/py_optional.txt" imp
  PY_OPT_WHY=""
  imp="$(awk -v p="$pkg" '$1 == p {print $2; exit}' "$list" 2>/dev/null)"
  if [ -z "$imp" ]; then
    PY_OPT_WHY="$pkg 미등재(config/py_optional.txt) — 사전에 먼저 등재하라"
    return 1
  fi
  python3 -c "import $imp" >/dev/null 2>&1 && return 0
  say "$pkg 미설치 — 선택 의존 사전에서 1회 확보 시도(config/py_optional.txt)"
  bash "$ROOT/scripts/py_deps_ensure.sh" "$list" "$pkg" >/dev/null 2>&1
  python3 -c "import $imp" >/dev/null 2>&1 && return 0
  PY_OPT_WHY="$pkg 확보 실패(오프라인·pip 제약 — 수동: python3 -m pip install $pkg)"
  return 1
}

# 대화형 판정을 한 줄로 뽑아 둔다 — 아래 갈래가 대화형 여부로 갈리고,
# 판정 원천이 갈래 안에 흩어져 있으면 시험이 그 갈래에 닿지 못한다
# (V-8·V-13 이 이 변수로 갈래를 돈다).
TG2_INTERACTIVE=0
if [ "$NONINT" = 0 ] && [ -t 0 ]; then TG2_INTERACTIVE=1; fi
TG2_STATE="$(PYTHONPATH="$ROOT/scripts" python3 scripts/tg2_util.py state 2>/dev/null)"
case "$TG2_STATE" in
  session_present)
    ok "tg2 세션 파일 존재(존재만 — 실인가는 실제 송수신에서 드러난다)" ;;
  need_creds)
    say "tg2 방식2 자격 미기입 — 로그인 절 건너뜀(값은 ①-0 창구가 묻는다)" ;;
  need_login)
    if [ "${TG2_INTERACTIVE:-0}" = 1 ]; then
      # 자격이 있는데 라이브러리가 없어 로그인이 "계측 불가"로 끝나면
      # 사용자 경로(`reworker` 한 번)가 닫히지 않는다(TASK-088d) — 그래서
      # 창구가 여기서 스스로 확보한다. 확보에 실패하면 로그인 절은
      # 건너뛰고 사유를 그대로 실은 need 한 줄만 남긴다(CR-0016).
      if py_optional_ensure telethon; then
        TG2_OUT="$(PYTHONPATH="$ROOT/scripts" python3 scripts/tg2_util.py login 2>&1 | tail -1)"
        case "$TG2_OUT" in
          "로그인 성공"*)   fix "tg2 로그인 완료 — $TG2_OUT" ;;
          "이미 로그인됨"*) ok "tg2 로그인 세션 유효" ;;
          *)                need "tg2 로그인 — $TG2_OUT" ;;
        esac
      else
        need "tg2 로그인 건너뜀 — $PY_OPT_WHY"
      fi
    else
      need "tg2 로그인(대화형) — 자격은 있는데 세션이 없다. 대화형 셸에서 'bash scripts/reworker.sh' 를 한 번 돌리면 코드 발송·숨김 입력·2단계 비밀번호까지 이 자리에서 끝난다"
    fi ;;
  *)
    # 사전 선언 부재 등 — 물을 수 없었던 것이지 고장이 아니다(CR-0016).
    say "tg2 로그인 절 계측 불가(${TG2_STATE:-빈 응답}) — 판정을 내리지 않는다" ;;
esac

# 1-1) git 잔재 정리
if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
  git rebase --abort >/dev/null 2>&1 && fix "미완 rebase 중단" || bad "rebase 중단 실패"
fi
if [ -f .git/MERGE_HEAD ]; then
  git merge --abort >/dev/null 2>&1 && fix "미완 merge 중단" || bad "merge 중단 실패"
fi
if [ -f .git/index.lock ]; then
  if ! pgrep -f "gi[t] " >/dev/null 2>&1; then
    rm -f .git/index.lock && fix "고아 index.lock 제거"
  else
    bad "index.lock 존재 + git 프로세스 가동 중 — 수동 확인 필요"
  fi
fi

# 1-2) 원격 인증 점검/복구. "죽었다고 가정"하지 않는다 — 실제로 시험해
# 실패가 확인될 때에만 토큰 창구를 연다. 대화형 숨김 입력은 위 ①-0
# 값 입력 창구가 이미 한 번 시도했으므로(TASK-116 ③), 여기서는 손수
# `read -rsp` 를 다시 열지 않는다 — 환경변수(비대화형에서도 쓸 수 있는
# 문서화된 경로) 재확인만 한다.
if git fetch -q origin main 2>/dev/null; then
  ok "원격 인증 정상(fetch)"
else
  say "원격 fetch 실패 — 자격증명 재확인"
  TOKEN="${GITHUB_TOKEN:-}"
  if [ -n "$TOKEN" ]; then
    printf 'https://x-access-token:%s@github.com\n' "$TOKEN" > ~/.git-credentials
    chmod 600 ~/.git-credentials
    git config --global credential.helper store
    unset TOKEN
    cred_stamp_save   # 우리가 쓴 변화 — 지문 기준 재설정(①-지문)
    if git fetch -q origin main 2>/dev/null; then
      fix "git 자격증명 재기입(GITHUB_TOKEN) + fetch 성공"
    else
      bad "GITHUB_TOKEN 기입 후에도 fetch 실패 — 토큰 권한·만료 확인 필요"
    fi
  else
    need "dpipe 토큰 — 대화형 셸에서 이 스크립트를 한 번 돌리면 ①-0 값 입력 창구가 묻는다(또는 GITHUB_TOKEN 환경변수로 재실행)"
  fi
fi

# 1-2b) dpipe 스코프 프로브(TASK-116 ①, 안내 갈래 정정 TASK-116b ③).
# "존재·비어있지 않음" 대신 "필요한 권한이 실제로 먹히는가"를 본다 —
# 읽기 전용이라 IN_JOB 여부와 무관하게 항상 돈다.
#
# 부족을 "재입력으로 못 고친다"고 단정하던 옛 전제는 **틀렸다**
# (2026-09-03 실측): 이 기계의 실제 원인은 권한 부족이 아니라 정본이
# 지정한 dpipe 가 아닌 **다른 토큰이 앉아 있는 것**이었고, 그것은
# 재입력으로 고쳐진다. 옛 문면대로면 사용자가 멀쩡한 토큰의 권한을
# 만지러 간다. 그래서 순서는 ①값 정정 ②그래도 부족하면 권한 편집이고,
# 판정도 bad 가 아니라 need(사람 입력 대기)다. 조회불가만 bad 로 남는다
# — 그쪽은 입력으로 풀리는 문제가 아니다(네트워크·대상 부재).
if [ -s "$HOME/.git-credentials" ]; then
  PROBE_OUT="$(PYTHONPATH="$ROOT/scripts" python3 scripts/core/cred_probe.py dpipe 2>&1)"
  PROBE_LAST="$(printf '%s\n' "$PROBE_OUT" | tail -1)"
  case "$PROBE_LAST" in
    ok)
      ok "dpipe 스코프 프로브 전건 통과" ;;
    부족*)
      need "dpipe 스코프 프로브 $PROBE_LAST — ① 먼저 이 기계의 값이 정본 자격(dpipe)이 아닐 수 있다: 대화형 셸에서 'bash scripts/reworker.sh' 를 돌려 ①-0 창구에 정본 값을 넣고(창구가 묻지 않으면 $(renew_hint dpipe)) ② 그래도 부족하면 GitHub Settings → Developer settings → Personal access tokens 에서 그 토큰의 권한 편집(PROTOCOL-4, RECOVERY.md)" ;;
    *)
      bad "dpipe 스코프 프로브 조회불가 — $PROBE_LAST" ;;
  esac
else
  say "dpipe 스코프 프로브 건너뜀(~/.git-credentials 없음)"
fi

# 1-3) 최신화(--autostash: 더러운 트리를 스스로 치우고 되돌린다)
# `.worker_name` 색인 제거 전이(TASK-583)의 뒤처리를 pull **앞뒤**에 둔다 —
# 앞은 옛 판이 이미 당겨 미병합으로 남긴 트리(그대로면 pull --rebase 가 거부),
# 뒤는 이 pull 이 방금 전이를 만든 트리. 자기 갱신 재실행(exec)보다 앞이어야
# 새 판의 1-3 이 막히지 않는다.
rw_identity_repair "pull 앞"
SELF_BEFORE="$(md5sum scripts/reworker.sh 2>/dev/null | cut -d' ' -f1)"
if git pull --rebase --autostash -q origin main 2>/dev/null; then
  rw_identity_repair "pull 뒤"
  rw_identity_ensure
  # 신원이 비었던 사이 state/unknown 으로 갈린 원장을 제자리로(TASK-594 — 없으면 무동작 · 삭제 0, 보관본으로 옮긴다)
  say "$(python3 "$REWORKER_ROOT/scripts/core/state_reclaim.py" --root "${ROOT:-$REWORKER_ROOT}" 2>&1 | tail -1)"
  ok "작업 폴더 최신화 완료($(git rev-parse --short HEAD))"
  SELF_AFTER="$(md5sum scripts/reworker.sh 2>/dev/null | cut -d' ' -f1)"
  if [ "$SELF_BEFORE" != "$SELF_AFTER" ] && [ -z "${REWORKER_REEXEC:-}" ]; then
    say "reworker 자신이 갱신됨 — 새 판으로 재실행"
    REWORKER_REEXEC=1 exec bash scripts/reworker.sh "$@"
  fi
else
  rw_identity_repair "pull 뒤"
  bad "pull --rebase 실패 — 위 항목 해소 후 재실행"
fi

# 1-3b) 저장소 설정 코드화 적용(TASK-125, PROTOCOL 7-2). git 밖 설정
# (Actions 변수 WORKER·비밀 2종·워크플로 기본 권한·Actions 허용 범위·
# 러너 라벨·브랜치 보호)은 저장소 미러 백업에 담기지 않는다 — 복원자가
# 하나를 빠뜨려도 아무 소리가 나지 않고 미러 워크플로만 조용히 죽는다.
# 선언(config/github_repo.yml)과 실제를 대조해 **부족·상이 항만** 적용한다
# (사람 손 0, 멱등). 1-3 뒤에 두는 이유는 선언 사전이 최신이어야 대조가
# 의미 있기 때문이다. 값은 원천 파일에서 GitHub 공개키로 봉인돼 나가고
# 어디에도 찍히지 않는다(CR-0026).
#
# **적용은 host 인스턴스만 한다(TASK-136 10, 2026-09-05 실측).** 이 절이
# 적용하는 항 중 `WORKER` 변수는 **기계 하나에 한 벌**인 저장소 설정인데,
# 비-host 인스턴스에서 그대로 돌자 그 변수를 자기 이름(`vast1-c1`)으로
# 되썼다 — `tasks.yml` 의 기본 `runs-on` 이 통째로 그 인스턴스로 넘어가는
# 것이고, 아무 소리도 나지 않는다. 비-host 는 `diff` 만 돌려 어긋남을
# 통보한다(관측은 유지, 손은 대지 않는다 — CR-0013 확정은 사람·host).
if [ -s "$HOME/.git-credentials" ]; then
  RS_MODE="$(repo_settings_mode "$IS_HOST")"
  RS_OUT="$(python3 scripts/repo_settings.py "$RS_MODE" 2>&1)"
  RS_RC=$?
  RS_APPLIED="$(printf '%s\n' "$RS_OUT" | grep -c ': 적용 —')"
  RS_NEED="$(printf '%s\n' "$RS_OUT" | grep ': 사람 입력 필요 —' | head -2 | tr '\n' ' ')"
  RS_GAP="$(printf '%s\n' "$RS_OUT" | sed -n 's/^부족 권한: //p')"
  [ -n "$RS_GAP" ] && need "저장소 설정 조회 권한 부족($RS_GAP) — dpipe 토큰 권한 편집(PROTOCOL-4)"
  [ -n "$RS_NEED" ] && need "저장소 설정 값 원천 부재 —$RS_NEED"
  if [ "$RS_RC" != 0 ] && [ "$RS_MODE" = diff ]; then
    need "저장소 설정 어긋남(비-host 인스턴스라 적용하지 않는다 — host 에서 reworker 실행): $(printf '%s\n' "$RS_OUT" | tail -1)"
  elif [ "$RS_RC" != 0 ]; then
    bad "저장소 설정 어긋남이 남았다 — $(printf '%s\n' "$RS_OUT" | tail -1)"
  elif [ "$RS_APPLIED" -gt 0 ]; then
    fix "저장소 설정 ${RS_APPLIED}항 적용(선언 config/github_repo.yml 복원)"
  else
    ok "저장소 설정 선언과 일치(드리프트 0, $RS_MODE)"
  fi
else
  say "저장소 설정 대조 건너뜀(~/.git-credentials 없음)"
fi

# 1-5b) 이관 data 복원·검증·확인증(TASK-223, PROTOCOL 17-8 보강 「이관」).
# 허브에 이 워커가 받을 열린 MIG(runs/MIG-*/MANIFEST.md, 확인증 없음, 원천
# 지문 ≠ 이 기계)가 있을 때만 움직이고, 없으면 한 줄로 지나간다(무동작).
# 수신(taildrop --get) → 봉인물 sha256 대조 → 1-5 의 키로 복호 → 전수 대조 뒤
# 전개 → 모델 재다운로드 → 검증 전건 → 이관 확인증 등재 — 전부
# core/migrate.restore 한 통로다. 봉인물이 PC 로 갔으면 PC 쪽 한 줄 명령을
# 띄우고 대화형이면 도착을 기다린다(--wait).
rw_phase "① 환경 점검·보충 · 1-5b 이관 data 복원"
# 한마디 이관(MG-0130)이 원격 걸음을 노드로 돌 때(m3b 가 YAC_MIG_FLOW=<MIG> 를
# 싣는다)는 복원 단계를 m3b~m3e 가 한 단계씩 부르므로 여기서는 돌지 않는다 —
# 한 통로(TASK-234). 손 이관(223 폴백)은 종전 그대로 여기서 전부 돈다.
if [ -n "${YAC_MIG_FLOW:-}" ]; then
  ok "이관 ${YAC_MIG_FLOW} 복원은 실행그래프 노드(MG-0130 m3b~m3e)가 수행 — 1-5b 건너뜀"
  MIG_SKIP=1
else
  MIG_SKIP=0
fi
MIG_ARGS=()
[ -n "${MIG_KEYF:-}" ] && [ -s "$MIG_KEYF" ] && MIG_ARGS+=(--identity "$MIG_KEYF")
[ "$NONINT" = 1 ] || MIG_ARGS+=(--wait)
if [ "$MIG_SKIP" = 1 ]; then
  MIG_OUT=""; MIG_RC=skip
else
  MIG_OUT="$(python3 scripts/migrate.py restore "${MIG_ARGS[@]}" 2>&1)"; MIG_RC=$?
  printf '%s\n' "$MIG_OUT" | sed 's/^/  /'
fi
case "$MIG_RC" in
  skip) : ;;
  0) if printf '%s' "$MIG_OUT" | grep -q '이관 확인증 등재'; then
       fix "이관 data 복원·검증·확인증 등재"
     else
       ok "이관 대기 없음(또는 확인증 기등재)"
     fi ;;
  3) need "이관 봉인물 미도착 — 위 안내 한 줄대로 보낸 뒤 reworker 재실행" ;;
  4) need "이관 data 복호 열쇠 — 대화형 셸에서 reworker 를 돌려 암호구 입력" ;;
  *) bad "이관 data 복원·검증 실패(rc=$MIG_RC) — 확인증 0(위 [FAIL] 줄 참조)" ;;
esac

# 1-5c) 깃 밖 지역 데이터 오프사이트 복원(TASK-242, PROTOCOL 17-8 보강 「오프사이트」).
# 허브에 이 워커의 오프사이트 확인표(runs/OFF-<워커>/MANIFEST.md)가 있고 그 묶음이
# 이 기계에 없으면(전수 일치하면 무동작) C 릴리스 자산 내려받기 → B 허브 복원 요청
# 표지 + 테일드롭 수신 대기(PC 응답기) → 사람 한 줄(텔레그램) 순으로 받아 조각
# 결합·sha256 전수 대조·전개·모델 refetch 까지 core/offsite.restore 한 통로다.
# 열쇠는 1-5 의 vault 키(이관과 같은 수신자)이고 대화형이면 도착을 기다린다.
rw_phase "① 환경 점검·보충 · 1-5c 오프사이트 데이터 복원"
OFF_ARGS=()
[ -n "${MIG_KEYF:-}" ] && [ -s "$MIG_KEYF" ] && OFF_ARGS+=(--identity "$MIG_KEYF")
[ "$NONINT" = 1 ] || OFF_ARGS+=(--wait)
OFF_OUT="$(python3 scripts/offsite_sync.py restore "${OFF_ARGS[@]}" 2>&1)"; OFF_RC=$?
printf '%s\n' "$OFF_OUT" | sed 's/^/  /'
case "$OFF_RC" in
  0) if printf '%s' "$OFF_OUT" | grep -q '오프사이트 복원 — '; then
       fix "오프사이트 데이터 복원($(printf '%s\n' "$OFF_OUT" | grep -c '오프사이트 복원 — ')묶음)"
     else
       ok "오프사이트 복원 대상 없음(확인표 없음 또는 전수 일치)"
     fi ;;
  3) need "오프사이트 봉인물 미도착 — 위 안내 한 줄대로 PC 에서 보낸 뒤 reworker 재실행(PC 응답기가 켜져 있으면 다음 폴링에 보낸다)" ;;
  4) need "오프사이트 복호 열쇠 — 대화형 셸에서 reworker 를 돌려 암호구 입력" ;;
  *) bad "오프사이트 데이터 복원 실패(rc=$OFF_RC) — 위 [FAIL] 줄 참조" ;;
esac
unset OFF_ARGS OFF_OUT OFF_RC
if [ -n "${MIG_KEYF:-}" ]; then rm -f "$MIG_KEYF"; fi
unset MIG_KEYF MIG_ARGS MIG_OUT MIG_RC MIG_SKIP

# 1-6) 셋업·크론 보충. 판정은 여기서 하고 **채우는 것은
# bootstrap_worker.sh 단일 원천에 위임**한다(워커 신원·claude 설치·
# YAC_TMP 구역·크론 3종의 줄 문면이 거기 한 곳에만 있게). 재귀 방지:
# bootstrap 말미의 reworker 호출은 YAC_REWORKER_ACTIVE 를 보고 건너뛴다.
# 관제 완장 표식이 먼저다 — obsv_boot cron 등재 여부가 이 표식에 달렸다.
if [ "$CONTROL" = 1 ] && [ ! -f "$LV_OBSV_HOME/CONTROL_NODE" ]; then
  mkdir -p "$LV_OBSV_HOME"
  touch "$LV_OBSV_HOME/CONTROL_NODE"
  fix "관제 완장 표식 생성($LV_OBSV_HOME/CONTROL_NODE)"
fi
GAPS="$(setup_gaps "$ROOT")"
if [ -z "$GAPS" ]; then
  ok "워커 셋업·크론 3종 등재 완료"
elif [ -z "$WORKER" ]; then
  bad "셋업 공백($GAPS) 이 있으나 워커 이름을 알 수 없다 — 'bash scripts/reworker.sh <워커>' 로 재실행"
else
  say "셋업 공백 감지($GAPS) — bootstrap_worker.sh 로 보충"
  if YAC_REWORKER_ACTIVE=1 bash scripts/bootstrap_worker.sh "$WORKER"; then
    REST="$(setup_gaps "$ROOT")"
    if [ -n "$REST" ]; then
      bad "셋업 공백 잔여($REST) — 수동 확인 필요"
    else
      fix "워커 셋업·크론 보충($GAPS)"
    fi
  else
    bad "bootstrap_worker.sh 실패 — 셋업 공백($GAPS) 잔존"
  fi
fi

# 1-7) Tailscale 영구 합류(ts_join.sh 는 authkey 없으면 조용히 건너뛰는
# 멱등 스크립트라 그대로 재사용한다 — 코어 재사용 원칙).
#
# authkey 경로 단일 원천(TASK-113 1 실측): 이 절은 종전
# `~/.secrets/tailscale_authkey` 를 봤는데 ts_join.sh·vault(export/import)
# 는 실제로 `~/.secrets/ts_authkey`(`YAC_TS_AUTHKEY_FILE` 기본값)를 읽고
# 쓴다 — 사용자가 RECOVERY.md 안내대로 `tailscale_authkey` 에 값을 넣어도
# ts_join.sh 는 그 파일을 보지 않아 조용히 건너뛰었다. 실물(vault
# MANIFEST 의 `home_secrets/ts_authkey`)을 기준으로 통일한다.
TS_AUTHKEY_FILE="${YAC_TS_AUTHKEY_FILE:-$HOME/.secrets/ts_authkey}"
# TASK-113b: OAuth 클라이언트(무만료)가 있으면 authkey 파일이 없어도
# ts_join.sh 가 일회용 authkey 를 API 로 즉석 발급해 합류한다 — 이
# 게이트도 그 자격을 통과 조건에 넣는다(그러지 않으면 authkey 파일이
# 없다는 이유만으로 need 로 멈춘다).
TS_OAUTH_FILE="${YAC_TS_OAUTH_FILE:-$HOME/.secrets/ts_oauth_client}"
TS_BIN="${YAC_TS_BIN:-$HOME/.local/bin/tailscale}"
TS_SOCK="${YAC_TS_SOCK:-$HOME/.local/state/tailscale/tailscaled.sock}"
if [ -x "$TS_BIN" ] && "$TS_BIN" --socket="$TS_SOCK" status >/dev/null 2>&1; then
  ok "Tailscale 합류 상태 정상"
elif [ -s "$TS_AUTHKEY_FILE" ] || [ -n "${TS_AUTHKEY:-}" ] || [ -s "$TS_OAUTH_FILE" ]; then
  if bash scripts/ts_join.sh >/dev/null 2>&1 \
     && "$TS_BIN" --socket="$TS_SOCK" status >/dev/null 2>&1; then
    fix "Tailscale 재합류(ts_join)"
  else
    bad "Tailscale 합류 실패 — 'bash scripts/ts_join.sh' 출력 확인"
  fi
else
  need "Tailscale authkey(권장: ts_oauth_client) — 대화형 셸에서 이 스크립트를 한 번 돌리면 ①-0 값 입력 창구가 묻는다(또는 콘솔에서 발급해 ~/.secrets/ts_authkey 에 600으로 저장, OAuth 클라이언트는 ~/.secrets/ts_oauth_client 에 'client_id:client_secret' 1줄)"
fi

# 1-7b) 이름 일치 판정(TASK-113 2). 합류돼도 이름이 접미(`<이름>-N`)면
# Funnel 주소가 바뀌어 관측 창이 끊긴다 — reworker 는 이것도 "정상"으로
# 지나가지 않는다(합류 자체 판정과 별개 원자).
if [ -x "$TS_BIN" ] && "$TS_BIN" --socket="$TS_SOCK" status >/dev/null 2>&1; then
  TS_NAME_STATE="$(lv_ts_name_state)"
  case "$TS_NAME_STATE" in
    일치) ok "Tailscale 이름 일치" ;;
    접미)
      say "[WARN] Tailscale 이름 접미($(lv_ts_self_dns)) — 관리 콘솔(Machines)에서 구 '$WORKER' 기계 rename 또는 삭제 후 재실행 필요"
      bad "Tailscale 이름 접미(콘솔 rename 필요) — RECOVERY.md 복구 외길 1단 참조"
      ;;
    부재) : ;;  # 합류 자체는 위 절에서 이미 판정·통보
  esac
fi

# 1-9) Claude 인증 원천 단일화(TASK-154 범위 0, PLN-0519 — 개정 전:
# TASK-113 5 의 `.bashrc` export 장기 토큰 이전 절). **로그인 자격 파일
# (`~/.claude/.credentials.json` + `~/.claude.json` 계정 키)이 잡·알씨
# 공통의 유일한 인증 원천이다.** 실측(관제 2026-09-15): 러너 프로세스
# (Runner.Listener·Worker) 환경에 `CLAUDE_CODE_OAUTH_TOKEN` 0개 — 워크플로
# run 셸은 `.bashrc` 를 읽지 않으므로 잡의 `claude -p` 는 이미 로그인
# 자격으로 인증한다. 그런데 `.bashrc` 의 내보내기 줄이 남아 있으면 러너
# 루프를 **로그인 셸에서 다시 띄우는 순간** 환경변수가 로그인 자격을 이겨
# 잡만 옛 계정으로 돈다(계정 전환의 무소음 갈래, CR-0006). 그래서 이 절이
# 그 줄을 **멱등으로 걷어낸다**(값 직접 기재형·파일 참조형 둘 다 — 원시는
# `core/rc_account.bashrc_strip_export`, 값은 어디에도 남기지 않는다).
# 옛 정본 파일 `~/.secrets/claude_oauth_token` 은 지우지 않는다(삭제 0 —
# `credentials.yml` 의 `claude_token` 항이 폐기 표기로 상태 전이됐고 그
# 자리는 `rc_login` 항이 잇는다).
BASHRC_STRIPPED="$(PYTHONPATH="$ROOT/scripts" python3 "$ROOT/scripts/core/rc_account.py" bashrc-strip "$HOME/.bashrc" 2>/dev/null || echo 0)"
case "$BASHRC_STRIPPED" in
  ''|*[!0-9]*) bad "~/.bashrc 토큰 내보내기 줄 판정 실패(core/rc_account 호출 오류)" ;;
  0) : ;;
  *) fix "~/.bashrc 의 CLAUDE_CODE_OAUTH_TOKEN 내보내기 ${BASHRC_STRIPPED}줄 제거(인증 원천 = 로그인 자격 파일 하나, PLN-0519)" ;;
esac
unset BASHRC_STRIPPED

# 1-9b) 로그인 자격 무비용 판정(TASK-113c 범위3 → TASK-154 로 잡·알씨
# 공통). 판정은 코어 단일 원천(`core/claude_home.has_rc_credentials` —
# 존재·JSON 형식·`claudeAiOauth` 키 유무만 보고 값은 절대 반환하지 않는다,
# 무비용). 실유효성은 1-10 `claude_p` 동작 프로브가 본다. 종전에는 알씨
# 거처(`lv_rc_target` 대상)에서만 물었으나 이제 잡의 자격도 이 파일이라
# **모든 워커**에서 묻는다 — 어느 계정으로 로그인됐는지는 `bash
# scripts/rc_account_switch.sh --check` 가 말한다(계정 전환 통로, 7-4).
if PYTHONPATH="$ROOT/scripts" python3 -c "
from core import claude_home as ch
import sys
sys.exit(0 if ch.has_rc_credentials() else 1)
" 2>/dev/null; then
  ok "Claude 로그인 자격 존재(잡·알씨 공통 단일 원천, 형식 확인 — 동작은 1-10 claude_p 프로브)"
else
  # 안내는 "어디로 가라"가 아니라 "이 명령이 데려간다"다(TASK-238 ⑥) — 대화형
  # 실행이면 요약 뒤 알씨 창으로 들어가므로 그 창에서 곧바로 로그인한다.
  need "Claude 로그인 — 대화형 'bash scripts/reworker.sh' 가 요약 뒤 알씨 창(tmux $(lv_rc_cfg tmux_session rc))으로 데려간다: 그 창에서 Enter·브라우저 로그인·Ctrl+b d(비대화형이면 'tmux attach -t $(lv_rc_cfg tmux_session rc)' 로 직접). setup-token 통로는 폐기됐다(TASK-154)"
fi
# 계정 보관소 요약(TASK-293) — 등재 상태 한 줄(값 0, `rc_account check`)과
# 새 계정 안내 한 줄. 미등재 계정은 손 등재(격리 HOME 로그인·파일 복사)가
# 아니라 전환 명령 하나가 등재 갈래까지 밟는다(CR-0025).
# 이 줄은 **등재 상태**지 동작 판정이 아니다(TASK-663 ⓓ) — 라이브 자격이 죽었는지는
# 1-10 claude_p 프로브가 재고, 고장이면 사전 선언 처방(remedy: account_switch)이 보관소의
# 산 계정으로 자동 전환한 뒤 재측정한다. 여기서 「정상」을 말하지 않는다(CR-0016).
ACCT_LINE="$(PYTHONPATH="$ROOT/scripts" python3 "$ROOT/scripts/core/rc_account.py" check 2>/dev/null)"
say "[INFO] Claude 계정 보관소 등재 — ${ACCT_LINE:-계측 불가} · 동작 판정·자동 전환은 1-10 claude_p 프로브(remedy account_switch) · 미등재 계정은 'bash scripts/rc_account_switch.sh <이름>' 한 명령(등재 → 전환)"
unset ACCT_LINE

# 1-9c) ntfy 구독 토픽 vault 이전 판정(TASK-113d, PLN-0233). 정본은
# `~/.secrets/ntfy_topic` — 판정·이전 로직 이중화를 피하려고
# `core/obsv.py` 의 멱등 이전 함수를 그대로 불러 쓴다(값은 어디에도
# 출력하지 않는다). 옛 경로만 있던 이 기계는 이전 1회가 "복구"로
# 집계된다(값 불변 — 폰 재구독 불요, 그 사실은 이 fix 문면이 ⑤ 절
# 텔레그램 통보에 실려 사용자에게 간다). 둘 다 없으면 실패가 아니라
# 정상(need 아님) — 첫 request_media 호출에서 자동 생성되고, 그 신규
# 생성 순간엔 core/obsv.py 자신이 재구독 안내 [WARN] 을 별도로 쏜다.
NTFY_MIGRATE_STATE="$(PYTHONPATH="$ROOT/scripts" python3 -c "
import os
from core import obsv
if obsv.migrate_ntfy_topic():
    print('migrated')
elif os.path.exists(obsv.NTFY_TOPIC_FILE):
    print('exists')
else:
    print('absent')
" 2>/dev/null || echo error)"
case "$NTFY_MIGRATE_STATE" in
  migrated) fix "ntfy 구독 토픽 vault 이전 완료(~/.secrets/ntfy_topic, 값 불변 — 폰 재구독 불요)" ;;
  exists)   ok "ntfy 구독 토픽 존재(vault 편입 대상, ~/.secrets/ntfy_topic)" ;;
  absent)   ok "정상: ntfy 구독 토픽 없음 — 첫 요청 시 자동 생성" ;;
  *)        bad "ntfy 토픽 이전 판정 실패(core/obsv import 오류)" ;;
esac

# 1-8) 러너 등록 자격(등록 자체는 잡 안에서 금지 — 이 잡을 태운 러너를
# 갈아치우는 것이 곧 자기 살해다).
RD="$YAC_RUNNER_DIR"
# 지역 .runner 가 있어도 API 에 없으면 stale 로 옮겨 아래 등록 갈래로(TASK-234).
if [ "$IN_JOB" != 1 ] && [ "$NO_RUNNER" != 1 ] && [ -f "$RD/.runner" ]; then
  runner_stale_check "$RD"; [ $? = 10 ] && fix "러너 stale 지역 등록 이동(API 에 없음) — 재등록"
fi
if [ "$IN_JOB" = 1 ]; then
  ok "잡 안 — 러너 등록 절 건너뜀"
elif [ "$NO_RUNNER" = 1 ]; then
  ok "러너 등록 보류(--no-runner — 이관 확인증·retire 뒤 m6b 신기계 활성화가 한다)"
elif [ -f "$RD/.runner" ]; then
  ok "러너 등록 자격 보유($RD/.runner)"
else
  RTOKEN="${GITHUB_TOKEN:-}"
  [ -z "$RTOKEN" ] && [ -f "$HOME/.git-credentials-token" ] && RTOKEN="$(cat "$HOME/.git-credentials-token")"
  [ -z "$RTOKEN" ] && [ -f "$HOME/.git-credentials" ] && RTOKEN="$(head -1 "$HOME/.git-credentials" | sed -E 's#.*:([^:@]+)@github\.com.*#\1#')"
  if [ -z "$RTOKEN" ] || [ -z "$WORKER" ]; then
    need "러너 등록 — GitHub 토큰(또는 워커 이름)을 찾지 못했다. GITHUB_TOKEN 을 주고 'bash scripts/reworker.sh <워커>' 재실행(수동 절차는 ENROLL §5)"
  else
    OWNER_REPO="$(git remote get-url origin | sed -E 's#.*github\.com[:/]##; s#\.git$##')"
    API="https://api.github.com/repos/$OWNER_REPO/actions/runners"
    read -r OLD_ID OLD_STATUS <<EOF2
$(curl -s -H "Authorization: Bearer $RTOKEN" "$API" | python3 -c "
import sys, json
rs = json.load(sys.stdin).get('runners', [])
m = [r for r in rs if r['name'] == '$WORKER']
print((str(m[0]['id']) + ' ' + m[0]['status']) if m else '- -')" 2>/dev/null || echo '- -')
EOF2
    if [ "$OLD_ID" != "-" ] && [ "$OLD_STATUS" = "online" ]; then
      bad "같은 이름($WORKER) 러너가 온라인 — 살아 있는 중복(워커 이름 유일성 규약). 등록 중단"
    else
      [ "$OLD_ID" != "-" ] && curl -s -X DELETE -H "Authorization: Bearer $RTOKEN" "$API/$OLD_ID" >/dev/null
      REG="$(curl -s -X POST -H "Authorization: Bearer $RTOKEN" -H "Accept: application/vnd.github+json" "$API/registration-token" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null || true)"
      if [ -z "$REG" ]; then
        bad "러너 등록 토큰 발급 실패 — 토큰 권한 확인 필요"
      else
        mkdir -p "$RD"
        ( cd "$RD" || exit 1
          if [ ! -x ./config.sh ]; then
            curl -sLo r.tar.gz https://github.com/actions/runner/releases/download/v2.336.0/actions-runner-linux-x64-2.336.0.tar.gz
            tar xzf r.tar.gz
            rm -f r.tar.gz
          fi
          POOL="$(python3 "$ROOT/scripts/core/instance.py" pool-labels 2>/dev/null || true)"
          env $(runner_root_env) ./config.sh --unattended --url "https://github.com/$OWNER_REPO" \
            --token "$REG" --name "$WORKER" --labels "self-hosted,$WORKER${POOL:+,$POOL}" --work _work )
        unset REG
        if [ -f "$RD/.runner" ]; then fix "러너 등록 완료($WORKER)"; else bad "러너 등록 실패"; fi
      fi
    fi
    unset RTOKEN
  fi
fi
# 1-8b) host 러너 풀 라벨 보강(TASK-315 재발사 ⓐ) — 이미 등록된 러너에 사전
# `host_runner_pool_labels` 를 더한다(graph_verify·풀 라우팅이 부류 라벨로 host 도 집는다).
# 멱등: 이미 단 라벨은 API 가 그대로 둔다. 실패는 재실행 명령을 실은 bad 항이다.
# 기계 키 `host_runner_pool_labels_by_machine` 우선(TASK-668) — vast2 는 gpu·vast2-gpu 도 단다.
POOL_LABELS="$(python3 "$ROOT/scripts/core/instance.py" pool-labels 2>/dev/null || true)"
if [ -n "$POOL_LABELS" ] && [ -n "$WORKER" ]; then
  if python3 "$ROOT/scripts/core/pass_plan.py" add-labels "$WORKER" "$POOL_LABELS"; then
    fix "러너 풀 라벨 보강($WORKER: $POOL_LABELS)"
  else
    bad "러너 풀 라벨 보강 실패($WORKER: $POOL_LABELS) — 'python3 scripts/core/pass_plan.py add-labels $WORKER $POOL_LABELS' 재실행"
  fi
fi
# 1-8c) 기대 인스턴스 러너의 기계 범위 풀 라벨 보강(TASK-622) — 이미 등록된 c1·c2… 러너에
# 사전 `pool_label_format` 의 라벨(vast1-cpu)을 더한다(멱등). 풀 라우팅이 이 라벨로만 쏘므로
# 빠진 러너는 후보에서 조용히 빠진다 — 실패는 재실행 명령을 실은 bad 항이다(CR-0006).
if [ -n "$WORKER" ]; then
  while read -r inst_name inst_cls; do
    [ -n "$inst_name" ] || continue
    inst_lbl="$(python3 "$ROOT/scripts/core/instance.py" pool-label "$inst_cls" 2>/dev/null || true)"
    [ -n "$inst_lbl" ] || continue
    if python3 "$ROOT/scripts/core/pass_plan.py" add-labels "$inst_name" "$inst_lbl"; then
      fix "인스턴스 러너 풀 라벨 보강($inst_name: $inst_lbl)"
    else
      bad "인스턴스 러너 풀 라벨 보강 실패($inst_name: $inst_lbl) — 'python3 scripts/core/pass_plan.py add-labels $inst_name $inst_lbl' 재실행(러너 미등록이면 ⓪ 절 inst_add 뒤)"
    fi
  done < <(python3 "$ROOT/scripts/core/instance.py" expected 2>/dev/null || true)
fi
# job-started 훅(매 잡 자동 unlock, PROTOCOL 17-5) — 멱등
if [ -d "$RD" ] && ! grep -q ACTIONS_RUNNER_HOOK_JOB_STARTED "$RD/.env" 2>/dev/null; then
  echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=$ROOT/scripts/runner_job_started.sh" >> "$RD/.env"
  fix "러너 job-started 훅 등록"
fi

# 1-9) 부팅 훅 자기 등록(재부팅 자동 부활). 자기 복제 — 한 번 복원된
# 기계는 다음 재부팅부터 사람 없이 이 스크립트를 다시 돌린다. 1순위는
# vast.ai 컨테이너 시작 스크립트(/root/onstart.sh), 없거나 쓸 수 없으면
# 계정 쪽 폴백(~/.bashrc + crontab @reboot) 양쪽에 건다.
if [ -z "$WORKER" ]; then
  bad "워커 이름 미상 — 부팅 훅 등록 건너뜀"
else
  ONSTART_FILE="${YAC_ONSTART_FILE:-/root/onstart.sh}"
  REVIVE_BASHRC="${YAC_REVIVE_BASHRC:-$HOME/.bashrc}"
  ACCOUNT_HOME="$(getent passwd "$ACCOUNT" 2>/dev/null | cut -d: -f6)"
  [ -n "$ACCOUNT_HOME" ] || ACCOUNT_HOME="$HOME"
  REVIVE_LOG="$ACCOUNT_HOME/obsv/run/onstart.log"
  mkdir -p "$(dirname "$REVIVE_LOG")" 2>/dev/null || true
  HOOK_OUT="$(register_onstart "$ONSTART_FILE" "$(revive_line root)" 2>&1)"
  HOOK_RC=$?
  echo "$HOOK_OUT"
  if [ "$HOOK_RC" = 0 ]; then
    case "$HOOK_OUT" in
      *"이미 등록됨"*) ok "부팅 훅 등재됨($ONSTART_FILE)" ;;
      *)               fix "부팅 훅 등록($ONSTART_FILE)" ;;
    esac
  else
    USER_LINE="$(revive_line user)"
    register_revive_line "$REVIVE_BASHRC" "$USER_LINE" "폴백(bashrc)" || true
    if crontab -l 2>/dev/null | grep -q 'scripts/restore\.sh'; then
      ok "부팅 훅 폴백(@reboot) 등재됨"
    elif command -v crontab >/dev/null 2>&1; then
      ( crontab -l 2>/dev/null || true ; echo "@reboot $USER_LINE" ) | crontab - \
        && fix "부팅 훅 폴백(@reboot) 등록" \
        || bad "@reboot 폴백 등록 실패"
    else
      bad "crontab 부재 — @reboot 폴백 건너뜀"
    fi
  fi
fi

# 1-10) 동작 프로브(TASK-130, PROTOCOL 4-2 보강 "동작 프로브"). 위 절들이
# 보는 것은 전부 **존재**다 — 로그인 자격 파일의 키 유무(1-9b), 주소 파일의 유무
# (③ `lv_tunnel_state`), 러너의 등록 상태(② `runner_health`). 셋 다 "그
# 자리에 무언가 있다"는 명제이고, 그것이 실제로 답한다는 명제가 아니다.
# 그래서 신 기계에서 세 자리가 모두 '정상'을 내는 동안 부활은 실패했다
# (2026-09-03 실측, PLN-0223). 이 절이 같은 자리를 **동작으로** 묻는다.
#
# 판정·목록은 전부 코어와 사전이 갖는다(`scripts/core/machine_probe.py`,
# `config/machine_probes.yml`) — 여기 있는 것은 순서와 통보 배열 합산뿐이다
# (CLAUDE.md 코드 규칙 3층). 새 프로브는 사전 한 줄이지 이 절의 한 줄이
# 아니다.
#
# 무해(free)한 것만 매 실행하고 paid(러너 잡을 실제로 태운다)는 `--deep`
# 일 때만 — 기본 off 가 안전한 기본값이다(CR-0024). 잡 안에서 러너 잡을
# 다시 태우는 자기 재귀는 사전의 `skip_in_job` 이 막는다(코어가 스스로
# 판정하므로 호출부가 잊을 수 없다).
#
# **계측 불가는 bad 도 need 도 아니다**(CR-0016): 자격 부재는 1-7~1-9b 가
# 이미 각 자격별로 `need` 를 내므로 여기서 또 세면 같은 사실이 두 줄이
# 되고, '고장'으로 세면 토큰 없는 기계에서 상시 거짓 경보가 된다. 정보로
# 한 줄 남긴다.
#
# 정직 고지(CR-0016): 이 절은 ①의 끝이라 ③(obsv_boot)보다 **앞선다** —
# 재부팅 직후 옛 `funnel_url.txt` 가 남아 있고 funnel 이 아직 안 열린
# 구간에서는 `public_http` 가 한 번 '고장'으로 잡힌다. 그것이 바로 종전
# 판정이 '확보'로 통과시키던 상태이므로 오보가 아니라 관측이고, ③이 연
# 뒤 다음 실행에서 정상으로 돌아온다.
rw_phase "① 환경 점검·보충 · 1-10 동작 프로브"
PROBE_COST=free
[ "${DEEP:-0}" = 1 ] && PROBE_COST=all
PROBE_SEEN=0
while IFS=$'\t' read -r P_ID P_STATE P_DETAIL; do
  [ -n "$P_ID" ] || continue
  PROBE_SEEN=$((PROBE_SEEN + 1))
  # fixed(TASK-663 ⓓ): 고장 → 사전 선언 처방(remedy, 예: 보관소 계정 자동 전환)
  # → 같은 프로브 재측정 정상. 코어가 처방·재측정을 다 했고 여기는 집계만.
  case "$P_STATE" in
    ok)           ok "동작 프로브 $P_ID — $P_DETAIL" ;;
    fixed)        fix "동작 프로브 $P_ID 복구 — $P_DETAIL" ;;
    fail)         bad "동작 프로브 $P_ID 고장 — $P_DETAIL" ;;
    *)            say "[INFO] 동작 프로브 $P_ID 계측 불가 — $P_DETAIL" ;;
  esac
done <<PROBE_EOF
$(PYTHONPATH="$ROOT/scripts" python3 scripts/core/machine_probe.py run \
    --cost "$PROBE_COST" --format tsv 2>/dev/null)
PROBE_EOF
[ "$PROBE_SEEN" -gt 0 ] || bad "동작 프로브 실행 실패(machine_probe run) — 사전·코어 확인 필요"

# 1-10b) 호스트 셸 환경 프로브(TASK-693). 2026-10-26 vast1 실측: `~/.bashrc` 가
# LD_LIBRARY_PATH 에 conda env lib 을 전역으로 얹어 `/usr/bin/ssh` 가 conda
# libcrypto 를 적재해 「OpenSSL version mismatch」 rc 255 — 이식봇 precheck 의
# `tailscale ssh` 가 그대로 죽었고 bash 의 libtinfo 경고가 모든 셸 호출에 찍혔다.
# 이 절은 **이 셸 env 그대로** 잰다(벗기면 고장을 못 본다). 항목은 사전
# `config/instances.yml` `host_env_*`, 판정은 코어 `instance.py host-env` 한 자리.
# `~/.bashrc` 는 저장소 밖 사용자 파일이라 자동 편집하지 않는다 — 고장이면 원인
# 경로와 처방을 `need` 로 낸다(CUDA·libtorch 경로는 무변경, conda lib 만 분리).
rw_phase "① 환경 점검·보충 · 1-10b 호스트 셸 환경"
HE_SEEN=0; HE_FAIL=0
while IFS=$'\t' read -r HE_ID HE_STATE HE_DETAIL; do
  [ -n "$HE_ID" ] || continue
  HE_SEEN=$((HE_SEEN + 1))
  case "$HE_STATE" in
    ok)   ok "호스트 셸 환경 $HE_ID — $HE_DETAIL" ;;
    fail) HE_FAIL=$((HE_FAIL + 1)); bad "호스트 셸 환경 $HE_ID 고장 — $HE_DETAIL" ;;
    *)    say "[INFO] 호스트 셸 환경 $HE_ID 계측 불가 — $HE_DETAIL" ;;
  esac
done <<HE_EOF
$(PYTHONPATH="$ROOT/scripts" python3 scripts/core/instance.py host-env 2>/dev/null)
HE_EOF
[ "$HE_FAIL" -gt 0 ] && need "호스트 셸 LD_LIBRARY_PATH 누출 — ~/.bashrc 의 conda env lib export 를 그 env 의 activate 훅(\$CONDA_PREFIX/etc/conda/activate.d/)으로 옮기고 새 셸에서 'bash scripts/reworker.sh' 재실행(CUDA·libtorch 경로는 그대로)"
[ "$HE_SEEN" -gt 0 ] || say "[INFO] 호스트 셸 환경 프로브 0건(config/instances.yml host_env_* 비어 있음 또는 실행 실패)"

# ═══ ② 상주 재기동 ═════════════════════════════════════════════════
step "② 상주 재기동"

# 2-1) 전 소유자 유령 정리(rescue_runner.sh 흡수). 2026-08-31 실측:
# 인스턴스 소유자가 바뀐 뒤 root 소유 Runner.Listener·runner_loop 가
# 남아 새 계정의 러너가 아무리 떠도 잡을 물지 못했다. 내 계정 소유가
# 아닌 것만 골라 죽인다 — 판정은 코어(lv_foreign_pids)가 하고, 패턴의
# 대괄호는 이 명령 자신이 자기 대상 목록에 드는 것을 막는다(P-0007).
#
# **범위는 이 인스턴스다(TASK-136 8)**: 유령의 정의가 "남의 계정"에서
# "**같은 자리**인데 남의 계정"으로 좁혀졌다. 2026-09-05 실측에서 host
# 셸의 `--instance vast1-c1` 실행이 이 절을 타고 host 러너를 죽였다 —
# 계정 축만 보면 다른 인스턴스의 정상 프로세스도 정리 대상이 된다.
# 자리를 못 가른 프로세스(소속 불명 + 남의 계정)는 죽이지 않고 **말만
# 한다**: 침묵하면 진짜 유령이 조용히 남고, 죽이면 남의 것을 죽인다.
if [ "$IN_JOB" = 1 ]; then
  ok "잡 안 — 유령 러너 정리 건너뜀"
elif [ "$ROOTOK" != 1 ]; then
  GH="$(lv_inst_foreign_pids "[R]unner.Listener run"; lv_inst_foreign_pids "runner_loo[p]\.sh")"
  if [ -n "$GH" ]; then
    need "root 권한 — 이 인스턴스 자리의 전 소유자 유령 러너($(echo "$GH" | tr '\n' ' '))를 지울 수 없다. root 셸에서 그 PID 를 kill"
  else
    ok "전 소유자 유령 러너 없음(이 인스턴스 범위)"
  fi
  UNSC="$(lv_unscoped_foreign_pids "[R]unner.Listener run"; lv_unscoped_foreign_pids "runner_loo[p]\.sh")"
  [ -n "$UNSC" ] && say "[INFO] 소속 불명 러너 프로세스 $(echo "$UNSC" | wc -w)개 — 이 인스턴스 자리가 아니어서 건드리지 않는다(PID: $(echo "$UNSC" | tr '\n' ' '))"
else
  GHOSTS="$(lv_inst_foreign_pids "[R]unner.Listener run"; lv_inst_foreign_pids "runner_loo[p]\.sh")"
  UNSC="$(lv_unscoped_foreign_pids "[R]unner.Listener run"; lv_unscoped_foreign_pids "runner_loo[p]\.sh")"
  [ -n "$UNSC" ] && say "[INFO] 소속 불명 러너 프로세스 $(echo "$UNSC" | wc -w)개 — 이 인스턴스 자리가 아니어서 건드리지 않는다(PID: $(echo "$UNSC" | tr '\n' ' '))"
  if [ -n "$GHOSTS" ]; then
    N=0
    for gp in $GHOSTS; do
      priv kill -TERM "$gp" 2>/dev/null && N=$((N+1))
    done
    sleep 2
    for gp in $GHOSTS; do
      kill -0 "$gp" 2>/dev/null && priv kill -KILL "$gp" 2>/dev/null || true
    done
    fix "전 소유자 유령 러너 ${N}개 정리(sudo, 이 인스턴스 범위)"
  else
    ok "전 소유자 유령 러너 없음(이 인스턴스 범위)"
  fi
fi

# 2-2) 상주물 5종 — **죽었거나 구판일 때만** 재기동한다.
#
# 종전에는 매 실행이 래퍼·데몬을 무조건 TERM 하고 새로 띄웠다. 안쪽
# 데몬만 죽이고 루프 래퍼를 두면 래퍼가 기동 시점의 구판 코드로 계속
# 도는 사고(2026-08-26 실측)를 막으려던 것인데, 그 대가로 **정상
# 상태에서도 매번 "복구 N"이 찍혔다** — 그 소음이 8-31 에 "[OK] 정상
# 7·복구 8"을 안심 신호로 읽게 만든 한 축이다. 이제 판정을 정확히
# 한다: 프로세스 시작 시각이 그 코드 파일의 수정 시각보다 이르면
# 구판(→ 재기동), 아니면 그대로 둔다(→ 무동작). 죽이는 순서는 그대로
# 래퍼 먼저·TERM(kill -9 금지 — trap 이 락 파일 정리를 보장).
# **생존·구판·종료 판정은 전부 이 인스턴스 범위다(TASK-136 8).** 기계
# 전체를 보면 두 방향으로 틀린다: 남의 루프를 자기 것으로 세어 죽은 채
# '가동(신판)'을 통보하고(교차 false-alive), 재기동 때 남의 상주물을
# 죽인다(교차 kill). 기동 명령이 저장소 상대경로를 쓰더라도 판정은
# 작업 디렉터리 축으로 갈리므로 구판 프로세스도 그대로 가려진다.
ensure_resident() {  # $1=이름 $2=래퍼패턴 $3=데몬패턴(없으면 "") $4=기동명령 $5..=기준파일
  local name="$1" wrap="$2" daemon="$3" start="$4"; shift 4
  local newest paths=() f up=0 stale=0 p
  for f in "$@"; do paths+=("$ROOT/$f"); done
  newest="$(lv_newest_mtime "${paths[@]}")"

  lv_inst_proc_alive "$wrap" && up=1
  if [ "$up" = 1 ]; then
    lv_inst_proc_started_before "$wrap" "$newest" && stale=1
    if [ -n "$daemon" ] && lv_inst_proc_started_before "$daemon" "$newest"; then stale=1; fi
  fi
  if [ "$up" = 1 ] && [ "$stale" = 0 ]; then
    ok "$name 가동(신판)"
    return 0
  fi

  if [ "$up" = 1 ]; then
    for p in $(lv_inst_pids "$wrap"); do kill -TERM "$p" 2>/dev/null || true; done
    if [ -n "$daemon" ]; then
      for p in $(lv_inst_pids "$daemon"); do kill -TERM "$p" 2>/dev/null || true; done
    fi
    sleep 2
  fi
  eval "$start"
  sleep 1
  if lv_inst_proc_alive "$wrap"; then
    if [ "$up" = 1 ]; then fix "$name 구판 → 신판 재기동"; else fix "$name 기동(죽어 있었음)"; fi
  else
    bad "$name 기동 실패"
  fi
}

if [ "$IN_JOB" = 1 ]; then
  ok "잡 안 — 러너 루프 래퍼·Runner.Listener 종료·재기동 건너뜀"
elif [ "$NO_RUNNER" = 1 ] || [ "$NO_RESIDENTS" = 1 ]; then
  ok "러너 루프 기동 보류(--no-runner/--no-residents — 이관 m6b 가 한다)"
elif [ ! -f scripts/runner_loop.sh ]; then
  bad "runner_loop.sh 없음 — 러너 루프 기동 불가"
else
  ensure_resident "Actions 러너 루프" "runner_loo[p]\.sh" "[R]unner.Listener run" \
    "setsid nohup bash '$ROOT/scripts/runner_loop.sh' >/dev/null 2>&1 &" \
    scripts/runner_loop.sh
fi

# 2-2b) **비-host 인스턴스의 러너 루프도 host 가 살린다(TASK-136 9).**
#
# 인스턴스를 만드는 자리(`--add-worker`)는 흔히 **잡 안**이고, 잡 안에서
# 띄운 상주물은 잡의 사후 정리를 넘기지 못한다(2026-09-05 실측: 잡 종료
# 직후 vast1-c1·c2 러너 offline). 그래서 등록과 기동을 나눈다 — 등록은
# 아무 데서나, 기동은 **잡 밖의 상시 주체**인 host 부활 주기가.
#
# 순회 대상의 진실은 디스크다: `$YAC_ROOT/*/.yac_instance` 가 곧 이 기계의
# 인스턴스 목록이다(커밋된 사전에 기계 고유 사실을 두지 않는다는 13-2
# 보강의 귀결 — 사전에 두면 clone 마다 서로를 덮어쓴다). 러너 없는 부류
# (control)와 host 자신은 대상이 아니고, 그 사실도 한 줄로 말한다.
if [ "$IN_JOB" = 1 ]; then
  ok "잡 안 — 다른 인스턴스 러너 루프 기동 건너뜀(잡 밖 host 주기가 한다)"
elif [ "$NO_RESIDENTS" = 1 ]; then
  ok "다른 인스턴스 러너 루프 기동 보류(--no-residents)"
elif [ "$IS_HOST" != 1 ]; then
  ok "비-host 인스턴스 — 다른 인스턴스 기동은 host 몫(대상 아님)"
else
  INST_SWEPT=0; INST_STARTED=0; INST_DOWN=""; INST_STALE=""
  while read -r INST_NAME INST_C INST_RD; do
    [ -n "$INST_NAME" ] || continue
    INST_SWEPT=$((INST_SWEPT + 1))
    # **트리 낙후 검사는 생존 판정보다 앞이다**(TASK-141 범위 3). 살아
    # 있는 루프가 낡은 트리를 물고 있는 것이 RUN-0007 ④ 의 상태였고,
    # 그것을 "이미 가동"으로 통과시키면 낙후가 영영 안 보인다.
    if ! inst_tree_sync "$INST_NAME" "$INST_C"; then
      INST_STALE="$INST_STALE $INST_NAME"
      continue
    fi
    inst_loop_alive "$INST_C" "$INST_RD" && continue
    if inst_loop_start "$INST_NAME" "$INST_C" "$INST_RD"; then
      INST_STARTED=$((INST_STARTED + 1))
    else
      INST_DOWN="$INST_DOWN $INST_NAME"
    fi
  done <<INST_SWEEP_EOF
$(inst_sweep_targets "$(basename "$ROOT")" "${YAC_INSTANCE_NAME:-}")
INST_SWEEP_EOF
  if [ "$INST_SWEPT" = 0 ]; then
    ok "다른 인스턴스 없음(이 기계는 단일 배치)"
  elif [ -n "$INST_STALE" ]; then
    # 낙후는 기동 실패와 **다른 사실**이라 따로 말한다(CR-0014) — 러너는
    # 멀쩡한데 코드가 옛것인 상태가 가장 조용한 고장이다.
    bad "인스턴스 트리 낙후(동기화 실패) — 기동 거부:$INST_STALE"
  elif [ -n "$INST_DOWN" ]; then
    bad "인스턴스 러너 루프 기동 실패 —$INST_DOWN"
  elif [ "$INST_STARTED" -gt 0 ]; then
    fix "인스턴스 러너 루프 ${INST_STARTED}개 기동(전수 $INST_SWEPT)"
  else
    ok "인스턴스 러너 루프 전수 가동(${INST_SWEPT}개)"
  fi
fi

# 리스너·메일 감시는 토큰·계정이 없으면 래퍼가 스스로 대기하므로 래퍼
# 생존만 본다(안쪽 데몬 부재는 결함이 아니다 — 데몬은 구판 판정에만 쓴다).
#
# **상주물 4종은 host 인스턴스 몫이다(TASK-136).** 한 기계 안의 인스턴스가
# 각자 리스너·워치독·체크포인트 루프를 띄우면 봇 큐 소비자가 여럿이 되고
# (13-6 불변식 위반) 체크포인트가 서로를 덮어쓴다. 러너 루프(위)만 인스턴스
# 마다 하나이고, 이 넷은 기계마다 하나다.
if [ "$NO_RESIDENTS" = 1 ]; then
  ok "상주 기동 보류(--no-residents — 명령봇·메일 감시·체크포인트 루프는 이관 m6b 가 한다)"
elif [ "$IS_HOST" != 1 ]; then
  ok "비-host 인스턴스 — 기계 유일 상주물 3종(리스너·메일 감시·체크포인트 루프)은 host 몫(대상 아님)"
else
  ensure_resident "명령봇 리스너" "listener_loo[p]\.sh" "cmd_listene[r]\.py" \
    "nohup bash '$ROOT/scripts/listener_loop.sh' >/dev/null 2>&1 &" \
    scripts/listener_loop.sh scripts/cmd_listener.py scripts/core/command_registry.py

  ensure_resident "메일 감시" "mail_watcher_loo[p]\.sh" "mail_watche[r]\.py" \
    "nohup bash '$ROOT/scripts/mail_watcher_loop.sh' >/dev/null 2>&1 &" \
    scripts/mail_watcher_loop.sh scripts/mail_watcher.py

  if [ -z "$(missing_cron)" ]; then
    ok "체크포인트 cron 등록됨"
  else
    ensure_resident "체크포인트 루프(cron 미등록 백업)" "ckpt_loo[p]\.sh" "" \
      "nohup bash '$ROOT/scripts/ckpt_loop.sh' >/dev/null 2>&1 &" \
      scripts/ckpt_loop.sh scripts/checkpoint.sh
  fi
fi

# 게이트웨이 워치독은 host 여부가 아니라 **관제 완장**을 따른다 — 감시
# 대상(관측 창 게이트웨이)이 완장을 단 인스턴스에만 서기 때문이다.
# 관제 인스턴스(vast1-rc, 부류 control)는 host 가 아니지만 이 워치독은
# 그쪽 몫이다(TASK-136 범위 5).
if [ "$NO_RESIDENTS" = 1 ]; then
  ok "게이트웨이 워치독 기동 보류(--no-residents)"
elif [ -f "$LV_OBSV_HOME/CONTROL_NODE" ]; then
  ensure_resident "게이트웨이 워치독" "gateway_watchdog_loo[p]\.sh" "" \
    "nohup bash '$ROOT/scripts/gateway_watchdog_loop.sh' >/dev/null 2>&1 &" \
    scripts/gateway_watchdog_loop.sh
else
  ok "관제 완장 아님 — 게이트웨이 워치독 비대상"
fi

# 2-3) 러너 자격·생존 확인
if [ "$NO_RUNNER" = 1 ]; then
  ok "러너 자격·생존 판정 보류(--no-runner)"
else
case "$(lv_runner_state)" in
  가동)   ok "Actions 러너 리스너 가동" ;;
  대기)   [ "$IN_JOB" = 1 ] && ok "러너 구성됨(잡 안 — 리스너 판정 생략)" \
                            || ok "러너 구성됨·리스너 기동 대기(runner_loop 가 곧 올림)" ;;
  *)      bad "러너 미구성($RD/.runner 없음) — 등록 필요" ;;
esac
fi
# 2-3b) 호스트 clone 리베이스 중단·UU 잔존(TASK-370 범위 1) — 판정만, 고침은 관제.
SYNC_LINE="$(lv_repo_sync_line)"
if [ -n "$SYNC_LINE" ]; then bad "$SYNC_LINE"; fi

# 2-4) 구판 /tmp 잔재 삭제(TASK-089b, 재기동 완료 후에만). 대상은 89-2
# 이전 구판 래퍼가 쓰던 고정 파일명뿐 — 글롭·디렉터리 삭제 금지.
OLD_TMP_FILES=(
  /tmp/runner.log /tmp/runner_loop.lock
  /tmp/cmd_listener.log /tmp/cmd_listener_loop.lock
  /tmp/mail_watcher.log /tmp/mail_watcher_loop.lock
  /tmp/ckpt.log /tmp/ckpt_loop.lock
)
removed=0
for f in "${OLD_TMP_FILES[@]}"; do
  [ -f "$f" ] && rm -f "$f" && removed=$((removed + 1))
done
[ "$removed" -gt 0 ] && fix "구판 /tmp 잔재 ${removed}개 삭제"

# ═══ ③ 관측(게이트웨이·터널·워치독) ═══════════════════════════════
step "③ 관측"

if [ ! -f "$LV_OBSV_HOME/CONTROL_NODE" ]; then
  ok "관제 완장 아님 — 관측 창 절 비대상"
elif [ "$IN_JOB" = 1 ]; then
  ok "잡 안 — 관측 창 재기동 건너뜀(판정만)"
else
  mkdir -p "$LV_RUN_DIR"
  if rw_wait timeout 300 bash scripts/obsv_boot.sh >> "$LV_RUN_DIR/reworker_boot.log" 2>&1; then
    say "obsv_boot 1회 완료(상세: $LV_RUN_DIR/reworker_boot.log)"
  else
    bad "obsv_boot 비정상 종료 — $LV_RUN_DIR/boot.log 확인"
  fi
fi

if [ -f "$LV_OBSV_HOME/CONTROL_NODE" ]; then
  G="$(lv_gateway_state)";  [ "$G" = 가동 ] && ok "관측 창 게이트웨이 가동" || bad "관측 창 게이트웨이 죽음"
  P="$(lv_gateway_probe)"
  case "$P" in
    200)    ok "관측 창 루프백 tools/list 200" ;;
    건너뜀) ok "관측 창 실응답 판정 건너뜀(토큰 미확보)" ;;
    *)      bad "관측 창 루프백 무응답(HTTP $P)" ;;
  esac
  F="$(lv_funnel_state)"
  case "$F" in
    가동)   ok "Tailscale Funnel 개통" ;;
    미가동) bad "Funnel 미개통 — 관리 콘솔 승인 또는 tailscaled 확인 필요" ;;
    *)      ok "Funnel 비대상(tailscale 부재·미합류) — 폴백 터널 사용" ;;
  esac
  [ "$(lv_tunnel_state)" = 확보 ] && ok "공개 주소 확보(값 미기재)" || bad "공개 주소 없음"
  [ "$(lv_watchdog_state)" = 가동 ] && ok "게이트웨이 워치독 가동" || bad "게이트웨이 워치독 죽음"
fi

# ═══ ④ 알씨 관제 거처(RC 세션) ════════════════════════════════════
step "④ 알씨 세션"

RC_BEFORE="$(lv_rc_bridge_state)"
say "판정(전): $(lv_rc_status_line)"
# 폴더 신뢰 사전 기입(TASK-684 범위 1) — 새 기계의 관제 창(rc·rc-<프로젝트>)이
# 'trust this folder' 화면에서 멈추지 않게, 창을 띄우는 rc_boot 와 **같은 원시**
# (`rc_account.py trust-fixup`)를 기동 전에 한 번 부른다(멱등 — 이미 참이면 인쇄 0).
if [ "$RC_BEFORE" != 대상아님 ]; then
  RC_TRUST="$(PYTHONPATH="$ROOT/scripts" python3 scripts/core/rc_account.py trust-fixup 2>&1)" || true
  case "$RC_TRUST" in
    "") ;;
    "[WARN]"*) bad "${RC_TRUST#\[WARN\] }" ;;
    *) fix "$RC_TRUST" ;;
  esac
fi
# 회전 대기(TASK-108) — 마커·턴 상한. 살아 있는 세션이어도 회전 사유가
# 있으면 기동 단일점을 불러야 하므로 생존 판정보다 **먼저** 본다.
RC_ROTATE=없음
[ "$RC_BEFORE" = 대상아님 ] || RC_ROTATE="$(lv_rc_rotate_state)"
if [ "$RC_ROTATE" != 없음 ]; then
  if [ "$IN_JOB" = 1 ]; then
    bad "알씨 세션 회전 대기($RC_ROTATE) — 잡 안이라 보류(관제·사람이 'bash scripts/rc_boot.sh')"
  else
    rw_wait timeout 180 bash scripts/rc_boot.sh >> "$LV_LIVE_DIR/rc_boot.log" 2>&1 || true
    if [ "$(lv_rc_rotate_state)" = 없음 ] && [ "$(lv_rc_bridge_state)" = 가동 ]; then
      fix "알씨 세션 회전($RC_ROTATE → 새 대화)"
      RC_BEFORE=가동
    else
      bad "알씨 세션 회전 실패($RC_ROTATE) — $LV_LIVE_DIR/rc_boot.log 확인"
      RC_BEFORE="$(lv_rc_bridge_state)"
    fi
  fi
fi
case "$RC_BEFORE" in
  대상아님)
    ok "알씨 세션 비대상($(lv_rc_target | sed 's/^비대상://'))" ;;
  가동)
    ok "알씨 세션 가동(다리 정상)" ;;
  *)
    if [ "$IN_JOB" = 1 ]; then
      # 살아 있는 관제 세션을 워커 잡이 죽이는 것은 권한 밖이다.
      bad "알씨 세션 $RC_BEFORE — 잡 안이라 재기동 보류(관제·사람이 'bash scripts/rc_boot.sh')"
    else
      rw_wait timeout 120 bash scripts/rc_boot.sh >> "$LV_LIVE_DIR/rc_boot.log" 2>&1 || true
      RC_AFTER="$(lv_rc_bridge_state)"
      if [ "$RC_AFTER" = 가동 ]; then
        fix "알씨 세션 복구($RC_BEFORE → 가동, 같은 세션 ID 로 --resume)"
      else
        bad "알씨 세션 $RC_AFTER — $LV_LIVE_DIR/rc_boot.log 확인"
      fi
    fi ;;
esac

# ═══ ⑤ 요약·통보 ═══════════════════════════════════════════════════
step "⑤ 요약"

# ⑤-지문) 자격 파일 되쓰기 감지(TASK-116c ③). ①-지문 이후(우리가 스스로
# 쓴 자리에서는 기준을 다시 잡았으므로) **설명되지 않는** 변화만 남는다.
# 값도 해시도 내지 않고 "바뀌었다"만 한 줄 알린다 — 이번처럼 조용히
# 원복되는 일을 다시는 무소음으로 넘기지 않는 것이 목적이다.
if [ -n "${CRED_STAMP:-}" ]; then
  CRED_FP_STATE="$(PYTHONPATH="$ROOT/scripts" python3 scripts/core/remote_cred.py \
    fingerprint --check "$CRED_STAMP" 2>/dev/null)"
  if [ "$CRED_FP_STATE" = changed ]; then
    echo "[WARN] ~/.git-credentials 가 이 실행 중 바뀌었다(되쓰기 의심 — 원격 URL 임베드 자격·다른 프로세스 확인, PROTOCOL 4-2). 값·지문은 출력하지 않는다"
    bad "자격 파일 되쓰기 감지 — 실행 중 ~/.git-credentials 변경됨(원천 확인 필요)"
  fi
fi
echo "=================== reworker 요약 ==================="
for m in "${OK[@]:-}";   do [ -n "$m" ] && echo "  정상: $m"; done
for m in "${FIX[@]:-}";  do [ -n "$m" ] && echo "  복구: $m"; done
for m in "${BAD[@]:-}";  do [ -n "$m" ] && echo "  잔여: $m"; done
for m in "${NEED[@]:-}"; do [ -n "$m" ] && echo "  입력: $m"; done
LKN="$(locked_bad_fold)"
if [ "$LKN" -gt 0 ] 2>/dev/null; then
  echo "  묶음: 위 잔여 중 ${LKN}건은 unlock 전 상태(보호 문서 암호문)에서 난 항목 — 저장소 키 전달·git-crypt unlock 뒤 재실행에서 다시 판정(ENROLL §2, TASK-582)"
fi

W="${WORKER:-worker}"
FIXNAMES="$(fix_names)"
NEEDNAMES="$(need_names)"
MSG="$(summary_line "$W")"
bash scripts/notify_telegram.sh "$MSG" >/dev/null 2>&1 || true
say "$MSG"

# --report: rescue_runner.sh 가 하던 진단 리포트 push(기본 off). 상시로
# 두면 허브가 로그로 불어나므로 사람이 "무슨 일이 있었는지 남겨라"고
# 할 때만 켠다. 커밋은 checkpoint.sh 경유(CLAUDE.md 15 — 직접 git 금지).
if [ "$REPORT" = 1 ]; then
  TS="$(date -u +%Y%m%dT%H%M%SZ)"
  R="rescue/${W}-$TS.log"
  mkdir -p rescue
  {
    echo "== reworker 리포트 $TS (uid=$(id -u) user=$(whoami) in_job=$IN_JOB)"
    echo "-- 요약"; echo "$MSG"
    for m in "${OK[@]:-}";   do [ -n "$m" ] && echo "  정상: $m"; done
    for m in "${FIX[@]:-}";  do [ -n "$m" ] && echo "  복구: $m"; done
    for m in "${BAD[@]:-}";  do [ -n "$m" ] && echo "  잔여: $m"; done
    for m in "${NEED[@]:-}"; do [ -n "$m" ] && echo "  입력: $m"; done
    echo "-- 프로세스"; pgrep -af 'Runner\.Listener|runner_loop|obsv_gateway|tailscaled' 2>/dev/null
    echo "-- 알씨"; lv_rc_status_line
    echo "-- crontab"; crontab -l 2>/dev/null || echo "crontab 없음"
  } > "$R"
  # `.gitignore` 의 `*.log` 에 걸리므로 강제 스테이징이 필요하다(옛
  # rescue_runner.sh 도 `git add -f` 였다). 커밋·push 는 직접 한다 —
  # checkpoint.sh 는 TASK-054 ③ 으로 "워킹트리를 쓸어 담아 허브에 [CKPT]
  # 커밋·push" 기능이 영구 폐지돼 이 파일을 밀어 주지 못한다(2026-08-31
  # 실측). CLAUDE.md 15 의 직접 git 금지는 `gate_escalations.log`
  # (자기 되먹임 루프)를 겨냥한 것이라 이 경로에는 적용되지 않는다.
  git add -f "$R" >/dev/null 2>&1 || true
  if git -c user.name="claude-$W" -c user.email="claude-$W@noreply" \
       commit -q -m "[BUS] reworker 리포트 $TS" -- "$R" >/dev/null 2>&1 \
     && git push -q >/dev/null 2>&1; then
    say "리포트 push: $R"
  else
    say "리포트 push 실패(로컬에만 남음): $R"
  fi
fi

# 비대화 모드에서 사람 입력이 남았으면 텔레그램 1통 + 비0(3) 종료.
# 위 절들은 전부 끝낸 뒤이므로 사람이 오기 전까지도 관측 창·러너는
# 살아 있다(부분 부활 > 전무). 이 종료 코드는 부팅 훅의 계약이다.
if [ "$NONINT" = 1 ] && [ ${#NEED[@]} -gt 0 ]; then
  bash scripts/notify_telegram.sh \
    "복원: 사람 입력 필요 — ${NEEDNAMES} (워커 $W, $(hostname 2>/dev/null || echo '?'))" >/dev/null 2>&1 || true
  exit 3
fi

# ═══ ⑥ 알씨 접속(TASK-238) ══════════════════════════════════════════
# 사용자 2026-09-24 16:39 "reworker 로 하던 명령을 … tmux attach -t rc
# 로그인 단계까지 포함해 명령 한 개로". 판정은 `rc_attach_decide` 한 자리
# (대화형·잡 밖·TTY·부팅 훅 아님·--no-attach 아님)이고, 창이 없으면 들어가지
# 않고 그 사실을 말한다(④ 절이 이미 사유를 냈다). Claude 로그인이 남았으면
# (1-9b need) 그 창에서 곧바로 하도록 한 줄을 앞에 찍는다. `exec` 라 이
# 뒤의 종료 코드는 tmux 의 것이다 — 사람이 앉은 터미널이라 요약 줄이 이미
# 결과를 말했고, 부팅 훅·잡의 종료 코드 계약(위 exit 3·아래 0/1)은 skip
# 갈래라 무변경이다.
rc_tty_probe   # RC_TTY — 명령 치환 밖에서 잰다(안에서는 -t 1 이 늘 거짓)
RC_ATTACH="$(rc_attach_decide "$RC_TTY")"
case "$RC_ATTACH" in
  attach|switch)
    RC_TMUX_SESSION="$(lv_rc_cfg tmux_session rc)"
    RC_TMUX_BIN="$(lv_tmux_bin)"
    if ! lv_rc_tmux_alive; then
      say "알씨 창(tmux $RC_TMUX_SESSION) 없음 — 접속 생략(④ 절 판정 참조)"
    else
      if printf '%s\n' "${NEED[@]:-}" | grep -q '^Claude 로그인'; then
        say "알씨 창에 Claude 로그인이 남아 있다 — 들어가서 Enter·브라우저 로그인·Ctrl+b d(로그인 뒤 reworker 재실행은 불요)"
      fi
      say "요약 끝 — 알씨 창(tmux $RC_TMUX_SESSION)으로 들어간다(나오기 Ctrl+b d · 끄려면 --no-attach)"
      if [ "$RC_ATTACH" = switch ]; then
        exec "$RC_TMUX_BIN" switch-client -t "$(lv_tmux_exact "$RC_TMUX_SESSION")"
      else
        exec "$RC_TMUX_BIN" attach -t "$(lv_tmux_exact "$RC_TMUX_SESSION")"
      fi
    fi ;;
  *)
    say "알씨 접속 생략(${RC_ATTACH#skip:})" ;;
esac

if [ ${#BAD[@]} -eq 0 ]; then
  say "완료 — 잔여 문제 없음"
  exit 0
fi
say "잔여 문제 ${#BAD[@]}건 — 위 요약 확인"
exit 1
