#!/usr/bin/env bash
# scripts/test_validator.sh
# Tests scripts/test_framework/validate_gdscript.sh against a stub Godot binary,
# with no real editor and no change to the repo:
#   - a missing class cache is warmed first, and a failed warm-up exits 2 before
#     either pass;
#   - pass 2 is skipped aloud when its script is absent, and a pass 2 that reports
#     neither PASS: nor FAIL: exits 2;
#   - a pass 1 exit of 126 or 127 exits 2, and any other exit code is only logged;
#   - an error followed by more output than a pipe buffer still fails.
#
# Every case runs in a temp project with no run_units_cold.sh, as an extension
# author's has none, so a cold case also proves the validator finds its warm-up
# from its own path.
#
# Usage: bash scripts/test_validator.sh   (from anywhere)
# Exit 0 = all passed, 1 = a check failed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="${REPO_ROOT}/scripts/test_framework/validate_gdscript.sh"
CACHE_PATH=".godot/global_script_class_cache.cfg"
RUNNER_PATH="scripts/test_framework/check_all_scripts.gd"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-validator.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0

check() {
  local label="$1"
  shift
  if "$@"; then
    PASSED=$((PASSED + 1))
    echo "  ok    ${label}"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL  ${label}"
  fi
}

equals() { [[ "$1" == "$2" ]]; }
contains() { [[ "$1" == *"$2"* ]]; }
lacks() { [[ "$1" != *"$2"* ]]; }
file_exists() { [[ -f "$1" ]]; }

# The stub tells the validator's three kinds of run apart by their arguments and
# appends each to STUB_CALLS. STUB_WARMUP, STUB_PASS1 and STUB_PASS2 pick its
# behaviour. Pass 2 fails while the cache is missing and when its script is absent,
# as Godot 4.3 does.
STUB="${WORK}/godot-stub.sh"
cat > "${STUB}" <<'STUB_BODY'
#!/usr/bin/env bash
noise() {
  head -c 300000 /dev/zero | tr '\0' 'x' | fold -w 100
  echo ''
}

case " $* " in
  *" --script "*) run=pass2 ;;
  *" --quit-after "*) run=pass1 ;;
  *) run=warmup ;;
esac
echo "${run}" >> "${STUB_CALLS}"

case "${run}" in
  warmup)
    [[ "${STUB_WARMUP:-write}" == "die" ]] && exit 1
    mkdir -p .godot
    : > .godot/global_script_class_cache.cfg
    ;;
  pass1)
    case "${STUB_PASS1:-clean}" in
      error_then_noise)
        echo 'SCRIPT ERROR: Parse Error: seeded'
        noise
        ;;
      exit:*) exit "${STUB_PASS1#exit:}" ;;
      *) echo 'editor boot' ;;
    esac
    ;;
  pass2)
    if [[ ! -f "${*: -1}" ]]; then
      echo "ERROR: Can't load script: ${*: -1}"
      exit 1
    fi
    if [[ ! -f .godot/global_script_class_cache.cfg ]]; then
      echo 'FAIL: 66 script(s) have errors'
      exit 1
    fi
    case "${STUB_PASS2:-pass}" in
      fail)
        echo 'FAIL: 1 script(s) have errors'
        exit 1
        ;;
      fail_then_noise)
        echo 'FAIL: 1 script(s) have errors'
        noise
        exit 1
        ;;
      error_then_noise)
        echo 'SCRIPT ERROR: Parse Error: seeded'
        noise
        echo 'PASS: all loadable scripts are valid'
        ;;
      crash) exit 139 ;;
      no_summary) echo 'check_all_scripts: scanning 169 .gd files' ;;
      indented_fail) echo '  FAIL: res://x.gd' ;;
      error_no_summary)
        echo 'SCRIPT ERROR: Parse Error: seeded'
        exit 1
        ;;
      *) echo 'PASS: all loadable scripts are valid' ;;
    esac
    ;;
esac
STUB_BODY
chmod +x "${STUB}"

unset GODOT_QUIT_AFTER GODOT_VALIDATE_TIMEOUT GODOT_WARM_ONLY SKIP_SCRIPT_RUNNER STUB_WARMUP STUB_PASS1 STUB_PASS2
export GODOT_BIN="${STUB}"
export STUB_CALLS="${WORK}/calls.log"

# Makes a temp project and sets PROJECT. Options: "cold" leaves out the class cache,
# "no-runner" leaves out pass 2's script.
new_project() {
  local option cache="yes" runner="yes"
  for option in "$@"; do
    case "${option}" in
      cold) cache="no" ;;
      no-runner) runner="no" ;;
    esac
  done
  PROJECT="$(mktemp -d "${WORK}/project.XXXXXX")"
  : > "${PROJECT}/project.godot"
  if [[ "${cache}" == "yes" ]]; then
    mkdir -p "${PROJECT}/.godot"
    : > "${PROJECT}/${CACHE_PATH}"
  fi
  if [[ "${runner}" == "yes" ]]; then
    mkdir -p "${PROJECT}/$(dirname "${RUNNER_PATH}")"
    : > "${PROJECT}/${RUNNER_PATH}"
  fi
}

# Runs the validator in PROJECT and sets OUT, STATUS and CALLS (the stub's runs, in
# order, space-separated). The first argument is "keep" or "unset" for GODOT_BIN in
# the validator's environment; the rest go to the validator.
run_validator_with_bin() {
  local bin_env="$1"
  shift
  : > "${STUB_CALLS}"
  OUT="$(
    cd "${PROJECT}"
    [[ "${bin_env}" == "unset" ]] && unset GODOT_BIN
    bash "${VALIDATOR}" "$@" 2>&1
  )" && STATUS=0 || STATUS=$?
  CALLS="$(tr '\n' ' ' < "${STUB_CALLS}")"
}

run_validator() { run_validator_with_bin keep "$@"; }

# Runs with GODOT_BIN absent from the environment, so a binary given as the first
# argument reaches the warm-up only through the validator's own hand-down.
run_validator_no_bin_env() { run_validator_with_bin unset "$@"; }

echo "── the plain run ──"
new_project
run_validator
check "warm tree: exits 0" equals "${STATUS}" "0"
check "warm tree: reads RESULT: PASS" contains "${OUT}" "RESULT: PASS"
check "warm tree: no warm-up, then both passes" equals "${CALLS}" "pass1 pass2 "

echo "── the warm-up ──"
new_project cold
run_validator_no_bin_env "${STUB}"
check "cold tree, binary as the first argument: exits 0" equals "${STATUS}" "0"
check "cold tree: warm-up, then both passes" equals "${CALLS}" "warmup pass1 pass2 "
check "cold tree: the warm-up reports its cache" contains "${OUT}" "cache written: yes"
check "cold tree: the cache exists" file_exists "${PROJECT}/${CACHE_PATH}"
new_project cold
STUB_WARMUP=die run_validator
check "failed warm-up: exits 2" equals "${STATUS}" "2"
check "failed warm-up: reports no cache" contains "${OUT}" "cache written: no"
check "failed warm-up: neither pass runs" lacks "${CALLS}" "pass"

echo "── pass 2 ──"
new_project no-runner
run_validator
check "script absent: exits 0" equals "${STATUS}" "0"
check "script absent: says pass 2 was skipped" contains "${OUT}" "Pass 2: Skipped"
check "script absent: pass 2 never runs" equals "${CALLS}" "pass1 "
new_project no-runner
STUB_PASS1=error_then_noise run_validator
check "script absent: pass 1's error still exits 1" equals "${STATUS}" "1"
for mode in crash no_summary indented_fail error_no_summary; do
  new_project
  STUB_PASS2="${mode}" run_validator
  check "${mode}: exits 2" equals "${STATUS}" "2"
  check "${mode}: does not read RESULT: PASS" lacks "${OUT}" "RESULT: PASS"
  check "${mode}: pass 2 is not retried" equals "${CALLS}" "pass1 pass2 "
done
new_project
STUB_PASS2=fail run_validator
check "a FAIL: line: exits 1" equals "${STATUS}" "1"
new_project
SKIP_SCRIPT_RUNNER=1 run_validator
check "SKIP_SCRIPT_RUNNER=1: exits 0" equals "${STATUS}" "0"
check "SKIP_SCRIPT_RUNNER=1: pass 2 never runs" equals "${CALLS}" "pass1 "

echo "── pass 1's exit code ──"
for code in 126 127; do
  new_project
  STUB_PASS1="exit:${code}" run_validator
  check "exit ${code}: exits 2" equals "${STATUS}" "2"
  check "exit ${code}: does not read RESULT: PASS" lacks "${OUT}" "RESULT: PASS"
done
for code in 134 139; do
  new_project
  STUB_PASS1="exit:${code}" run_validator
  check "exit ${code}: exits 0" equals "${STATUS}" "0"
  check "exit ${code}: printed in the log" contains "${OUT}" "Pass 1 exit code: ${code}"
done
# Pass 2's script is absent in the cases a warm pass 1 decides alone, so the exit 2
# comes from the 126/127 rule and not from pass 2's no-verdict check.
new_project no-runner
GODOT_BIN="${WORK}/no-such-godot" run_validator
check "missing binary: exits 2" equals "${STATUS}" "2"
check "missing binary: does not read RESULT: PASS" lacks "${OUT}" "RESULT: PASS"
for tree in warm cold; do
  if [[ "${tree}" == "warm" ]]; then
    new_project warm no-runner
  else
    new_project cold
  fi
  # Run as the binary, the file lacks an execute bit and exits 126 on Linux; on Windows
  # every file counts as executable, so its body supplies the same exit.
  echo 'exit 126' > "${PROJECT}/some_script.gd"
  run_validator_no_bin_env "${PROJECT}/some_script.gd"
  check "a .gd first argument, ${tree} tree: exits 2" equals "${STATUS}" "2"
  check "a .gd first argument, ${tree} tree: does not read RESULT: PASS" lacks "${OUT}" "RESULT: PASS"
done
new_project
: > "${PROJECT}/some_script.gd"
run_validator "${PROJECT}/some_script.gd"
check "a .gd first argument beside GODOT_BIN: exits 0" equals "${STATUS}" "0"
check "a .gd first argument beside GODOT_BIN: reads RESULT: PASS" contains "${OUT}" "RESULT: PASS"
check "a .gd first argument beside GODOT_BIN: the argument is ignored" equals "${CALLS}" "pass1 pass2 "

echo "── an error ahead of more than a pipe buffer ──"
new_project
STUB_PASS1=error_then_noise run_validator
check "pass 1 error: exits 1" equals "${STATUS}" "1"
new_project
STUB_PASS2=fail_then_noise run_validator
check "pass 2 FAIL: line: exits 1" equals "${STATUS}" "1"
new_project
STUB_PASS2=error_then_noise run_validator
check "pass 2 error beside a PASS: line: exits 1" equals "${STATUS}" "1"

echo ""
if [[ ${FAILED} -eq 0 ]]; then
  echo "PASS: ${PASSED} checks"
  exit 0
fi
echo "FAIL: ${FAILED} of $((PASSED + FAILED)) checks failed"
exit 1
