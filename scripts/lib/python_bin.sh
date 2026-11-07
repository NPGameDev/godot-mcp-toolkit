# shellcheck shell=bash
#
# scripts/lib/python_bin.sh: the Python 3 the test harnesses run.
#
# Sourced, never run. Runs under bash on Linux, macOS and Windows (Git Bash).
#
#   ut_python_bin                       print the path of a Python 3: UT_PYTHON's, or
#                                       the first on the PATH outside a WindowsApps
#                                       folder; or say why there is none and fail
#   ut_in_windows_apps <path>           whether <path> lies in a WindowsApps folder
#   ut_is_python3 <path>                whether <path> runs Python 3; runs it

# Whether a resolved path lies in a WindowsApps folder, in any letter case and with
# either slash. Matched with globs alone, so it needs no command from the PATH.
ut_in_windows_apps() {
  local path="${1//\\//}"
  [[ "${path}" == *[Ww][Ii][Nn][Dd][Oo][Ww][Ss][Aa][Pp][Pp][Ss]/* ]]
}

ut_is_python3() {
  "$1" -c 'import sys; sys.exit(sys.version_info[0] != 3)' 2>/dev/null
}

# On Windows `python3` and `python` can be the Microsoft Store's app-execution
# aliases in a WindowsApps folder. With no Python installed, running one, even for a
# version check, downloads and installs a Python and registers it for the user, so
# every candidate is resolved to its path first and one in WindowsApps is never run.
# UT_PYTHON names the interpreter outright, and a wrong one fails rather than falling
# back to the PATH. Prints the interpreter's path. The Windows runner names Python 3
# `python`.
ut_python_bin() {
  local why='python3 and python in a WindowsApps folder are skipped without being run: they can be the Microsoft Store aliases, and running one can install a Python'
  if [[ -n "${UT_PYTHON:-}" ]]; then
    local pinned
    pinned="$(type -P -- "${UT_PYTHON}")"
    if [[ -z "${pinned}" ]]; then
      echo "ERROR: UT_PYTHON=${UT_PYTHON} is not a command or an executable file" >&2
      return 1
    fi
    if ut_in_windows_apps "${pinned}"; then
      echo "ERROR: UT_PYTHON=${UT_PYTHON} resolves to ${pinned}; ${why}. Set UT_PYTHON to the interpreter itself" >&2
      return 1
    fi
    if ! ut_is_python3 "${pinned}"; then
      echo "ERROR: UT_PYTHON=${UT_PYTHON} does not run Python 3" >&2
      return 1
    fi
    echo "${pinned}"
    return 0
  fi
  local name path
  for name in python3 python; do
    while IFS= read -r path; do
      [[ -n "${path}" ]] || continue
      ut_in_windows_apps "${path}" && continue
      if ut_is_python3 "${path}"; then
        echo "${path}"
        return 0
      fi
    done <<< "$(type -aP -- "${name}")"
  done
  echo "ERROR: no Python 3 found on the PATH; set UT_PYTHON to a Python 3 interpreter. ${why}" >&2
  return 1
}
