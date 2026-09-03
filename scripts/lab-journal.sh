#!/usr/bin/env bash
# Forge lab journal: records every command you type in THIS terminal, with a
# timestamp and its exit code, so the phase-done review can see what actually
# happened (retries, errors, detours). The log never leaves your machine: it
# lives in .journal/<phase>.log at the repo root, which is gitignored.
#
# Usage (source it, do not execute it):
#   source scripts/lab-journal.sh start phase-1
#   source scripts/lab-journal.sh stop
#
# Only the terminal you source it in is recorded. Open a second terminal for a
# lab step and its commands are not in the log.
#
# How it works: a DEBUG trap flags the first command after each prompt, and a
# prompt hook writes the line once the exit code exists. The trap is installed
# and removed at the next prompt by one-shot functions with the trace
# attribute, because bash hides the current DEBUG trap from a sourced file and
# from ordinary functions, and discards changes they make to it.
#
# Caveats: a command that HISTCONTROL keeps out of history (a leading space
# with ignorespace) is logged with the previous history entry's text. Prompt
# hooks that read PIPESTATUS see the journal's, not your pipeline's.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "This script must be sourced: source scripts/lab-journal.sh start phase-N" >&2
  exit 1
fi

__forge_journal_usage() { echo "usage: source scripts/lab-journal.sh start phase-N | stop" >&2; }

# DEBUG trap. Only the first command after a prompt counts: the arm hook sets
# the flag right before the prompt, and the first command clears it. The trap
# also fires for the prompt hook itself, which must not count (an empty line
# leaves the flag armed until then).
__forge_journal_debug() {
  if [[ "${__forge_journal_armed:-0}" == 1 && "$BASH_COMMAND" != __forge_journal ]]; then
    __forge_journal_armed=0
    __forge_journal_pending=1
  fi
  : "$1"
}

# Prompt hook, first in PROMPT_COMMAND so $? is the last command's exit code.
# history 1 (not fc) because fc skips the newest entry from inside a prompt hook.
__forge_journal() {
  local status=$?
  __forge_journal_armed=0
  if [[ "${__forge_journal_pending:-0}" == 1 ]]; then
    __forge_journal_pending=0
    local entry cmd
    entry=$(HISTTIMEFORMAT= history 1)
    if [[ $entry =~ ^[[:space:]]*[0-9]+[[:space:]]+(.*)$ ]]; then cmd=${BASH_REMATCH[1]}; else cmd=$entry; fi
    cmd=${cmd//$'\n'/\\n}
    printf '%s\t%s\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$status" "$cmd" >> "$FORGE_JOURNAL_FILE"
  fi
  return $status
}

# Arm hook, last in PROMPT_COMMAND.
__forge_journal_arm() { __forge_journal_armed=1; }

# PROMPT_COMMAND helpers, for its string and array forms.
__forge_journal_pc_is_array() { [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; }
__forge_journal_pc_add() {
  local where=$1 name=$2
  if __forge_journal_pc_is_array; then
    if [[ $where == first ]]; then PROMPT_COMMAND=("$name" "${PROMPT_COMMAND[@]}"); else PROMPT_COMMAND+=("$name"); fi
  elif [[ $where == first ]]; then
    PROMPT_COMMAND="$name${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
  else
    PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND;}$name"
  fi
}
__forge_journal_pc_remove() {
  local name=$1
  if __forge_journal_pc_is_array; then
    local kept=() part
    for part in "${PROMPT_COMMAND[@]}"; do [[ "$part" == "$name" ]] || kept+=("$part"); done
    PROMPT_COMMAND=("${kept[@]}")
  else
    PROMPT_COMMAND=";$PROMPT_COMMAND;"
    PROMPT_COMMAND=${PROMPT_COMMAND//";$name;"/;}
    PROMPT_COMMAND=${PROMPT_COMMAND#;}; PROMPT_COMMAND=${PROMPT_COMMAND%;}
  fi
}

# One-shot installers, run by PROMPT_COMMAND at the next prompt. The trace
# attribute (declare -ft) lets them see and change the DEBUG trap. Each removes
# itself when done.
__forge_journal_install() {
  __forge_journal_prev_debug=""
  if [[ -n "$(trap -p DEBUG)" ]]; then
    eval "set -- $(trap -p DEBUG)"; __forge_journal_prev_debug=$3
  fi
  trap "__forge_journal_debug \"\$_\"${__forge_journal_prev_debug:+; $__forge_journal_prev_debug}" DEBUG
  __forge_journal_pc_remove __forge_journal_install
}
__forge_journal_uninstall() {
  if [[ -n "${__forge_journal_prev_debug:-}" ]]; then trap "$__forge_journal_prev_debug" DEBUG; else trap - DEBUG; fi
  unset __forge_journal_prev_debug
  __forge_journal_pc_remove __forge_journal_uninstall
}
declare -ft __forge_journal_install __forge_journal_uninstall

__forge_journal_start() {
  local phase=$1
  if [[ -z "$phase" ]]; then __forge_journal_usage; return 1; fi
  if [[ -n "${FORGE_JOURNAL_FILE:-}" ]]; then
    echo "already recording to $FORGE_JOURNAL_FILE; run: source scripts/lab-journal.sh stop" >&2
    return 1
  fi
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  mkdir -p "$root/.journal"
  FORGE_JOURNAL_FILE="$root/.journal/$phase.log"
  __forge_journal_pending=0
  __forge_journal_armed=0
  __forge_journal_pc_remove __forge_journal_uninstall
  __forge_journal_pc_add first __forge_journal
  __forge_journal_pc_add last __forge_journal_install
  __forge_journal_pc_add last __forge_journal_arm
  printf '%s\tstart\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$phase" >> "$FORGE_JOURNAL_FILE"
  echo "journal on: $FORGE_JOURNAL_FILE"
  echo "stop with: source scripts/lab-journal.sh stop"
}

__forge_journal_stop() {
  if [[ -z "${FORGE_JOURNAL_FILE:-}" ]]; then echo "journal is not running" >&2; return 1; fi
  printf '%s\tstop\t\n' "$(date +%Y-%m-%dT%H:%M:%S)" >> "$FORGE_JOURNAL_FILE"
  __forge_journal_pc_remove __forge_journal
  __forge_journal_pc_remove __forge_journal_arm
  __forge_journal_pc_remove __forge_journal_install
  __forge_journal_pc_add last __forge_journal_uninstall
  echo "journal off: $FORGE_JOURNAL_FILE"
  unset FORGE_JOURNAL_FILE __forge_journal_pending __forge_journal_armed
}

case "${1:-}" in
  start) __forge_journal_start "${2:-}" ;;
  stop) __forge_journal_stop ;;
  *) __forge_journal_usage; return 1 ;;
esac
