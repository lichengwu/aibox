# ---------- JSON emission (bash 3.2, no jq/python) ----------
# Machine-readable output is a first-class surface for a manager whose main
# consumers are scripts, timers and CI (`aibox status --json`,
# `aibox check --json`). These helpers keep the escaping in ONE place; callers
# own the shape. stdout carries JSON only — colors/log lines go to stderr.

# Escape a string for a JSON string literal (quotes, backslashes, control chars).
json_escape() { # $1 = raw text → escaped text (no surrounding quotes)
  # LC_ALL=C on purpose: under a non-UTF-8 locale (CI macOS runs bats with C)
  # bash's substring expansion counts BYTES, so a multibyte character would be
  # sliced into invalid UTF-8 and the JSON would not parse. Byte-wise iteration
  # passes any byte >= 0x80 through untouched — valid UTF-8 either way.
  local LC_ALL=C
  local s="${1:-}" out="" i=0 c ord
  while [ "${i}" -lt "${#s}" ]; do
    c="${s:${i}:1}"
    case "${c}" in
    '"') out="${out}\\\"" ;;
    '\') out="${out}\\\\" ;;
    $'\n') out="${out}\\n" ;;
    $'\r') out="${out}\\r" ;;
    $'\t') out="${out}\\t" ;;
    *)
      # Any OTHER control byte (ESC from brew/apt colour output, BEL, …) is
      # illegal raw inside a JSON string — live-caught: the macOS preflight
      # auto-install of docker injected ESC and the whole --json envelope
      # stopped parsing. Escape every control byte as \uXXXX (LC_ALL=C above
      # makes c exactly one byte, so the ordinal is the byte value).
      ord="$(printf '%d' "'${c}" 2>/dev/null)" || ord=""
      case "${ord}" in
      '' | *[!0-9]*) out="${out}${c}" ;;
      *)
        if [ "${ord}" -lt 32 ]; then
          out="${out}\u$(printf '%04x' "${ord}")"
        else
          out="${out}${c}"
        fi ;;
      esac ;;
    esac
    i=$(( i + 1 ))
  done
  printf '%s' "${out}"
}

json_str() { # $1 = raw text → "quoted JSON string"
  printf '"%s"' "$(json_escape "${1:-}")"
}

# Key: value pairs for scalars — json_kv name "string" / json_num name 3
json_kv_str() { printf '%s: %s' "$(json_str "${1:-}")" "$(json_str "${2:-}")"; }
json_kv_num() { printf '%s: %s' "$(json_str "${1:-}")" "${2:-0}"; }
json_kv_bool() {
  local b="false"
  case "${2:-}" in 1 | true | yes | ok) b="true" ;; esac
  printf '%s: %s' "$(json_str "${1:-}")" "${b}"
}
# Array of strings: json_arr name a b c  → "name": ["a","b"]
json_arr() { # $1 = key, rest = items
  local key="$1" first=1 item
  shift
  printf '%s: [' "$(json_str "${key}")"
  for item in "$@"; do
    [ "${first}" = "1" ] || printf ', '
    printf '%s' "$(json_str "${item}")"
    first=0
  done
  printf ']'
}
