# ---------- module.yaml readers (ONE implementation of the dialect) ----------
# The registry dialect is a tiny YAML subset (scalars, flat lists, two-space
# maps) and it used to be parsed in five places — the manager's registry loader,
# three status readers, the validator, and seven module libs. Every copy was
# a place where the dialect's semantics could drift (and the validator's copy was
# never even defined: parse_one died silently, so its cross-module rules were
# no-ops). Readers:
#   parse_yaml_module_stdin <mu>   registry vars for a whole file (manager/validator)
#   meta_field <yaml> <field>      scalar value, else flat list joined by spaces
#   meta_map_value <yaml> <k> <c>  two-space map member (e.g. usage.<action>)
#   meta_version <yaml>            the version field (module libs / display)

# Capability version of the manager↔module CONTRACT SURFACE: the status_info
# keys, the residue: stanza, the upgrade: stanza and the hook behaviour. Bump it
# on any RENAME/REMOVAL in that surface (additions do not need a bump); a module
# declares the version it targets via module_iface in module.yaml. The manager
# exports this to hooks and warns when a module targets something newer.
AIBOX_IFACE_SUPPORTED="1"
#
parse_yaml_module_stdin() {
  awk -v NAME="$1" '
    BEGIN { parent=""; subparent=""; listkey=""; listval="" }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      content=$0
      while (substr(content,1,1)==" ") content=substr(content,2)
      indent=length($0)-length(content)
      if (substr(content,1,1)=="-") {
        item=substr(content,2); sub(/^ +/, "", item)
        if (listkey=="") listkey=(subparent!="" ? NAME"_"parent"_"subparent : NAME"_"parent)
        listval=(listval=="" ? "" : listval" ") stripq(item)
        next
      }
      colon=index(content,":")
      if (colon>0) {
        k=substr(content,1,colon-1); v=substr(content,colon+1)
        sub(/^ +/, "", v); sub(/ +$/, "", v)
        if (listkey!="") { printvar(listkey,listval); listkey=""; listval="" }
        if (indent==0) {
          parent=""; subparent=""
          if (v=="") parent=k; else printvar(NAME"_"k, stripq(v))
        } else {
          if (v=="") subparent=k
          else if (parent=="hooks") printvar(NAME"_"k, stripq(v))  # hooks.install -> _install (module_field compat)
          else if (parent!="") printvar(NAME"_"parent"_"k, stripq(v))
        }
      }
    }
    END { if (listkey!="") printvar(listkey,listval) }
    function esc(s,   r) { r=s; gsub(/\\/, "\\\\", r); gsub(/"/, "\\\"", r); gsub(/\$/, "\\$", r); gsub(/`/, "\\`", r); return r }
    function printvar(k,v) { gsub(/-/, "_", k); printf "AIBOX_MODULE_%s=\"%s\"\n", k, esc(v) }
    function stripq(s) {
      if (substr(s,1,1)=="\"" && substr(s,length(s),1)=="\"") return substr(s,2,length(s)-2)
      return s
    }
  '
}

# Scalar field value, else the flat list under it joined by spaces ("" when the
# file or the field is absent — callers decide the fallback: registry, installed
# marker, or nothing).
meta_field() { # $1 = module.yaml path, $2 = field
  local f="${1:-}" field="${2:-}" v
  [ -n "${f}" ] && [ -n "${field}" ] && [ -f "${f}" ] || return 0
  v="$(sed -n "s/^${field}: *\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "${f}" 2>/dev/null | head -1)"
  [ -n "${v}" ] && { printf '%s' "${v}"; return 0; }
  awk -v f="${field}" '
    $0 == f ":" { inl = 1; next }
    inl && /^[ ]+- / {
      sub(/^[ ]+- /, ""); gsub(/^"|"$/, "")
      printf "%s%s", sep, $0; sep = " "; next
    }
    inl { inl = 0 }
  ' "${f}" 2>/dev/null
}

# Value of a two-space map member: `usage:` → `  <action>: "text"`.
meta_map_value() { # $1 = module.yaml path, $2 = parent key, $3 = member key
  local f="${1:-}" pk="${2:-}" ck="${3:-}"
  [ -n "${f}" ] && [ -n "${pk}" ] && [ -n "${ck}" ] && [ -f "${f}" ] || return 0
  awk -v pk="${pk}" -v ck="${ck}" '
    $0 == pk ":" { inb = 1; next }
    inb && /^[^ ]/ { inb = 0 }
    inb {
      line = $0; sub(/^[ ]+/, "", line)
      if (index(line, ck ":") == 1) {
        v = substr(line, length(ck) + 2); sub(/^ +/, "", v); gsub(/^"|"$/, "", v)
        print v; exit
      }
    }
  ' "${f}" 2>/dev/null
}

# The version field — the ONE reader for module libs (the manager injects
# AIBOX_MODULE_VERSION on dispatch, so this covers direct execution).
meta_version() { # $1 = module.yaml path
  meta_field "${1:-}" version
}

# A nested child value under a top-level parent: scalar (`parent:` → `  child: v`)
# or the flat list under it (`parent:` → `  child:` → `    - item`), joined.
meta_sub_field() { # $1 = module.yaml path, $2 = parent key, $3 = child key
  local f="${1:-}" pk="${2:-}" ck="${3:-}"
  [ -n "${f}" ] && [ -n "${pk}" ] && [ -n "${ck}" ] && [ -f "${f}" ] || return 0
  awk -v pk="${pk}" -v ck="${ck}" '
    $0 == pk ":" { inb = 1; next }
    inb && /^[^ ]/ { inb = 0 }
    inb {
      line = $0; sub(/^[ ]+/, "", line)
      if (line == ck ":") { inl = 1; next }
      if (inl && line ~ /^- /) {
        sub(/^- /, "", line); gsub(/^"|"$/, "", line)
        printf "%s%s", sep, line; sep = " "; next
      }
      if (index(line, ck ":") == 1) {
        v = substr(line, length(ck) + 2); sub(/^ +/, "", v); gsub(/^"|"$/, "", v)
        print v; exit
      }
      inl = 0
    }
  ' "${f}" 2>/dev/null
}
