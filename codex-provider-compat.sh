#!/bin/sh

set -u
umask 077

TOOL_VERSION=0.1.0
PATCH_ID=responses-lite-standard-tools
MAX_CATALOG_BYTES=5242880
MIN_CATALOG_MODELS=8
MIN_NON_TARGET_MODELS=5
TARGETS='gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna'
EX_OK=0
EX_ERROR=1
EX_NOT_APPLICABLE=2
EX_UNSAFE=3
EX_STALE=4
EX_NETWORK=5

info() { printf '%s\n' "[provider-compat] $*"; }
warn() { printf '%s\n' "[provider-compat] WARNING: $*" >&2; }

TMP_BASE=${TMPDIR:-/tmp}
TMP_ROOT=$(/usr/bin/mktemp -d "$TMP_BASE/codex-provider-compat.XXXXXX") || exit 1
LOCK_DIR=
LOCK_NONCE=
TX_PATH=
SIGNALLED=0
RECOVERY_PRESERVE_CONFIG=0

absolute_path() {
  mode=${2:-strict}
  /usr/bin/osascript -l JavaScript - "$1" "$mode" <<'JXA'
ObjC.import('Foundation');
function symlinkDestination(p) {
  let e = Ref();
  let d = $.NSFileManager.defaultManager.destinationOfSymbolicLinkAtPathError($(p), e);
  return d ? d.js : null;
}
function run(a) {
  if (!a.length || !a[0]) throw Error('empty path');
  let mode = a[1] || 'strict';
  if (mode !== 'strict' && mode !== 'resolve') throw Error('invalid path mode');
  let lexical = $(a[0]).stringByExpandingTildeInPath.stringByStandardizingPath.js;
  if (!lexical.startsWith('/') || /[\u0000\r\n]/.test(lexical)) throw Error('invalid absolute path');
  let parts = lexical.split('/'), cur = '';
  for (let i = 1; i < parts.length; i++) {
    if (!parts[i]) continue;
    cur += '/' + parts[i];
    let destination = symlinkDestination(cur);
    if (!destination) continue;
    let allowedSystemAlias =
      cur === '/var' && (destination === 'private/var' || destination === '/private/var') ||
      cur === '/tmp' && (destination === 'private/tmp' || destination === '/private/tmp') ||
      cur === '/etc' && (destination === 'private/etc' || destination === '/private/etc');
    if (!allowedSystemAlias && mode !== 'resolve') throw Error('symlink path component: ' + cur);
  }
  return $(lexical).stringByResolvingSymlinksInPath.stringByStandardizingPath.js;
}
JXA
}

new_nonce() {
  /usr/bin/osascript -l JavaScript - <<'JXA'
ObjC.import('Foundation');
function run() { return $.NSUUID.UUID.UUIDString.js.replace(/-/g, '').toLowerCase(); }
JXA
}

path_guard() {
  root=$1
  target=$2
  mode=${3:-inside}
  /usr/bin/osascript -l JavaScript - "$root" "$target" "$mode" <<'JXA'
ObjC.import('Foundation');
function standard(p) {
  if (typeof p !== 'string' || !p || /[\u0000\r\n]/.test(p)) throw Error('invalid path');
  let q = $(p).stringByExpandingTildeInPath.stringByStandardizingPath.js;
  if (!q.startsWith('/')) throw Error('path is not absolute');
  return q;
}
function isSymlink(p) {
  let linkError = Ref();
  let destination = $.NSFileManager.defaultManager.destinationOfSymbolicLinkAtPathError($(p), linkError);
  if (destination) return true;
  let e = Ref();
  let attrs = $.NSFileManager.defaultManager.attributesOfItemAtPathError($(p), e);
  if (!attrs) return false;
  let t = attrs.objectForKey($.NSFileType);
  return !!t && t.isEqualToString($.NSFileTypeSymbolicLink);
}
function checkComponents(p) {
  let parts = p.split('/'), cur = '';
  for (let i = 1; i < parts.length; i++) {
    if (!parts[i]) continue;
    cur += '/' + parts[i];
    if (isSymlink(cur)) throw Error('symlink path component: ' + cur);
  }
}
function run(a) {
  let root = standard(a[0]), target = standard(a[1]), mode = a[2];
  if (root === '/') throw Error('Codex home cannot be root');
  if (target !== root && !target.startsWith(root + '/')) throw Error('path escapes Codex home');
  if (mode === 'inside' && target === root) throw Error('write target must be inside Codex home');
  checkComponents(root);
  checkComponents(target);
  return target;
}
JXA
}

path_in_home() {
  path_guard "$1" "$2" "${3:-inside}" >/dev/null 2>&1
}

sha256() {
  [ -f "$1" ] || return 1
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print toupper($1)}'
}

filesize() { /usr/bin/stat -f '%z' "$1"; }
filemode() { /usr/bin/stat -f '%Lp' "$1"; }
timestamp() { /bin/date '+%Y%m%d-%H%M%S'; }

unique_path() {
  p=$1
  i=0
  while [ -e "$p" ] || [ -L "$p" ]; do
    i=$((i + 1))
    p="$1.$i"
  done
  printf '%s\n' "$p"
}

sync_file() {
  /usr/bin/osascript -l JavaScript - "$1" <<'JXA'
ObjC.import('Foundation');
function run(a) {
  let h = $.NSFileHandle.fileHandleForUpdatingAtPath($(a[0]));
  if (!h) throw Error('cannot open file for sync');
  h.synchronizeFile;
  h.closeFile;
}
JXA
}

atomic_install() {
  src=$1
  dest=$2
  preserve=${3:-}
  token=${4:-${LOCK_NONCE:-$$}}
  path_guard "$CODEX_ROOT" "$dest" inside >/dev/null || return 1
  dir=${dest%/*}
  base=${dest##*/}
  tmp="$dir/.$base.provider-compat-$token.tmp"
  path_guard "$CODEX_ROOT" "$tmp" inside >/dev/null || return 1
  [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || return 1
  if [ -n "$preserve" ] && [ -f "$preserve" ] && [ ! -L "$preserve" ]; then
    /bin/cp -p "$preserve" "$tmp" || return 1
    /bin/cat "$src" > "$tmp" || { /bin/rm -f "$tmp"; return 1; }
  else
    /bin/cp "$src" "$tmp" || return 1
    /bin/chmod 600 "$tmp" || { /bin/rm -f "$tmp"; return 1; }
  fi
  sync_file "$tmp" >/dev/null 2>&1 || { /bin/rm -f "$tmp"; return 1; }
  [ "$(sha256 "$tmp")" = "$(sha256 "$src")" ] || { /bin/rm -f "$tmp"; return 1; }
  /bin/mv -f "$tmp" "$dest" || { /bin/rm -f "$tmp"; return 1; }
  [ "$(sha256 "$dest")" = "$(sha256 "$src")" ] || return 1
}

remove_owned_temp() {
  p=$1
  expected=${2:-}
  [ -e "$p" ] || [ -L "$p" ] || return 0
  path_guard "$CODEX_ROOT" "$p" inside >/dev/null || return 1
  [ -f "$p" ] && [ ! -L "$p" ] || return 1
  if [ -n "$expected" ]; then [ "$(sha256 "$p")" = "$expected" ] || return 1; fi
  /bin/rm -f "$p"
}

atomic_temp_path() {
  dest=$1
  nonce=$2
  dir=${dest%/*}
  base=${dest##*/}
  printf '%s\n' "$dir/.$base.provider-compat-$nonce.tmp"
}

remove_exact_atomic_temp() {
  p=$1
  [ -e "$p" ] || [ -L "$p" ] || return 0
  path_guard "$CODEX_ROOT" "$p" inside >/dev/null || return 1
  [ -f "$p" ] && [ ! -L "$p" ] || return 1
  /bin/rm -f "$p"
}

cleanup_transaction_atomic_temps() {
  tx=$1
  nonce=$(jxa_get "$tx" nonce) || return 1
  for key in config generated state; do
    dest=$(jxa_get "$tx" "paths.$key")
    [ -z "$dest" ] || remove_exact_atomic_temp "$(atomic_temp_path "$dest" "$nonce")" || return 1
  done
  remove_exact_atomic_temp "$(atomic_temp_path "$TX_PATH" "$nonce")"
}

internal_test_hooks_authorized() {
  requested=0
  [ -z "${CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE:-}" ] || requested=1
  [ -z "${CODEX_PROVIDER_COMPAT_TEST_DOWNLOAD_MODE:-}" ] || requested=1
  [ -z "${CODEX_PROVIDER_COMPAT_TEST_FAIL_STAGE:-}" ] || requested=1
  [ -z "${CODEX_PROVIDER_COMPAT_TEST_MUTATE_CONFIG_BEFORE_WRITE:-}" ] || requested=1
  [ -z "${CODEX_PROVIDER_COMPAT_TEST_SIGNAL_STAGE:-}" ] || requested=1
  [ -z "${CODEX_PROVIDER_COMPAT_TEST_TOCTOU:-}" ] || requested=1
  [ -z "${CODEX_PROVIDER_COMPAT_TEST_VERSIONS:-}" ] || requested=1
  [ "$requested" -eq 0 ] && return 0
  [ "${CODEX_PROVIDER_COMPAT_INTERNAL_TEST_CONFIRM:-}" = 'I-understand-this-is-test-only' ] || {
    warn 'internal test hook refused without the explicit test-only confirmation gate'
    return 1
  }
}

parse_args() {
  [ "$#" -ge 1 ] || return 1
  COMMAND=$1
  shift
  YES=0
  DRY_RUN=0
  CODEX_HOME_ARG=
  CODEX_HOME_ARG_SET=0
  CODEX_VERSION=
  CATALOG_FILE=
  ENABLE_WEB_SEARCH=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes) YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --enable-web-search) ENABLE_WEB_SEARCH=1 ;;
      --codex-home)
        shift
        [ "$#" -gt 0 ] || return 1
        CODEX_HOME_ARG_SET=1
        CODEX_HOME_ARG=$1
        ;;
      --codex-version)
        shift
        [ "$#" -gt 0 ] || return 1
        [ -n "$1" ] || return 1
        CODEX_VERSION=$1
        ;;
      --catalog-file)
        shift
        [ "$#" -gt 0 ] || return 1
        [ -n "$1" ] || return 1
        CATALOG_FILE=$1
        ;;
      *)
        warn "unknown argument: $1"
        return 1
        ;;
    esac
    shift
  done
  case "$COMMAND" in doctor|apply|status|rollback) return 0 ;; *) return 1 ;; esac
}

resolve_home() {
  if [ "$CODEX_HOME_ARG_SET" -eq 1 ]; then
    [ -n "$CODEX_HOME_ARG" ] || return 1
    case "$CODEX_HOME_ARG" in /*) raw=$CODEX_HOME_ARG ;; *) return 1 ;; esac
  elif [ -n "${CODEX_HOME:-}" ]; then
    raw=$CODEX_HOME
  else
    [ -n "${HOME:-}" ] || return 1
    raw="$HOME/.codex"
  fi
  CODEX_ROOT=$(absolute_path "$raw") || return 1
  [ -n "$CODEX_ROOT" ] && [ "$CODEX_ROOT" != / ] || return 1
  lower_root=$(printf '%s' "$CODEX_ROOT" | /usr/bin/tr '[:upper:]' '[:lower:]')
  case "$lower_root" in
    /bin|/bin/*|/sbin|/sbin/*|/usr|/usr/*|/dev|/dev/*|/applications|/applications/*|/library|/library/*|/system|/system/*|/private/etc|/private/etc/*|/opt|/volumes|/cores|/network|/private|/private/var|/private/tmp|/users) return 1 ;;
  esac
  if [ -n "${HOME:-}" ]; then
    canonical_home=$(absolute_path "$HOME" resolve 2>/dev/null) || return 1
    [ "$(printf '%s' "$canonical_home" | /usr/bin/tr '[:upper:]' '[:lower:]')" != "$lower_root" ] || return 1
  fi
  [ ! -L "$CODEX_ROOT" ] || return 1
  path_guard "$CODEX_ROOT" "$CODEX_ROOT" root >/dev/null || return 1
  TX_PATH="$CODEX_ROOT/provider-compat-transaction.json"
}

ensure_home() {
  path_guard "$CODEX_ROOT" "$CODEX_ROOT" root >/dev/null || return 1
  if [ -e "$CODEX_ROOT" ] || [ -L "$CODEX_ROOT" ]; then
    [ -d "$CODEX_ROOT" ] && [ ! -L "$CODEX_ROOT" ] || return 1
  else
    /bin/mkdir -p "$CODEX_ROOT" || return 1
  fi
  path_guard "$CODEX_ROOT" "$CODEX_ROOT" root >/dev/null || return 1
}

ensure_catalog_dir() {
  d="$CODEX_ROOT/model-catalogs"
  path_guard "$CODEX_ROOT" "$d" inside >/dev/null || return 1
  if [ -e "$d" ] || [ -L "$d" ]; then
    [ -d "$d" ] && [ ! -L "$d" ] || return 1
  else
    /bin/mkdir -m 700 "$d" || return 1
  fi
  path_guard "$CODEX_ROOT" "$d" inside >/dev/null || return 1
}

version_from() {
  label=$1
  path=$2
  [ -x "$path" ] || return 0
  out=$("$path" --version 2>&1) || out=
  version=$(printf '%s\n' "$out" | /usr/bin/awk 'match($0,/[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?/){print substr($0,RSTART,RLENGTH);exit}')
  if [ -n "$version" ]; then
    printf '%s\t%s\t%s\n' "$label" "$path" "$version"
  else
    printf '%s\t%s\t\n' "$label" "$path"
  fi
}

discover_versions() {
  out="$TMP_ROOT/versions"
  : > "$out"
  if [ -n "${CODEX_PROVIDER_COMPAT_TEST_VERSIONS:-}" ]; then
    printf '%s\n' "$CODEX_PROVIDER_COMPAT_TEST_VERSIONS" |
      /usr/bin/awk -F ';' '{for(i=1;i<=NF;i++){n=split($i,a,"=");if(n>=1)printf "%s\\t<test-fixture>\\t%s\\n",a[1],a[2]}}' > "$out"
    return
  fi
  cli=$(command -v codex 2>/dev/null || true)
  [ -n "$cli" ] && version_from 'PATH CLI' "$cli" >> "$out"
  /bin/ps -axo comm= 2>/dev/null |
    while IFS= read -r running; do
      case "$running" in
        codex|codex-app-server|*/codex|*/codex-app-server|*/codex-cli)
          version_from 'Running Codex/app-server' "$running"
          ;;
      esac
    done >> "$out"
  version_from 'Codex home app-server' "$CODEX_ROOT/plugins/.plugin-appserver/codex" >> "$out"
  version_from 'Desktop /Applications' '/Applications/Codex.app/Contents/Resources/codex' >> "$out"
  [ -z "${HOME:-}" ] || version_from 'Desktop ~/Applications' "$HOME/Applications/Codex.app/Contents/Resources/codex" >> "$out"
  /usr/bin/awk -F '\t' '!seen[$2]++' "$out" > "$out.d"
  /bin/mv "$out.d" "$out"
}

show_versions() {
  tab=$(printf '\t')
  while IFS="$tab" read -r label path version; do
    [ -n "$label" ] || continue
    if [ -n "$version" ]; then
      info "version source: $label -> $version [$path]"
    else
      warn "version source unresolved: $label [$path]"
    fi
  done < "$TMP_ROOT/versions"
}

warn_running_codex() {
  if /usr/bin/awk -F '\t' '$1=="Running Codex/app-server"{found=1}END{exit !found}' "$TMP_ROOT/versions"; then
    warn 'Codex/app-server appears to be running; changes require a full restart and a new task'
  fi
}

select_version() {
  if [ -n "$CODEX_VERSION" ]; then
    printf '%s\n' "$CODEX_VERSION" |
      /usr/bin/awk '/^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$/{ok=1} END{exit !ok}' || return 1
    SELECTED_VERSION=$CODEX_VERSION
    return 0
  fi
  versions=$(/usr/bin/awk -F '\t' '$3!=""&&!seen[$3]++{print $3}' "$TMP_ROOT/versions")
  count=$(printf '%s\n' "$versions" | /usr/bin/awk 'NF{n++}END{print n+0}')
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$versions" | /usr/bin/awk '/^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$/{ok=1}END{exit !ok}' || return 1
  SELECTED_VERSION=$versions
}

jxa_catalog() {
  mode=$1
  input=$2
  output=${3:-}
  /usr/bin/osascript -l JavaScript - "$mode" "$input" "$output" "$MIN_CATALOG_MODELS" "$MIN_NON_TARGET_MODELS" <<'JXA'
ObjC.import('Foundation');
function read(p) {
  let e = Ref();
  let s = $.NSString.stringWithContentsOfFileEncodingError($(p), $.NSUTF8StringEncoding, e);
  if (!s) throw Error('cannot read catalog');
  return s.js;
}
function write(p, s) {
  let e = Ref();
  if (!$(s).writeToFileAtomicallyEncodingError($(p), true, $.NSUTF8StringEncoding, e)) throw Error('cannot write catalog');
}
function plainObject(o) { return !!o && typeof o === 'object' && !Array.isArray(o); }
function validate(o, minModels, minNonTargets) {
  if (!plainObject(o) || !Array.isArray(o.models)) throw Error('catalog must be an object with a models array');
  if (o.models.length < minModels) throw Error('catalog is empty or too small to be a complete catalog');
  const targets = ['gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna'];
  let seen = Object.create(null), states = {}, other = [], nonTargets = 0;
  for (let i = 0; i < o.models.length; i++) {
    let m = o.models[i];
    if (!plainObject(m) || typeof m.slug !== 'string' || !m.slug.trim()) throw Error('every model must have a non-empty slug');
    if (Object.prototype.hasOwnProperty.call(seen, m.slug)) throw Error('duplicate model slug: ' + m.slug);
    seen[m.slug] = {model:m, index:i};
    if (targets.indexOf(m.slug) < 0) nonTargets++;
  }
  if (nonTargets < minNonTargets) throw Error('catalog does not contain enough non-target models');
  for (let t of targets) {
    if (!seen[t]) throw Error('target model missing: ' + t);
    if (typeof seen[t].model.use_responses_lite !== 'boolean') throw Error('use_responses_lite for ' + t + ' must be boolean');
    states[t] = seen[t].model.use_responses_lite;
  }
  for (let m of o.models) {
    if (m.use_responses_lite === true && targets.indexOf(m.slug) < 0) other.push(m.slug);
  }
  return {targets:targets, seen:seen, states:states, other:other, nonTargets:nonTargets};
}
function diff(a, b, path, out) {
  if (a === b) return;
  if (typeof a !== typeof b || a === null || b === null || Array.isArray(a) !== Array.isArray(b)) {
    out.push({path:path, before:a, after:b});
    return;
  }
  if (Array.isArray(a)) {
    if (a.length !== b.length) { out.push({path:path + '.length', before:a.length, after:b.length}); return; }
    for (let i = 0; i < a.length; i++) diff(a[i], b[i], path + '[' + i + ']', out);
    return;
  }
  if (typeof a === 'object') {
    let ak = Object.keys(a).sort(), bk = Object.keys(b).sort();
    if (JSON.stringify(ak) !== JSON.stringify(bk)) { out.push({path:path + '.keys', before:ak, after:bk}); return; }
    for (let k of ak) diff(a[k], b[k], path ? path + '.' + k : k, out);
    return;
  }
  out.push({path:path, before:a, after:b});
}
function run(a) {
  let original;
  try { original = JSON.parse(read(a[1])); }
  catch (e) { throw Error('invalid or truncated catalog JSON: ' + e.message); }
  let minModels = Number(a[3]), minNonTargets = Number(a[4]);
  let v = validate(original, minModels, minNonTargets);
  if (a[0] === 'patch') {
    let patched = JSON.parse(JSON.stringify(original));
    let pv = validate(patched, minModels, minNonTargets);
    for (let t of pv.targets) pv.seen[t].model.use_responses_lite = false;
    write(a[2], JSON.stringify(patched, null, 2) + '\n');
    let reread = JSON.parse(read(a[2]));
    let rv = validate(reread, minModels, minNonTargets);
    let changes = [];
    diff(original, reread, '', changes);
    for (let c of changes) {
      let allowed = false;
      for (let t of v.targets) {
        let expected = 'models[' + v.seen[t].index + '].use_responses_lite';
        if (c.path === expected && c.before === true && c.after === false) allowed = true;
      }
      if (!allowed) throw Error('unexpected catalog semantic difference at ' + c.path);
    }
    for (let t of rv.targets) if (rv.states[t] !== false) throw Error('patched target remained Lite: ' + t);
  }
  return JSON.stringify({
    model_count: original.models.length,
    non_target_count: v.nonTargets,
    states: v.states,
    all_false: !Object.keys(v.states).some(function(k){ return v.states[k] === true; }),
    other_lite: v.other
  });
}
JXA
}

jxa_config() {
  mode=$1
  config=$2
  output=$3
  catalog=${4:-}
  enable=${5:-0}
  state=${6:-}
  /usr/bin/osascript -l JavaScript - "$mode" "$config" "$output" "$catalog" "$enable" "$state" <<'JXA'
ObjC.import('Foundation');
const tracked = ['model_catalog_json', 'web_search', 'model', 'model_provider', 'openai_base_url'];
const owned = ['model_catalog_json', 'web_search'];
function exists(p) { return $.NSFileManager.defaultManager.fileExistsAtPath($(p)); }
function readRaw(p) {
  if (!exists(p)) return '';
  let e = Ref(), d = $.NSData.dataWithContentsOfFileOptionsError($(p), 0, e);
  if (!d) throw Error('cannot read config bytes');
  let length = Number(d.length), hadBom = false, body = d;
  if (length >= 3) {
    let prefix = d.subdataWithRange($.NSMakeRange(0, 3));
    hadBom = prefix.base64EncodedStringWithOptions(0).js === '77u/';
  }
  if (hadBom) body = d.subdataWithRange($.NSMakeRange(3, length - 3));
  let s = $.NSString.alloc.initWithDataEncoding(body, $.NSUTF8StringEncoding);
  if (!s) throw Error('cannot read config as strict UTF-8');
  return (hadBom ? '\uFEFF' : '') + s.js;
}
function writeRaw(p, s) {
  let e = Ref();
  let d = $(s).dataUsingEncodingAllowLossyConversion($.NSUTF8StringEncoding, false);
  if (!d) throw Error('cannot encode config as strict UTF-8');
  if (!d.writeToFileOptionsError($(p), $.NSDataWritingAtomic, e)) throw Error('cannot write config temp');
}
function decodeBasic(s) {
  let out = '';
  for (let i = 1; i < s.length - 1; i++) {
    let c = s[i];
    if (c !== '\\') { out += c; continue; }
    i++;
    if (i >= s.length - 1) throw Error('invalid basic string escape');
    c = s[i];
    let simple = {'b':'\b','t':'\t','n':'\n','f':'\f','r':'\r','"':'"','\\':'\\'};
    if (Object.prototype.hasOwnProperty.call(simple, c)) { out += simple[c]; continue; }
    if (c === 'u' || c === 'U') {
      let n = c === 'u' ? 4 : 8, h = s.slice(i + 1, i + 1 + n);
      if (h.length !== n || !/^[0-9A-Fa-f]+$/.test(h)) throw Error('invalid unicode escape');
      let cp = parseInt(h, 16);
      if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) throw Error('invalid unicode scalar');
      out += String.fromCodePoint(cp);
      i += n;
      continue;
    }
    throw Error('unsupported basic string escape');
  }
  return out;
}
function decodeLiteral(s) {
  if (s.length < 2) throw Error('invalid string literal');
  if (s[0] === '"' && s[s.length - 1] === '"') return decodeBasic(s);
  if (s[0] === "'" && s[s.length - 1] === "'") return s.slice(1, -1);
  throw Error('owned config values must be single-line TOML strings');
}
function quote(s) {
  return '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\u0008/g, '\\b').replace(/\t/g, '\\t').replace(/\n/g, '\\n').replace(/\f/g, '\\f').replace(/\r/g, '\\r') + '"';
}
function parseKey(lhs) {
  let i = 0, segs = [];
  function ws() { while (i < lhs.length && /[ \t]/.test(lhs[i])) i++; }
  ws();
  while (i < lhs.length) {
    let c = lhs[i], value = '';
    if (c === '"' || c === "'") {
      let q = c, start = i, esc = false;
      i++;
      for (; i < lhs.length; i++) {
        c = lhs[i];
        if (q === '"' && esc) { esc = false; continue; }
        if (q === '"' && c === '\\') { esc = true; continue; }
        if (c === q) { i++; break; }
      }
      if (c !== q) throw Error('unterminated quoted key');
      value = q === '"' ? decodeBasic(lhs.slice(start, i)) : lhs.slice(start + 1, i - 1);
    } else {
      let start = i;
      while (i < lhs.length && /[A-Za-z0-9_-]/.test(lhs[i])) i++;
      if (start === i) throw Error('unsupported top-level key syntax');
      value = lhs.slice(start, i);
    }
    segs.push(value);
    ws();
    if (i === lhs.length) break;
    if (lhs[i] !== '.') throw Error('unsupported top-level key syntax');
    i++;
    ws();
  }
  if (!segs.length) throw Error('empty key');
  return segs;
}
function findEqual(line) {
  let q = null, esc = false;
  for (let i = 0; i < line.length; i++) {
    let c = line[i];
    if (q === '"') {
      if (esc) { esc = false; continue; }
      if (c === '\\') { esc = true; continue; }
      if (c === '"') q = null;
      continue;
    }
    if (q === "'") { if (c === "'") q = null; continue; }
    if (c === '"' || c === "'") { q = c; continue; }
    if (c === '#') return -1;
    if (c === '=') return i;
  }
  if (q) throw Error('unterminated quoted key');
  return -1;
}
function tableHeaderSegments(line) {
  let i = 0;
  while (i < line.length && /[ \t]/.test(line[i])) i++;
  if (line[i] !== '[') throw Error('malformed table header');
  let arrayTable = line[i + 1] === '[', need = arrayTable ? 2 : 1;
  i += need;
  let contentStart = i, contentEnd = -1;
  let q = null, esc = false, closed = 0;
  for (; i < line.length; i++) {
    let c = line[i];
    if (q === '"') {
      if (esc) { esc = false; continue; }
      if (c === '\\') { esc = true; continue; }
      if (c === '"') q = null;
      continue;
    }
    if (q === "'") { if (c === "'") q = null; continue; }
    if (c === '"' || c === "'") { q = c; continue; }
    if (c === ']') {
      closed++;
      if (closed === need) { contentEnd = i - need + 1; i++; break; }
      continue;
    }
    if (c === '#') throw Error('malformed table header');
  }
  if (q || closed !== need) throw Error('malformed table header');
  while (i < line.length && /[ \t]/.test(line[i])) i++;
  if (i < line.length && line[i] !== '#') throw Error('malformed table header');
  return parseKey(line.slice(contentStart, contentEnd));
}
function simpleValueInfo(line, eq) {
  let start = eq + 1;
  while (start < line.length && /[ \t]/.test(line[start])) start++;
  if (line.slice(start, start + 3) === '"""' || line.slice(start, start + 3) === "'''") throw Error('owned key uses a multiline value');
  let q = null, esc = false, comment = line.length;
  for (let i = start; i < line.length; i++) {
    let c = line[i];
    if (q === '"') {
      if (esc) { esc = false; continue; }
      if (c === '\\') { esc = true; continue; }
      if (c === '"') q = null;
      continue;
    }
    if (q === "'") { if (c === "'") q = null; continue; }
    if (c === '"' || c === "'") { q = c; continue; }
    if (c === '#') { comment = i; break; }
    if (c === '[' || c === '{') throw Error('owned key uses a complex value');
  }
  if (q) throw Error('unterminated owned value');
  let end = comment;
  while (end > start && /[ \t]/.test(line[end - 1])) end--;
  let literal = line.slice(start, end);
  let value = decodeLiteral(literal);
  return {start:start, end:end, literal:literal, value:value};
}
function quoteRun(line, start, quote) {
  let i = start;
  while (i < line.length && line[i] === quote) i++;
  return i - start;
}
function scanLine(line, st, start) {
  let comment = false;
  for (let i = start; i < line.length; i++) {
    let c = line[i], tri = line.slice(i, i + 3);
    if (comment) break;
    if (st.kind === 'mlbasic') {
      if (st.escape) { st.escape = false; continue; }
      if (c === '\\') { st.escape = true; continue; }
      if (c === '"') {
        let n = quoteRun(line, i, '"');
        if (n >= 3) { st.kind = 'normal'; i += (n <= 5 ? n : 3) - 1; }
      }
      continue;
    }
    if (st.kind === 'mlliteral') {
      if (c === "'") {
        let n = quoteRun(line, i, "'");
        if (n >= 3) { st.kind = 'normal'; i += (n <= 5 ? n : 3) - 1; }
      }
      continue;
    }
    if (st.kind === 'basic') {
      if (st.escape) { st.escape = false; continue; }
      if (c === '\\') { st.escape = true; continue; }
      if (c === '"') st.kind = 'normal';
      continue;
    }
    if (st.kind === 'literal') {
      if (c === "'") st.kind = 'normal';
      continue;
    }
    if (c === '#') { comment = true; continue; }
    if (tri === '"""') { st.kind = 'mlbasic'; st.escape = false; i += 2; continue; }
    if (tri === "'''") { st.kind = 'mlliteral'; i += 2; continue; }
    if (c === '"') { st.kind = 'basic'; st.escape = false; continue; }
    if (c === "'") { st.kind = 'literal'; continue; }
    if (c === '[') st.square++;
    else if (c === ']') { st.square--; if (st.square < 0) throw Error('unbalanced array'); }
    else if (c === '{') st.curly++;
    else if (c === '}') { st.curly--; if (st.curly < 0) throw Error('unbalanced inline table'); }
  }
  if (st.kind === 'basic' || st.kind === 'literal') throw Error('single-line string crosses a newline');
  if (st.kind === 'mlbasic') st.escape = false;
}
function analyze(raw) {
  let hadBom = raw.charCodeAt(0) === 0xFEFF;
  let text = hadBom ? raw.slice(1) : raw;
  let crlf = (text.match(/\r\n/g) || []).length;
  let loneLf = (text.replace(/\r\n/g, '').match(/\n/g) || []).length;
  if (crlf && loneLf) throw Error('mixed newline styles are unsafe to edit');
  let nl = crlf ? '\r\n' : '\n';
  let lines = text.split(/\r\n|\n/);
  let keys = {model_catalog_json:[], web_search:[], model:[], model_provider:[], openai_base_url:[]};
  let st = {kind:'normal', escape:false, square:0, curly:0};
  let inTable = false, firstTable = -1, openaiProviderTable = false;
  for (let index = 0; index < lines.length; index++) {
    let line = lines[index], trimmed = line.replace(/^[ \t]+/, '');
    let atStatement = st.kind === 'normal' && st.square === 0 && st.curly === 0;
    if (atStatement && trimmed && trimmed[0] !== '#') {
      if (trimmed[0] === '[') {
        let tableSegments = tableHeaderSegments(line);
        if (tableSegments.length === 2 && tableSegments[0] === 'model_providers' && tableSegments[1] === 'openai') openaiProviderTable = true;
        inTable = true;
        if (firstTable < 0) firstTable = index;
        continue;
      }
      let eq = findEqual(line);
      if (!inTable && eq < 0) throw Error('unsupported top-level TOML statement');
      if (!inTable) {
        let segs = parseKey(line.slice(0, eq));
        let hasOwned = segs.some(function(k){ return owned.indexOf(k) >= 0; });
        if (segs.length !== 1 && hasOwned) throw Error('owned key uses dotted or complex syntax');
        if (segs.length === 1 && tracked.indexOf(segs[0]) >= 0) {
          let vi;
          if (owned.indexOf(segs[0]) >= 0) vi = simpleValueInfo(line, eq);
          else {
            try { vi = simpleValueInfo(line, eq); }
            catch (_) { vi = {start:eq + 1, end:line.length, literal:null, value:null, unsupported:true}; }
          }
          keys[segs[0]].push({index:index, line:line, equal:eq, start:vi.start, end:vi.end, literal:vi.literal, value:vi.value});
        }
      }
    }
    scanLine(line, st, 0);
  }
  if (st.kind !== 'normal' || st.square !== 0 || st.curly !== 0) throw Error('unterminated multiline TOML value');
  for (let k of owned) if (keys[k].length > 1) throw Error('duplicate top-level ' + k + ' keys');
  return {raw:raw, text:text, hadBom:hadBom, newline:nl, lines:lines, firstTable:firstTable, keys:keys, openaiProviderTable:openaiProviderTable};
}
function setKey(a, key, literal, remove) {
  let lines = a.lines.slice(), entries = a.keys[key];
  if (entries.length > 1) throw Error('duplicate top-level ' + key + ' keys');
  if (entries.length === 1) {
    let e = entries[0];
    if (remove) lines.splice(e.index, 1);
    else lines[e.index] = e.line.slice(0, e.start) + literal + e.line.slice(e.end);
  } else if (!remove) {
    let idx = a.firstTable >= 0 ? a.firstTable : lines.length;
    if (idx === lines.length && lines.length && lines[lines.length - 1] === '') idx--;
    lines.splice(idx, 0, key + ' = ' + literal);
  }
  return (a.hadBom ? '\uFEFF' : '') + lines.join(a.newline);
}
function meta(a, pathExists) {
  function one(k) { return a.keys[k].length ? a.keys[k][0] : null; }
  let mc = one('model_catalog_json'), ws = one('web_search'), model = one('model'), provider = one('model_provider');
  return {
    exists:pathExists,
    had_bom:a.hadBom,
    newline:a.newline === '\r\n' ? 'crlf' : 'lf',
    previous_model_catalog_json_present:!!mc,
    previous_model_catalog_json:mc ? mc.value : null,
    previous_model_catalog_json_literal:mc ? mc.literal : null,
    previous_web_search_present:!!ws,
    previous_web_search:ws ? ws.value : null,
    previous_web_search_literal:ws ? ws.literal : null,
    current_model:model ? model.value : null,
    current_provider:provider ? provider.value : null,
    current_catalog:mc ? mc.value : null,
    current_web_search:ws ? ws.value : null,
    openai_base_url_present:a.keys.openai_base_url.length > 0,
    openai_provider_table_present:a.openaiProviderTable
  };
}
function run(v) {
  let mode = v[0], path = v[1], out = v[2], pathExists = exists(path), raw = readRaw(path), a = analyze(raw), m = meta(a, pathExists);
  if (mode === 'analyze') return JSON.stringify(m);
  let text;
  if (mode === 'apply') {
    text = setKey(a, 'model_catalog_json', quote(v[3].replace(/\\/g, '/')), false);
    if (v[4] === '1') {
      a = analyze(text);
      text = setKey(a, 'web_search', '"live"', false);
    }
  } else if (mode === 'rollback') {
    let st = JSON.parse(readRaw(v[5]));
    if (!st || !st.generated_catalog || !st.config) throw Error('invalid sanitized state');
    if (!m.current_catalog || m.current_catalog.replace(/\\/g, '/') !== st.generated_catalog.path.replace(/\\/g, '/')) throw Error('model_catalog_json drifted after apply');
    if (st.config.web_search_modified && m.current_web_search !== 'live') throw Error('web_search drifted after apply');
    let previousCatalogLiteral = st.config.previous_model_catalog_json_literal;
    if (!previousCatalogLiteral && st.config.previous_model_catalog_json_present) previousCatalogLiteral = quote(st.config.previous_model_catalog_json);
    text = setKey(a, 'model_catalog_json', previousCatalogLiteral || '', !st.config.previous_model_catalog_json_present);
    a = analyze(text);
    if (st.config.web_search_modified) {
      let previousWebLiteral = st.config.previous_web_search_literal;
      if (!previousWebLiteral && st.config.previous_web_search_present) previousWebLiteral = quote(st.config.previous_web_search);
      text = setKey(a, 'web_search', previousWebLiteral || '', !st.config.previous_web_search_present);
    }
  } else {
    throw Error('unknown config operation');
  }
  writeRaw(out, text);
  m.result_empty = (text.replace(/^\uFEFF/, '').length === 0);
  return JSON.stringify(m);
}
JXA
}

jxa_get() {
  /usr/bin/osascript -l JavaScript - "$1" "$2" <<'JXA'
ObjC.import('Foundation');
function run(a) {
  let e = Ref(), s = $.NSString.stringWithContentsOfFileEncodingError($(a[0]), $.NSUTF8StringEncoding, e);
  if (!s) throw Error('cannot read JSON');
  let o = JSON.parse(s.js), p = a[1].split('.');
  for (let k of p) o = o == null ? null : o[k];
  if (o === null || o === undefined) return '';
  if (Array.isArray(o)) return o.join(',');
  return String(o);
}
JXA
}

jxa_validate_state() {
  state=$1
  root=$2
  selected=${3:-}
  /usr/bin/osascript -l JavaScript - "$state" "$root" "$selected" <<'JXA'
ObjC.import('Foundation');
function read(p) {
  let e = Ref(), s = $.NSString.stringWithContentsOfFileEncodingError($(p), $.NSUTF8StringEncoding, e);
  if (!s) throw Error('cannot read state');
  return JSON.parse(s.js);
}
function req(x, m) { if (!x) throw Error(m); }
function exact(o, keys, name) {
  req(o && typeof o === 'object' && !Array.isArray(o), 'invalid ' + name);
  let actual = Object.keys(o).sort(), expected = keys.slice().sort();
  req(JSON.stringify(actual) === JSON.stringify(expected), 'unexpected ' + name + ' fields');
}
function std(p) { return $(p).stringByStandardizingPath.js; }
function inside(root, p) { return typeof p === 'string' && std(p) === p && p !== root && p.startsWith(root + '/') && !/[\u0000\r\n]/.test(p); }
function hash(s, nullable) { return nullable && (s === null || s === '') || typeof s === 'string' && /^[0-9A-Fa-f]{64}$/.test(s); }
function leaf(p) { return p.slice(p.lastIndexOf('/') + 1); }
function parent(p) { let i = p.lastIndexOf('/'); return i <= 0 ? '/' : p.slice(0, i); }
function safeLiteral(lit, value) {
  if (lit === null || lit === undefined || lit === '') return true;
  req(typeof lit === 'string' && lit.length >= 2, 'invalid previous literal');
  let q = lit[0];
  req((q === '"' || q === "'") && lit[lit.length - 1] === q && lit.indexOf('\n') < 0 && lit.indexOf('\r') < 0, 'invalid previous literal');
  if (q === "'") return lit.slice(1, -1) === value;
  let out = '';
  for (let i = 1; i < lit.length - 1; i++) {
    let c = lit[i];
    if (c !== '\\') { out += c; continue; }
    i++; req(i < lit.length - 1, 'bad previous literal escape'); c = lit[i];
    let map = {'b':'\b','t':'\t','n':'\n','f':'\f','r':'\r','"':'"','\\':'\\'};
    if (Object.prototype.hasOwnProperty.call(map, c)) { out += map[c]; continue; }
    if (c === 'u' || c === 'U') {
      let n = c === 'u' ? 4 : 8, h = lit.slice(i + 1, i + 1 + n);
      req(h.length === n && /^[0-9A-Fa-f]+$/.test(h), 'bad previous unicode escape');
      let cp = parseInt(h, 16);
      req(cp <= 0x10FFFF && !(cp >= 0xD800 && cp <= 0xDFFF), 'bad previous unicode scalar');
      out += String.fromCodePoint(cp);
      i += n;
      continue;
    }
    throw Error('unsupported previous literal escape');
  }
  return out === value;
}
function run(a) {
  let o = read(a[0]), root = std(a[1]), selected = a[2];
  exact(o, ['schema_version','patch_version','patch_id','codex_version','source_catalog','generated_catalog','config','cache','other_lite_models','applied_at'], 'state');
  req(o && o.schema_version === 1, 'unsupported state schema');
  req(o.patch_id === 'responses-lite-standard-tools', 'unexpected patch id');
  req(typeof o.codex_version === 'string' && /^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$/.test(o.codex_version), 'invalid state version');
  if (selected) req(o.codex_version === selected, 'stale state version');
  let expectedGenerated = root + '/model-catalogs/models-' + o.codex_version + '.standard-responses-compat.json';
  exact(o.source_catalog, ['kind','url','path','sha256','model_count'], 'source catalog state');
  exact(o.generated_catalog, ['path','sha256'], 'generated catalog state');
  exact(o.config, ['path','backup_path','before_sha256','existed','had_bom','newline','original_mode','previous_model_catalog_json_present','previous_model_catalog_json','previous_model_catalog_json_literal','web_search_modified','previous_web_search_present','previous_web_search','previous_web_search_literal'], 'config state');
  exact(o.cache, ['original_path','backup_path','sha256'], 'cache state');
  req(typeof o.patch_version === 'string' && /^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$/.test(o.patch_version), 'invalid patch version');
  req(typeof o.applied_at === 'string' && !isNaN(Date.parse(o.applied_at)) && Array.isArray(o.other_lite_models) && o.other_lite_models.every(function(x){return typeof x === 'string';}), 'invalid state metadata');
  req(o.source_catalog.kind === 'local-file' || o.source_catalog.kind === 'official-github-tag', 'invalid source catalog kind');
  if (o.source_catalog.kind === 'official-github-tag') {
    req(o.source_catalog.path === null && o.source_catalog.url === 'https://raw.githubusercontent.com/openai/codex/rust-v' + o.codex_version + '/codex-rs/models-manager/models.json', 'invalid official source catalog');
  } else {
    req(o.source_catalog.url === null && typeof o.source_catalog.path === 'string' && o.source_catalog.path.length > 0, 'invalid local source catalog');
  }
  req(o.generated_catalog.path === expectedGenerated && hash(o.generated_catalog.sha256, false), 'invalid generated catalog state');
  req(typeof o.source_catalog.model_count === 'number' && isFinite(o.source_catalog.model_count) && Math.floor(o.source_catalog.model_count) === o.source_catalog.model_count && o.source_catalog.model_count >= 8 && hash(o.source_catalog.sha256, false), 'invalid source catalog state');
  req(o.config.path === root + '/config.toml', 'invalid config state path');
  req(typeof o.config.existed === 'boolean' && typeof o.config.previous_model_catalog_json_present === 'boolean' && typeof o.config.web_search_modified === 'boolean' && typeof o.config.previous_web_search_present === 'boolean', 'invalid config state flags');
  req(typeof o.config.had_bom === 'boolean' && (o.config.newline === 'lf' || o.config.newline === 'crlf'), 'invalid config format state');
  req(o.config.original_mode === null || o.config.original_mode === undefined || typeof o.config.original_mode === 'string' && /^[0-7]{3,4}$/.test(o.config.original_mode), 'invalid original config mode');
  req(hash(o.config.before_sha256, true), 'invalid config backup hash');
  if (o.config.backup_path !== null && o.config.backup_path !== '') {
    req(inside(root, o.config.backup_path) && parent(o.config.backup_path) === root && /^config\.toml\.bak-provider-compat-[0-9]{8}-[0-9]{6}(\.[0-9]+)?$/.test(leaf(o.config.backup_path)), 'invalid config backup path');
  } else req(!o.config.existed, 'missing config backup path');
  if (o.config.previous_model_catalog_json_present) {
    req(typeof o.config.previous_model_catalog_json === 'string', 'invalid previous catalog value');
    req(safeLiteral(o.config.previous_model_catalog_json_literal, o.config.previous_model_catalog_json), 'invalid previous catalog literal');
  } else req(o.config.previous_model_catalog_json === null && o.config.previous_model_catalog_json_literal === null, 'unexpected previous catalog state');
  if (o.config.previous_web_search_present) {
    req(typeof o.config.previous_web_search === 'string', 'invalid previous web_search value');
    req(safeLiteral(o.config.previous_web_search_literal, o.config.previous_web_search), 'invalid previous web_search literal');
  } else req(o.config.previous_web_search === null && o.config.previous_web_search_literal === null, 'unexpected previous web_search state');
  req(o.cache && o.cache.original_path === root + '/models_cache.json' && hash(o.cache.sha256, true), 'invalid cache state');
  if (o.cache.backup_path !== null && o.cache.backup_path !== '') {
    req(inside(root, o.cache.backup_path) && parent(o.cache.backup_path) === root && /^models_cache\.json\.bak-provider-compat-[0-9]{8}-[0-9]{6}(\.[0-9]+)?$/.test(leaf(o.cache.backup_path)), 'invalid cache backup path');
    req(hash(o.cache.sha256, false), 'missing cache hash');
  } else req(o.cache.sha256 === null || o.cache.sha256 === '', 'unexpected cache hash');
  return JSON.stringify(o);
}
JXA
}

jxa_write_state() {
  meta=$1
  catalog_meta=$2
  out=$3
  shift 3
  /usr/bin/osascript -l JavaScript - "$meta" "$catalog_meta" "$out" "$@" <<'JXA'
ObjC.import('Foundation');
function read(p) {
  let e = Ref(), s = $.NSString.stringWithContentsOfFileEncodingError($(p), $.NSUTF8StringEncoding, e);
  if (!s) throw Error('cannot read state input');
  return JSON.parse(s.js);
}
function write(p, s) {
  let e = Ref();
  if (!$(s).writeToFileAtomicallyEncodingError($(p), true, $.NSUTF8StringEncoding, e)) throw Error('cannot write state temp');
}
function run(a) {
  let m = read(a[0]), cm = read(a[1]);
  let o = {
    schema_version:1,
    patch_version:a[3],
    patch_id:a[4],
    codex_version:a[5],
    source_catalog:{kind:a[6], url:a[7] || null, path:a[6] === 'local-file' ? a[8] : null, sha256:a[9], model_count:Number(a[10])},
    generated_catalog:{path:a[11], sha256:a[12]},
    config:{
      path:a[13],
      backup_path:a[14] || null,
      before_sha256:a[15] || null,
      existed:m.exists,
      had_bom:m.had_bom,
      newline:m.newline,
      original_mode:a[16] || null,
      previous_model_catalog_json_present:m.previous_model_catalog_json_present,
      previous_model_catalog_json:m.previous_model_catalog_json,
      previous_model_catalog_json_literal:m.previous_model_catalog_json_literal,
      web_search_modified:a[17] === '1',
      previous_web_search_present:m.previous_web_search_present,
      previous_web_search:m.previous_web_search,
      previous_web_search_literal:m.previous_web_search_literal
    },
    cache:{original_path:a[18], backup_path:a[19] || null, sha256:a[20] || null},
    other_lite_models:cm.other_lite || [],
    applied_at:(new Date()).toISOString()
  };
  write(a[2], JSON.stringify(o, null, 2) + '\n');
}
JXA
}

jxa_write_transaction() {
  out=$1
  shift
  /usr/bin/osascript -l JavaScript - "$out" "$@" <<'JXA'
ObjC.import('Foundation');
function write(p, s) {
  let e = Ref();
  if (!$(s).writeToFileAtomicallyEncodingError($(p), true, $.NSUTF8StringEncoding, e)) throw Error('cannot write transaction temp');
}
function n(s) { return s === '' ? null : s; }
function run(a) {
  let o = {
    schema_version:1,
    operation:a[1],
    phase:a[2],
    nonce:a[3],
    created_at:(new Date()).toISOString(),
    updated_at:null,
    root:a[4],
    codex_version:a[5],
    paths:{
      config:a[6],
      config_backup:n(a[7]),
      config_snapshot:n(a[8]),
      generated_catalog:a[9],
      generated_catalog_pending:n(a[10]),
      cache_original:a[11],
      cache_backup:n(a[12]),
      state:a[13],
      state_archive:n(a[14])
    },
    hashes:{
      config_before:n(a[15]),
      config_after:n(a[16]),
      generated_catalog:n(a[17]),
      cache:n(a[18]),
      state:n(a[19])
    },
    flags:{
      config_existed:a[20] === '1',
      config_should_delete:a[21] === '1',
      generated_catalog_owned:a[22] === '1',
      cache_should_restore:a[23] === '1'
    }
  };
  write(a[0], JSON.stringify(o, null, 2) + '\n');
}
JXA
}

jxa_update_transaction_phase() {
  tx=$1
  phase=$2
  out=$3
  /usr/bin/osascript -l JavaScript - "$tx" "$phase" "$out" <<'JXA'
ObjC.import('Foundation');
function run(a) {
  let e = Ref(), s = $.NSString.stringWithContentsOfFileEncodingError($(a[0]), $.NSUTF8StringEncoding, e);
  if (!s) throw Error('cannot read transaction');
  let o = JSON.parse(s.js);
  o.phase = a[1];
  o.updated_at = (new Date()).toISOString();
  if (!$(JSON.stringify(o, null, 2) + '\n').writeToFileAtomicallyEncodingError($(a[2]), true, $.NSUTF8StringEncoding, e)) throw Error('cannot update transaction');
}
JXA
}

jxa_validate_transaction() {
  tx=$1
  root=$2
  /usr/bin/osascript -l JavaScript - "$tx" "$root" <<'JXA'
ObjC.import('Foundation');
function read(p) {
  let e = Ref(), s = $.NSString.stringWithContentsOfFileEncodingError($(p), $.NSUTF8StringEncoding, e);
  if (!s) throw Error('cannot read transaction');
  return JSON.parse(s.js);
}
function req(x, m) { if (!x) throw Error(m); }
function exact(o, keys, name) {
  req(o && typeof o === 'object' && !Array.isArray(o), 'invalid ' + name);
  let actual = Object.keys(o).sort(), expected = keys.slice().sort();
  req(JSON.stringify(actual) === JSON.stringify(expected), 'unexpected ' + name + ' fields');
}
function std(p) { return $(p).stringByStandardizingPath.js; }
function inside(root, p) { return typeof p === 'string' && std(p) === p && p !== root && p.startsWith(root + '/') && !/[\u0000\r\n]/.test(p); }
function hash(s) { return s === null || typeof s === 'string' && /^[0-9A-Fa-f]{64}$/.test(s); }
function leaf(p) { return p.slice(p.lastIndexOf('/') + 1); }
function parent(p) { let i = p.lastIndexOf('/'); return i <= 0 ? '/' : p.slice(0, i); }
function run(a) {
  let o = read(a[0]), root = std(a[1]);
  exact(o, ['schema_version','operation','phase','nonce','created_at','updated_at','root','codex_version','paths','hashes','flags'], 'transaction');
  req(o && o.schema_version === 1 && (o.operation === 'apply' || o.operation === 'rollback'), 'invalid transaction');
  req(typeof o.created_at === 'string' && !isNaN(Date.parse(o.created_at)) && (o.updated_at === null || typeof o.updated_at === 'string' && !isNaN(Date.parse(o.updated_at))), 'invalid transaction timestamps');
  req(typeof o.phase === 'string' && typeof o.nonce === 'string' && /^[0-9a-f]{32}$/.test(o.nonce), 'invalid transaction identity');
  let allowedPhases = o.operation === 'apply'
    ? ['prepared','config-backed-up','generated-catalog-written','cache-backed-up','config-written','state-written']
    : ['prepared','config-snapshotted','generated-catalog-pending','cache-restored','config-written','state-archived'];
  req(allowedPhases.indexOf(o.phase) >= 0, 'invalid transaction phase');
  req(o.root === root && typeof o.codex_version === 'string' && /^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$/.test(o.codex_version), 'invalid transaction root/version');
  let p = o.paths, h = o.hashes, f = o.flags;
  exact(p, ['config','config_backup','config_snapshot','generated_catalog','generated_catalog_pending','cache_original','cache_backup','state','state_archive'], 'transaction paths');
  exact(h, ['config_before','config_after','generated_catalog','cache','state'], 'transaction hashes');
  exact(f, ['config_existed','config_should_delete','generated_catalog_owned','cache_should_restore'], 'transaction flags');
  req(p && h && f && p.config === root + '/config.toml' && p.state === root + '/provider-compat-state.json' && p.cache_original === root + '/models_cache.json', 'invalid fixed transaction paths');
  let expectedGenerated = root + '/model-catalogs/models-' + o.codex_version + '.standard-responses-compat.json';
  req(p.generated_catalog === expectedGenerated, 'invalid generated transaction path');
  for (let k of Object.keys(p)) if (p[k] !== null) req(inside(root, p[k]), 'transaction path escapes home: ' + k);
  if (p.config_backup !== null) req(parent(p.config_backup) === root && /^config\.toml\.bak-provider-compat-[0-9]{8}-[0-9]{6}(\.[0-9]+)?$/.test(leaf(p.config_backup)), 'invalid config backup transaction path');
  if (p.cache_backup !== null) req(parent(p.cache_backup) === root && /^models_cache\.json\.bak-provider-compat-[0-9]{8}-[0-9]{6}(\.[0-9]+)?$/.test(leaf(p.cache_backup)), 'invalid cache backup transaction path');
  if (o.operation === 'rollback') {
    req(p.config_backup === null && f.config_existed === true, 'invalid rollback transaction config flags');
    req(p.config_snapshot === root + '/.provider-compat-rollback-' + o.nonce + '.config', 'invalid config snapshot path');
    req(p.generated_catalog_pending === p.generated_catalog + '.rollback-pending-' + o.nonce, 'invalid pending catalog path');
    req(p.state_archive !== null && parent(p.state_archive) === root && /^provider-compat-state\.json\.rolled-back-[0-9]{8}-[0-9]{6}(\.[0-9]+)?$/.test(leaf(p.state_archive)), 'invalid state archive path');
  } else {
    req(f.config_should_delete === false && f.generated_catalog_owned === false && f.cache_should_restore === false, 'invalid apply transaction flags');
    if (f.config_existed) {
      req(p.config_backup !== null && h.config_before !== null, 'missing apply config recovery data');
    } else {
      req(p.config_backup === null && h.config_before === null, 'unexpected apply config recovery data');
    }
    req(p.config_snapshot === null && p.generated_catalog_pending === null && p.state_archive === null, 'unexpected apply transaction paths');
  }
  for (let k of Object.keys(h)) req(hash(h[k]), 'invalid transaction hash: ' + k);
  req(typeof f.config_existed === 'boolean' && typeof f.config_should_delete === 'boolean' && typeof f.generated_catalog_owned === 'boolean' && typeof f.cache_should_restore === 'boolean', 'invalid transaction flags');
  req(h.state !== null, 'missing transaction state hash');
  if (o.operation === 'apply') req(h.config_after !== null && h.generated_catalog !== null, 'missing apply content hash');
  if (o.operation === 'rollback') {
    if (f.generated_catalog_owned) req(h.generated_catalog !== null, 'missing owned generated catalog hash');
    if (f.config_should_delete) req(h.config_after === null, 'unexpected deleted-config hash');
    else req(h.config_after !== null, 'missing rollback config hash');
  }
  if (p.cache_backup !== null) req(h.cache !== null, 'missing transaction cache hash');
  if (o.operation === 'rollback') req(h.config_before !== null, 'missing rollback config hash');
  return JSON.stringify(o);
}
JXA
}

download_catalog() {
  mode=${CODEX_PROVIDER_COMPAT_TEST_DOWNLOAD_MODE:-}
  dest="$TMP_ROOT/download.json"
  case "$mode" in
    404|500|timeout|redirect|slow|truncated) return 1 ;;
    empty) : > "$dest" ;;
    oversize) /usr/bin/awk 'BEGIN{for(i=0;i<5242881;i++)printf "x"}' > "$dest" ;;
    '')
      url="https://raw.githubusercontent.com/openai/codex/rust-v$SELECTED_VERSION/codex-rs/models-manager/models.json"
      code=$(/usr/bin/curl --proto '=https' --tlsv1.2 --fail --silent --show-error --connect-timeout 10 --max-time 30 --max-filesize "$MAX_CATALOG_BYTES" --output "$dest" --write-out '%{http_code}' "$url") || return 1
      [ "$code" = 200 ] || return 1
      ;;
    *) return 1 ;;
  esac
  [ -s "$dest" ] || return 1
  [ "$(filesize "$dest")" -le "$MAX_CATALOG_BYTES" ] || return 1
  SOURCE_PATH=$dest
  SOURCE_KIND=official-github-tag
  SOURCE_URL="https://raw.githubusercontent.com/openai/codex/rust-v$SELECTED_VERSION/codex-rs/models-manager/models.json"
}

catalog_source() {
  SOURCE_URL=
  if [ -n "$CATALOG_FILE" ]; then
    case "$CATALOG_FILE" in /*) ;; *) return 1 ;; esac
    SOURCE_PATH=$(absolute_path "$CATALOG_FILE") || return 1
    SOURCE_KIND=local-file
  else
    download_catalog || return 2
  fi
  [ -f "$SOURCE_PATH" ] && [ ! -L "$SOURCE_PATH" ] || return 1
  size=$(filesize "$SOURCE_PATH") || return 1
  [ "$size" -gt 0 ] && [ "$size" -le "$MAX_CATALOG_BYTES" ] || return 1
}

lock_metadata_write() {
  out=$1
  /usr/bin/osascript -l JavaScript - "$out" "$$" "$(/bin/date +%s)" "$LOCK_NONCE" <<'JXA'
ObjC.import('Foundation');
function run(a) {
  let o = {pid:Number(a[1]), epoch:Number(a[2]), nonce:a[3]};
  let e = Ref();
  if (!$(JSON.stringify(o) + '\n').writeToFileAtomicallyEncodingError($(a[0]), true, $.NSUTF8StringEncoding, e)) throw Error('cannot write lock metadata');
}
JXA
}

release_lock() {
  [ -n "$LOCK_DIR" ] && [ -n "$LOCK_NONCE" ] || return 0
  lock="$LOCK_DIR/lock.json"
  owned_tmp="$LOCK_DIR/.lock.json.$LOCK_NONCE.tmp"
  if [ -e "$owned_tmp" ] || [ -L "$owned_tmp" ]; then
    if path_guard "$CODEX_ROOT" "$owned_tmp" inside >/dev/null 2>&1 && [ -f "$owned_tmp" ] && [ ! -L "$owned_tmp" ]; then
      owned_tmp_nonce=$(jxa_get "$owned_tmp" nonce 2>/dev/null || true)
      if [ "$owned_tmp_nonce" = "$LOCK_NONCE" ]; then /bin/rm -f "$owned_tmp" 2>/dev/null || true; fi
    fi
  fi
  if [ -f "$lock" ] && [ ! -L "$lock" ]; then
    nonce=$(jxa_get "$lock" nonce 2>/dev/null || true)
    if [ "$nonce" = "$LOCK_NONCE" ]; then
      /bin/rm -f "$lock"
      /bin/rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
  elif [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    /bin/rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  LOCK_DIR=
  LOCK_NONCE=
}

acquire_lock() {
  candidate="$CODEX_ROOT/provider-compat.lock.d"
  path_guard "$CODEX_ROOT" "$candidate" inside >/dev/null || return 1
  new_lock_nonce=$(new_nonce) || return 1
  if /bin/mkdir -m 700 "$candidate" 2>/dev/null; then
    :
  else
    [ -d "$candidate" ] && [ ! -L "$candidate" ] || return 1
    lock="$candidate/lock.json"
    now=$(/bin/date +%s)
    if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
      set -- "$candidate"/.lock.json.*.tmp
      if [ "$#" -eq 1 ] && [ "$1" != "$candidate/.lock.json.*.tmp" ] && [ -f "$1" ] && [ ! -L "$1" ]; then
        pending_lock=$1
        pending_pid=$(jxa_get "$pending_lock" pid 2>/dev/null || true)
        pending_nonce=$(jxa_get "$pending_lock" nonce 2>/dev/null || true)
        if printf '%s\n' "$pending_pid" | /usr/bin/awk '/^[0-9]+$/{ok=1}END{exit !ok}' &&
           printf '%s\n' "$pending_nonce" | /usr/bin/awk '/^[0-9a-f]+$/{if(length($0)==32)ok=1}END{exit !ok}' &&
           [ "$pending_lock" = "$candidate/.lock.json.$pending_nonce.tmp" ]; then
          if /bin/kill -0 "$pending_pid" 2>/dev/null; then return 1; fi
          /bin/rm -f "$pending_lock" || return 1
        else
          modified=$(/usr/bin/stat -f '%m' "$candidate" 2>/dev/null || printf '%s' "$now")
          [ $((now - modified)) -ge 1800 ] || return 1
          return 1
        fi
      else
        modified=$(/usr/bin/stat -f '%m' "$candidate" 2>/dev/null || printf '%s' "$now")
        [ $((now - modified)) -ge 1800 ] || return 1
      fi
      /bin/rmdir "$candidate" 2>/dev/null || return 1
    else
      [ -f "$lock" ] && [ ! -L "$lock" ] || return 1
      pid=$(jxa_get "$lock" pid 2>/dev/null || true)
      epoch=$(jxa_get "$lock" epoch 2>/dev/null || true)
      nonce=$(jxa_get "$lock" nonce 2>/dev/null || true)
      printf '%s\n' "$pid" | /usr/bin/awk '/^[0-9]+$/{ok=1}END{exit !ok}' || return 1
      printf '%s\n' "$epoch" | /usr/bin/awk '/^[0-9]+$/{ok=1}END{exit !ok}' || return 1
      printf '%s\n' "$nonce" | /usr/bin/awk '/^[0-9a-f]+$/{if(length($0)==32)ok=1}END{exit !ok}' || return 1
      if /bin/kill -0 "$pid" 2>/dev/null; then return 1; fi
      if ! transaction_exists; then
        orphan_tx_tmp=$(atomic_temp_path "$TX_PATH" "$nonce")
        [ ! -e "$orphan_tx_tmp" ] && [ ! -L "$orphan_tx_tmp" ] || remove_exact_atomic_temp "$orphan_tx_tmp" || return 1
      fi
      /bin/rm -f "$lock" || return 1
      /bin/rmdir "$candidate" 2>/dev/null || return 1
    fi
    /bin/mkdir -m 700 "$candidate" || return 1
  fi
  LOCK_DIR=$candidate
  LOCK_NONCE=$new_lock_nonce
  lock_tmp="$LOCK_DIR/.lock.json.$LOCK_NONCE.tmp"
  lock_metadata_write "$lock_tmp" || return 1
  /bin/mv "$lock_tmp" "$LOCK_DIR/lock.json" || return 1
  [ "$(jxa_get "$LOCK_DIR/lock.json" nonce)" = "$LOCK_NONCE" ] || return 1
}

confirm_write() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  [ "$YES" -eq 1 ] && return 0
  printf '%s' "$1 Continue? [y/N] "
  read ans || return 1
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

restart_notice() {
  info '完全退出并重新启动 Codex，然后新建任务/新 thread。'
  info '旧任务保留启动时的模型与工具快照，不会自动应用本次更改。'
}

config_fingerprint() {
  p=$1
  if [ -f "$p" ] && [ ! -L "$p" ]; then sha256 "$p"; else printf '%s\n' '<missing>'; fi
}

profile_check() {
  [ -d "$CODEX_ROOT" ] || return 0
  for p in "$CODEX_ROOT"/*.config.toml; do
    [ -f "$p" ] || continue
    [ "$p" = "$CODEX_ROOT/config.toml" ] && continue
    if [ -L "$p" ]; then
      warn "profile config is a symlink and was not inspected: ${p##*/}"
    else
      warn "profile config may override user config only when explicitly selected: ${p##*/}"
    fi
  done
}

transaction_exists() {
  [ -e "$TX_PATH" ] || [ -L "$TX_PATH" ]
}

validate_transaction_to_temp() {
  path_guard "$CODEX_ROOT" "$TX_PATH" inside >/dev/null || return 1
  [ -f "$TX_PATH" ] && [ ! -L "$TX_PATH" ] || return 1
  jxa_validate_transaction "$TX_PATH" "$CODEX_ROOT" > "$TMP_ROOT/transaction-safe.json" || return 1
}

write_transaction() {
  prepared="$TMP_ROOT/transaction.new"
  jxa_write_transaction "$prepared" "$@" || return 1
  atomic_install "$prepared" "$TX_PATH" "${TX_PRESERVE:-}" "$LOCK_NONCE" || return 1
  validate_transaction_to_temp
}

set_transaction_phase() {
  phase=$1
  jxa_update_transaction_phase "$TX_PATH" "$phase" "$TMP_ROOT/transaction.phase" || return 1
  atomic_install "$TMP_ROOT/transaction.phase" "$TX_PATH" "$TX_PATH" "$LOCK_NONCE" || return 1
  validate_transaction_to_temp
}

state_validate_to_temp() {
  state="$CODEX_ROOT/provider-compat-state.json"
  path_guard "$CODEX_ROOT" "$state" inside >/dev/null || return 1
  [ -f "$state" ] && [ ! -L "$state" ] || return 1
  jxa_validate_state "$state" "$CODEX_ROOT" "${1:-}" > "$TMP_ROOT/state-safe.json" || return 1
}

state_health_core() {
  selected=${1:-}
  state="$CODEX_ROOT/provider-compat-state.json"
  [ -e "$state" ] || [ -L "$state" ] || return 2
  state_validate_to_temp "$selected" || {
    if [ -n "$selected" ] && jxa_validate_state "$state" "$CODEX_ROOT" '' > "$TMP_ROOT/state-version-check.json" 2>/dev/null; then return 4; fi
    return 3
  }
  generated=$(jxa_get "$TMP_ROOT/state-safe.json" generated_catalog.path) || return 3
  expected=$(jxa_get "$TMP_ROOT/state-safe.json" generated_catalog.sha256) || return 3
  [ "$(filemode "$state")" = 600 ] || return 3
  path_guard "$CODEX_ROOT" "$generated" inside >/dev/null || return 3
  [ -f "$generated" ] && [ ! -L "$generated" ] || return 3
  [ "$(filemode "$generated")" = 600 ] || return 3
  [ "$(sha256 "$generated")" = "$expected" ] || return 3
  cmeta=$(jxa_catalog validate "$generated" 2>/dev/null) || return 3
  printf '%s' "$cmeta" > "$TMP_ROOT/status-catalog-meta.json"
  [ "$(jxa_get "$TMP_ROOT/status-catalog-meta.json" all_false)" = true ] || return 3
  [ "$(jxa_get "$TMP_ROOT/status-catalog-meta.json" model_count)" = "$(jxa_get "$TMP_ROOT/state-safe.json" source_catalog.model_count)" ] || return 3
  config="$CODEX_ROOT/config.toml"
  path_guard "$CODEX_ROOT" "$config" inside >/dev/null || return 3
  [ -f "$config" ] && [ ! -L "$config" ] || return 3
  original_mode=$(jxa_get "$TMP_ROOT/state-safe.json" config.original_mode)
  if [ -n "$original_mode" ]; then [ "$(filemode "$config")" = "$original_mode" ] || return 3; else [ "$(filemode "$config")" = 600 ] || return 3; fi
  backup=$(jxa_get "$TMP_ROOT/state-safe.json" config.backup_path)
  before=$(jxa_get "$TMP_ROOT/state-safe.json" config.before_sha256)
  if [ -n "$backup" ]; then
    path_guard "$CODEX_ROOT" "$backup" inside >/dev/null || return 3
    [ -f "$backup" ] && [ ! -L "$backup" ] && [ "$(sha256 "$backup")" = "$before" ] || return 3
    [ -z "$original_mode" ] || [ "$(filemode "$backup")" = "$original_mode" ] || return 3
  fi
  cache_backup=$(jxa_get "$TMP_ROOT/state-safe.json" cache.backup_path)
  cache_hash=$(jxa_get "$TMP_ROOT/state-safe.json" cache.sha256)
  if [ -n "$cache_backup" ]; then
    path_guard "$CODEX_ROOT" "$cache_backup" inside >/dev/null || return 3
    [ -f "$cache_backup" ] && [ ! -L "$cache_backup" ] && [ "$(sha256 "$cache_backup")" = "$cache_hash" ] || return 3
  fi
  meta=$(jxa_config analyze "$config" /dev/null 2>/dev/null) || return 3
  printf '%s' "$meta" > "$TMP_ROOT/status-config-meta.json"
  current=$(jxa_get "$TMP_ROOT/status-config-meta.json" current_catalog)
  [ "$current" = "$generated" ] || return 3
  if [ "$(jxa_get "$TMP_ROOT/state-safe.json" config.web_search_modified)" = true ]; then
    [ "$(jxa_get "$TMP_ROOT/status-config-meta.json" current_web_search)" = live ] || return 3
  fi
  return 0
}

maybe_fail() {
  stage=$1
  if [ "${CODEX_PROVIDER_COMPAT_TEST_SIGNAL_STAGE:-}" = "$stage" ]; then /bin/kill -TERM "$$"; fi
  if [ "${CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE:-}" = "$stage" ]; then /bin/kill -KILL "$$"; fi
  [ "${CODEX_PROVIDER_COMPAT_TEST_FAIL_STAGE:-}" != "$stage" ]
}

recover_apply_transaction() {
  tx="$TMP_ROOT/transaction-safe.json"
  state=$(jxa_get "$tx" paths.state)
  generated=$(jxa_get "$tx" paths.generated_catalog)
  config=$(jxa_get "$tx" paths.config)
  backup=$(jxa_get "$tx" paths.config_backup)
  cache=$(jxa_get "$tx" paths.cache_original)
  cache_backup=$(jxa_get "$tx" paths.cache_backup)
  before=$(jxa_get "$tx" hashes.config_before)
  after=$(jxa_get "$tx" hashes.config_after)
  genhash=$(jxa_get "$tx" hashes.generated_catalog)
  cachehash=$(jxa_get "$tx" hashes.cache)
  statehash=$(jxa_get "$tx" hashes.state)
  existed=$(jxa_get "$tx" flags.config_existed)
  version=$(jxa_get "$tx" codex_version)
  phase=$(jxa_get "$tx" phase)
  txnonce=$(jxa_get "$tx" nonce)
  preserve_config=${RECOVERY_PRESERVE_CONFIG:-0}
  if [ "$preserve_config" = 1 ]; then
    [ "$phase" = cache-backed-up ] || return 1
  fi
  if [ -e "$state" ] || [ -L "$state" ]; then
    if [ -f "$state" ] && [ ! -L "$state" ] && [ "$(sha256 "$state")" = "$statehash" ] && state_health_core "$version"; then
      cleanup_transaction_atomic_temps "$tx" || return 1
      /bin/rm -f "$TX_PATH"
      info 'recovery=completed-committed-apply'
      return 0
    fi
    warn 'transaction recovery found an unexpected state file'
    return 1
  fi
  if [ "$preserve_config" = 1 ]; then
    info 'recovery=preserving-external-config'
  elif [ -f "$config" ]; then
    current=$(sha256 "$config")
    if [ -n "$after" ] && [ "$current" = "$after" ]; then
      if [ "$existed" = true ]; then
        [ -f "$backup" ] && [ ! -L "$backup" ] && [ "$(sha256 "$backup")" = "$before" ] || return 1
        atomic_install "$backup" "$config" "$backup" "$txnonce" || return 1
      else
        /bin/rm -f "$config" || return 1
      fi
    elif [ "$existed" = true ] && [ "$current" = "$before" ]; then
      :
    else
      warn 'transaction recovery stopped because config has unrelated drift'
      return 1
    fi
  elif [ "$existed" = true ]; then
    [ -f "$backup" ] && [ "$(sha256 "$backup")" = "$before" ] || return 1
    atomic_install "$backup" "$config" "$backup" "$txnonce" || return 1
  fi
  if [ -n "$cache_backup" ]; then
    if [ -f "$cache_backup" ] && [ ! -L "$cache_backup" ]; then
      [ "$(sha256 "$cache_backup")" = "$cachehash" ] || return 1
      if [ -e "$cache" ] || [ -L "$cache" ]; then
        warn 'transaction recovery found both cache paths; preserving the journal'
        return 1
      fi
      /bin/mv -n "$cache_backup" "$cache" || return 1
      [ ! -e "$cache_backup" ] && [ -f "$cache" ] && [ "$(sha256 "$cache")" = "$cachehash" ] || return 1
    else
      [ ! -e "$cache_backup" ] && [ ! -L "$cache_backup" ] && [ -f "$cache" ] && [ ! -L "$cache" ] && [ "$(sha256 "$cache")" = "$cachehash" ] || return 1
    fi
  fi
  if [ -e "$generated" ] || [ -L "$generated" ]; then
    remove_owned_temp "$generated" "$genhash" || return 1
  fi
  if [ -n "$backup" ] && [ -e "$backup" ]; then
    [ -f "$backup" ] && [ ! -L "$backup" ] && [ "$(sha256 "$backup")" = "$before" ] || return 1
    /bin/rm -f "$backup" || return 1
  fi
  cleanup_transaction_atomic_temps "$tx" || return 1
  /bin/rm -f "$TX_PATH" || return 1
  if [ "$preserve_config" = 1 ]; then
    info 'recovery=restored-apply-owned-state-preserved-external-config'
  else
    info 'recovery=restored-pre-apply-state'
  fi
}

recover_rollback_transaction() {
  tx="$TMP_ROOT/transaction-safe.json"
  phase=$(jxa_get "$tx" phase)
  config=$(jxa_get "$tx" paths.config)
  snapshot=$(jxa_get "$tx" paths.config_snapshot)
  generated=$(jxa_get "$tx" paths.generated_catalog)
  pending=$(jxa_get "$tx" paths.generated_catalog_pending)
  cache=$(jxa_get "$tx" paths.cache_original)
  cache_backup=$(jxa_get "$tx" paths.cache_backup)
  state=$(jxa_get "$tx" paths.state)
  archive=$(jxa_get "$tx" paths.state_archive)
  before=$(jxa_get "$tx" hashes.config_before)
  after=$(jxa_get "$tx" hashes.config_after)
  genhash=$(jxa_get "$tx" hashes.generated_catalog)
  cachehash=$(jxa_get "$tx" hashes.cache)
  statehash=$(jxa_get "$tx" hashes.state)
  delete_config=$(jxa_get "$tx" flags.config_should_delete)
  generated_owned=$(jxa_get "$tx" flags.generated_catalog_owned)
  cache_restorable=$(jxa_get "$tx" flags.cache_should_restore)
  preserve_config=${RECOVERY_PRESERVE_CONFIG:-0}
  if [ "$preserve_config" = 1 ]; then
    [ "$phase" = cache-restored ] || return 1
    [ -f "$state" ] && [ ! -L "$state" ] && [ "$(sha256 "$state")" = "$statehash" ] || return 1
    [ -f "$snapshot" ] && [ ! -L "$snapshot" ] && [ "$(sha256 "$snapshot")" = "$before" ] || return 1
  fi
  if [ "$phase" = state-archived ]; then
    [ ! -e "$state" ] && [ -f "$archive" ] && [ ! -L "$archive" ] && [ "$(sha256 "$archive")" = "$statehash" ] || return 1
    jxa_validate_state "$archive" "$CODEX_ROOT" '' >/dev/null || return 1
    if [ "$delete_config" = true ]; then
      [ ! -e "$config" ] && [ ! -L "$config" ] || return 1
    else
      [ -f "$config" ] && [ ! -L "$config" ] && [ "$(sha256 "$config")" = "$after" ] || return 1
    fi
    if [ "$cache_restorable" = true ]; then
      [ -f "$cache" ] && [ ! -L "$cache" ] && [ "$(sha256 "$cache")" = "$cachehash" ] && [ ! -e "$cache_backup" ] || return 1
    fi
    [ ! -e "$pending" ] || remove_owned_temp "$pending" "$genhash" || return 1
    [ ! -e "$snapshot" ] || remove_owned_temp "$snapshot" "$before" || return 1
    cleanup_transaction_atomic_temps "$tx" || return 1
    /bin/rm -f "$TX_PATH" || return 1
    info 'recovery=completed-committed-rollback'
    return 0
  fi
  if [ ! -e "$state" ] && [ -f "$archive" ] && [ ! -L "$archive" ]; then
    [ "$(sha256 "$archive")" = "$statehash" ] || return 1
    /bin/mv -n "$archive" "$state" || return 1
    [ ! -e "$archive" ] && [ -f "$state" ] || return 1
  elif [ -e "$state" ] && [ -e "$archive" ]; then
    return 1
  fi
  if [ "$cache_restorable" = true ]; then
    if [ ! -e "$cache_backup" ] && [ ! -L "$cache_backup" ] && [ -f "$cache" ] && [ ! -L "$cache" ] && [ "$(sha256 "$cache")" = "$cachehash" ]; then
      /bin/mv -n "$cache" "$cache_backup" || return 1
      [ ! -e "$cache" ] && [ -f "$cache_backup" ] && [ "$(sha256 "$cache_backup")" = "$cachehash" ] || return 1
    else
      [ -f "$cache_backup" ] && [ ! -L "$cache_backup" ] && [ "$(sha256 "$cache_backup")" = "$cachehash" ] && [ ! -e "$cache" ] && [ ! -L "$cache" ] || return 1
    fi
  fi
  if [ "$preserve_config" = 1 ]; then
    info 'recovery=preserving-external-config'
  elif [ -f "$snapshot" ] && [ ! -L "$snapshot" ]; then
    [ "$(sha256 "$snapshot")" = "$before" ] || return 1
    if [ -f "$config" ]; then
      current=$(sha256 "$config")
      if [ "$current" = "$after" ] || [ "$current" = "$before" ]; then
        /bin/mv -f "$snapshot" "$config" || return 1
      else
        warn 'transaction recovery stopped because config has unrelated drift'
        return 1
      fi
    elif [ "$delete_config" = true ]; then
      /bin/mv "$snapshot" "$config" || return 1
    else
      return 1
    fi
  elif [ ! -f "$config" ] || [ "$(sha256 "$config")" != "$before" ]; then
    return 1
  fi
  if [ "$generated_owned" = true ]; then
    if [ -f "$pending" ] && [ ! -L "$pending" ]; then
      [ "$(sha256 "$pending")" = "$genhash" ] || return 1
      [ ! -e "$generated" ] && [ ! -L "$generated" ] || return 1
      /bin/mv -n "$pending" "$generated" || return 1
      [ ! -e "$pending" ] && [ -f "$generated" ] && [ "$(sha256 "$generated")" = "$genhash" ] || return 1
    elif [ ! -f "$generated" ] || [ "$(sha256 "$generated")" != "$genhash" ]; then
      return 1
    fi
  fi
  if [ "$preserve_config" = 1 ]; then
    remove_owned_temp "$snapshot" "$before" || return 1
  fi
  cleanup_transaction_atomic_temps "$tx" || return 1
  /bin/rm -f "$TX_PATH" || return 1
  if [ "$preserve_config" = 1 ]; then
    info 'recovery=restored-rollback-owned-state-preserved-external-config'
  else
    info 'recovery=restored-pre-rollback-state'
  fi
}

recover_transaction() {
  transaction_exists || return 0
  validate_transaction_to_temp || { warn 'transaction journal is corrupt or unsafe'; return 1; }
  for k in config config_backup config_snapshot generated_catalog generated_catalog_pending cache_original cache_backup state state_archive; do
    p=$(jxa_get "$TMP_ROOT/transaction-safe.json" "paths.$k")
    [ -z "$p" ] || path_guard "$CODEX_ROOT" "$p" inside >/dev/null || return 1
  done
  cleanup_transaction_atomic_temps "$TMP_ROOT/transaction-safe.json" || return 1
  operation=$(jxa_get "$TMP_ROOT/transaction-safe.json" operation)
  case "$operation" in
    apply) recover_apply_transaction ;;
    rollback) recover_rollback_transaction ;;
    *) return 1 ;;
  esac
}

recover_transaction_preserving_config() {
  RECOVERY_PRESERVE_CONFIG=1
  recover_transaction
  rc=$?
  RECOVERY_PRESERVE_CONFIG=0
  return "$rc"
}

cleanup() {
  release_lock
  /bin/rm -f "$TMP_ROOT"/* "$TMP_ROOT"/.[!.]* "$TMP_ROOT"/..?* 2>/dev/null || true
  /bin/rmdir "$TMP_ROOT" 2>/dev/null || true
}

on_signal() {
  code=$1
  [ "$SIGNALLED" -eq 0 ] || exit "$code"
  SIGNALLED=1
  trap - HUP INT TERM
  warn 'interrupted; attempting transaction recovery'
  if [ -n "$LOCK_DIR" ] && transaction_exists; then recover_transaction || warn 'automatic recovery requires another apply/rollback run'; fi
  cleanup
  exit "$code"
}

prepare_apply_config() {
  config="$CODEX_ROOT/config.toml"
  path_guard "$CODEX_ROOT" "$config" inside >/dev/null || return 1
  if [ -e "$config" ] || [ -L "$config" ]; then [ -f "$config" ] && [ ! -L "$config" ] || return 1; fi
  meta=$(jxa_config apply "$config" "$TMP_ROOT/config.apply" "$generated" "$ENABLE_WEB_SEARCH") || return 1
  printf '%s' "$meta" > "$TMP_ROOT/config-meta.json"
  PREPARED_CONFIG_HASH=$(config_fingerprint "$config")
  PREPARED_AFTER_HASH=$(sha256 "$TMP_ROOT/config.apply") || return 1
}

doctor() {
  info "tool_version=$TOOL_VERSION patch_id=$PATCH_ID"
  info "os=$(uname -s) codex_home=$CODEX_ROOT"
  if transaction_exists; then
    path_guard "$CODEX_ROOT" "$TX_PATH" inside >/dev/null 2>&1 || { info 'result=unsafe'; return $EX_UNSAFE; }
    info 'result=recovery-required'
    return $EX_UNSAFE
  fi
  discover_versions
  show_versions
  warn_running_codex
  if ! select_version; then
    count=$(/usr/bin/awk -F '\t' '$3!=""&&!seen[$3]++{n++}END{print n+0}' "$TMP_ROOT/versions")
    warn 'could not select one Codex version'
    if [ "$count" -eq 0 ]; then info 'result=unknown'; else info 'result=unsafe'; fi
    return $EX_UNSAFE
  fi
  config="$CODEX_ROOT/config.toml"
  path_guard "$CODEX_ROOT" "$config" inside >/dev/null || { info 'result=unsafe'; return $EX_UNSAFE; }
  meta=$(jxa_config analyze "$config" /dev/null) || { warn 'unsafe or unsupported config'; info 'result=unsafe'; return $EX_UNSAFE; }
  printf '%s' "$meta" > "$TMP_ROOT/meta.json"
  for k in current_model current_provider current_catalog current_web_search; do info "$k=$(jxa_get "$TMP_ROOT/meta.json" "$k")"; done
  if [ -f "$CODEX_ROOT/models_cache.json" ] && [ ! -L "$CODEX_ROOT/models_cache.json" ]; then info 'models_cache=present'; else info 'models_cache=missing'; fi
  configured_catalog=$(jxa_get "$TMP_ROOT/meta.json" current_catalog)
  if [ -n "$configured_catalog" ]; then
    case "$configured_catalog" in
      /*)
        configured_catalog_path=$(absolute_path "$configured_catalog" 2>/dev/null || true)
        if [ -n "$configured_catalog_path" ] && [ -f "$configured_catalog_path" ] && [ ! -L "$configured_catalog_path" ] &&
           [ "$(filesize "$configured_catalog_path")" -le "$MAX_CATALOG_BYTES" ]; then
          configured_meta=$(jxa_catalog validate "$configured_catalog_path" 2>/dev/null || true)
          if [ -n "$configured_meta" ]; then
            printf '%s' "$configured_meta" > "$TMP_ROOT/configured-catalog-meta.json"
            info "configured_catalog_models=$(jxa_get "$TMP_ROOT/configured-catalog-meta.json" model_count) configured_catalog_targets_all_false=$(jxa_get "$TMP_ROOT/configured-catalog-meta.json" all_false)"
          else
            warn 'configured model catalog is invalid or incomplete'
          fi
        else
          warn 'configured model catalog is missing, oversized, or unsafe'
        fi
        ;;
      *) warn 'configured model catalog path is not absolute' ;;
    esac
  fi
  profile_check
  if [ -e "$CODEX_ROOT/provider-compat-state.json" ] || [ -L "$CODEX_ROOT/provider-compat-state.json" ]; then
    state_health_core "$SELECTED_VERSION"
    rc=$?
    case "$rc" in
      0) info 'result=already-applied'; return 0 ;;
      4) info 'result=stale'; return $EX_STALE ;;
      *) info 'result=unsafe'; return $EX_UNSAFE ;;
    esac
  fi
  catalog_source
  rc=$?
  [ "$rc" -eq 0 ] || { [ "$rc" -eq 2 ] && return $EX_NETWORK; return $EX_UNSAFE; }
  cmeta=$(jxa_catalog validate "$SOURCE_PATH") || {
    warn 'catalog validation failed'
    [ "$SOURCE_KIND" = official-github-tag ] && return $EX_STALE
    return $EX_UNSAFE
  }
  printf '%s' "$cmeta" > "$TMP_ROOT/catalog-meta.json"
  info "catalog_source=$SOURCE_KIND models=$(jxa_get "$TMP_ROOT/catalog-meta.json" model_count) sha256=$(sha256 "$SOURCE_PATH")"
  other=$(jxa_get "$TMP_ROOT/catalog-meta.json" other_lite)
  [ -z "$other" ] || info "unverified_lite_models=$other"
  model=$(jxa_get "$TMP_ROOT/meta.json" current_model)
  provider=$(jxa_get "$TMP_ROOT/meta.json" current_provider)
  if [ -z "$model" ] || [ -z "$provider" ]; then info 'result=unknown'; return $EX_UNSAFE; fi
  case " $TARGETS " in *" $model "*) ;; *) info 'result=not-needed'; return $EX_NOT_APPLICABLE ;; esac
  case "$provider" in
    openai)
      if [ "$(jxa_get "$TMP_ROOT/meta.json" openai_base_url_present)" = true ] ||
         [ "$(jxa_get "$TMP_ROOT/meta.json" openai_provider_table_present)" = true ]; then
        info 'provider_scope=openai-overridden-or-ambiguous'
        info 'result=unknown'
        return $EX_UNSAFE
      fi
      info 'provider_scope=official'
      info 'result=not-needed'
      return $EX_NOT_APPLICABLE
      ;;
  esac
  [ "$(jxa_get "$TMP_ROOT/catalog-meta.json" all_false)" = true ] && { info 'result=not-needed'; return $EX_NOT_APPLICABLE; }
  info 'capability_risk=hosted-web-search,exec-shell,code-mode,function-mcp,dynamic-tools,collaboration,image-extension'
  info 'result=applicable'
  return 0
}

status_cmd() {
  if transaction_exists; then info 'result=recovery-required'; return $EX_UNSAFE; fi
  discover_versions
  show_versions
  warn_running_codex
  if select_version; then
    :
  else
    count=$(/usr/bin/awk -F '\t' '$3!=""&&!seen[$3]++{n++}END{print n+0}' "$TMP_ROOT/versions")
    if [ "$count" -eq 0 ]; then info 'result=unknown'; else info 'result=unsafe'; fi
    return $EX_UNSAFE
  fi
  state_health_core "$SELECTED_VERSION"
  rc=$?
  case "$rc" in
    0)
      other=$(jxa_get "$TMP_ROOT/status-catalog-meta.json" other_lite)
      [ -z "$other" ] || info "unverified_lite_models=$other"
      profile_check
      info 'result=healthy'
      ;;
    2) info 'result=not-applied' ;;
    4) info 'result=stale' ;;
    *) info 'result=unsafe' ;;
  esac
  return "$rc"
}

apply_cmd() {
  discover_versions
  show_versions
  warn_running_codex
  select_version || { warn 'conflicting or missing Codex version; use --codex-version'; return $EX_UNSAFE; }
  if transaction_exists; then
    [ "$DRY_RUN" -eq 0 ] || { info 'result=recovery-required'; return $EX_UNSAFE; }
    ensure_home || return $EX_UNSAFE
    acquire_lock || return $EX_UNSAFE
    recover_transaction || return $EX_UNSAFE
  fi
  if [ -e "$CODEX_ROOT/provider-compat-state.json" ] || [ -L "$CODEX_ROOT/provider-compat-state.json" ]; then
    state_health_core "$SELECTED_VERSION"
    rc=$?
    [ "$rc" -eq 0 ] && { info 'result=already-applied'; return 0; }
    [ "$rc" -eq 4 ] && { warn 'existing patch belongs to a different Codex version; run rollback, then apply for the new version'; return $EX_STALE; }
    warn 'existing patch state is not healthy; rollback first'
    return $EX_UNSAFE
  fi
  catalog_source
  rc=$?
  [ "$rc" -eq 0 ] || { [ "$rc" -eq 2 ] && return $EX_NETWORK; return $EX_UNSAFE; }
  cmeta=$(jxa_catalog validate "$SOURCE_PATH") || {
    warn 'catalog validation failed'
    [ "$SOURCE_KIND" = official-github-tag ] && return $EX_STALE
    return $EX_UNSAFE
  }
  printf '%s' "$cmeta" > "$TMP_ROOT/catalog-meta.json"
  [ "$(jxa_get "$TMP_ROOT/catalog-meta.json" all_false)" = true ] && { info 'result=not-needed'; return $EX_NOT_APPLICABLE; }
  generated="$CODEX_ROOT/model-catalogs/models-$SELECTED_VERSION.standard-responses-compat.json"
  path_guard "$CODEX_ROOT" "$generated" inside >/dev/null || return $EX_UNSAFE
  jxa_catalog patch "$SOURCE_PATH" "$TMP_ROOT/catalog.patched" >/dev/null || return $EX_UNSAFE
  jxa_catalog validate "$TMP_ROOT/catalog.patched" >/dev/null || return $EX_UNSAFE
  prepare_apply_config || { warn 'config validation failed'; return $EX_UNSAFE; }
  info "plan: generate $generated"
  info "plan: backup and update $CODEX_ROOT/config.toml"
  if [ "$DRY_RUN" -eq 1 ]; then info 'result=dry-run (zero writes)'; return 0; fi
  confirm_write 'Apply responses-lite-standard-tools?' || return $EX_ERROR
  ensure_home || return $EX_UNSAFE
  [ -n "$LOCK_DIR" ] || acquire_lock || return $EX_UNSAFE
  recover_transaction || return $EX_UNSAFE
  current_hash=$(config_fingerprint "$CODEX_ROOT/config.toml")
  if [ "${CODEX_PROVIDER_COMPAT_TEST_TOCTOU:-}" = once ] || [ "${CODEX_PROVIDER_COMPAT_TEST_TOCTOU:-}" = twice ]; then
    printf '%s\n' '# concurrent test edit 1' >> "$CODEX_ROOT/config.toml"
    current_hash=$(config_fingerprint "$CODEX_ROOT/config.toml")
  fi
  if [ "$current_hash" != "$PREPARED_CONFIG_HASH" ]; then
    warn 'config changed after confirmation; rebuilding the plan'
    prepare_apply_config || return $EX_UNSAFE
    second_hash=$PREPARED_CONFIG_HASH
    confirm_write 'Config changed; apply the rebuilt plan?' || return $EX_ERROR
    if [ "${CODEX_PROVIDER_COMPAT_TEST_TOCTOU:-}" = twice ]; then printf '%s\n' '# concurrent test edit 2' >> "$CODEX_ROOT/config.toml"; fi
    [ "$(config_fingerprint "$CODEX_ROOT/config.toml")" = "$second_hash" ] || { warn 'config changed again; refusing to overwrite it'; return $EX_UNSAFE; }
  fi
  ensure_catalog_dir || return $EX_UNSAFE
  [ ! -e "$generated" ] && [ ! -L "$generated" ] || { warn 'generated catalog exists without healthy state'; return $EX_UNSAFE; }
  stamp=$(timestamp)
  config="$CODEX_ROOT/config.toml"
  existed=$(jxa_get "$TMP_ROOT/config-meta.json" exists)
  backup=
  before_sha=
  original_mode=
  if [ "$existed" = true ]; then
    backup=$(unique_path "$CODEX_ROOT/config.toml.bak-provider-compat-$stamp")
    path_guard "$CODEX_ROOT" "$backup" inside >/dev/null || return $EX_UNSAFE
    before_sha=$(sha256 "$config")
    original_mode=$(filemode "$config")
  fi
  cache="$CODEX_ROOT/models_cache.json"
  cache_backup=
  cache_hash=
  if [ -e "$cache" ] || [ -L "$cache" ]; then
    path_guard "$CODEX_ROOT" "$cache" inside >/dev/null || return $EX_UNSAFE
    [ -f "$cache" ] && [ ! -L "$cache" ] || return $EX_UNSAFE
    cache_backup=$(unique_path "$CODEX_ROOT/models_cache.json.bak-provider-compat-$stamp")
    cache_hash=$(sha256 "$cache")
  fi
  [ "$(config_fingerprint "$config")" = "$PREPARED_CONFIG_HASH" ] || { warn 'config changed before transaction start'; return $EX_UNSAFE; }
  if [ -n "$cache_hash" ]; then
    [ -f "$cache" ] && [ ! -L "$cache" ] && [ "$(sha256 "$cache")" = "$cache_hash" ] || { warn 'cache changed before transaction start'; return $EX_UNSAFE; }
  else
    [ ! -e "$cache" ] && [ ! -L "$cache" ] || { warn 'cache appeared before transaction start'; return $EX_UNSAFE; }
  fi
  [ ! -e "$generated" ] && [ ! -L "$generated" ] && [ ! -e "$CODEX_ROOT/provider-compat-state.json" ] && [ ! -L "$CODEX_ROOT/provider-compat-state.json" ] || return $EX_UNSAFE
  generated_sha=$(sha256 "$TMP_ROOT/catalog.patched")
  state="$CODEX_ROOT/provider-compat-state.json"
  source_sha=$(sha256 "$SOURCE_PATH")
  model_count=$(jxa_get "$TMP_ROOT/catalog-meta.json" model_count)
  jxa_write_state "$TMP_ROOT/config-meta.json" "$TMP_ROOT/catalog-meta.json" "$TMP_ROOT/state.new" "$TOOL_VERSION" "$PATCH_ID" "$SELECTED_VERSION" "$SOURCE_KIND" "$SOURCE_URL" "$SOURCE_PATH" "$source_sha" "$model_count" "$generated" "$generated_sha" "$config" "$backup" "$before_sha" "$original_mode" "$ENABLE_WEB_SEARCH" "$cache" "$cache_backup" "$cache_hash" || return $EX_UNSAFE
  state_sha=$(sha256 "$TMP_ROOT/state.new")
  write_transaction apply prepared "$LOCK_NONCE" "$CODEX_ROOT" "$SELECTED_VERSION" "$config" "$backup" '' "$generated" '' "$cache" "$cache_backup" "$state" '' "$before_sha" "$PREPARED_AFTER_HASH" "$generated_sha" "$cache_hash" "$state_sha" "$([ "$existed" = true ] && printf 1 || printf 0)" 0 0 0 || return $EX_UNSAFE
  maybe_fail after-journal || { recover_transaction; return $EX_UNSAFE; }
  if [ "$existed" = true ]; then
    /bin/cp -p "$config" "$backup" || { recover_transaction; return $EX_UNSAFE; }
    [ "$(sha256 "$backup")" = "$before_sha" ] || { recover_transaction; return $EX_UNSAFE; }
  fi
  set_transaction_phase config-backed-up || { recover_transaction; return $EX_UNSAFE; }
  maybe_fail after-backup || { recover_transaction; return $EX_UNSAFE; }
  atomic_install "$TMP_ROOT/catalog.patched" "$generated" '' "$LOCK_NONCE" || { recover_transaction; return $EX_UNSAFE; }
  jxa_catalog validate "$generated" >/dev/null || { recover_transaction; return $EX_UNSAFE; }
  set_transaction_phase generated-catalog-written || { recover_transaction; return $EX_UNSAFE; }
  maybe_fail after-catalog || { recover_transaction; return $EX_UNSAFE; }
  if [ -n "$cache_backup" ]; then
    [ ! -e "$cache_backup" ] && [ ! -L "$cache_backup" ] || { recover_transaction; return $EX_UNSAFE; }
    /bin/mv -n "$cache" "$cache_backup" || { recover_transaction; return $EX_UNSAFE; }
    [ ! -e "$cache" ] && [ -f "$cache_backup" ] && [ "$(sha256 "$cache_backup")" = "$cache_hash" ] || { recover_transaction; return $EX_UNSAFE; }
  fi
  set_transaction_phase cache-backed-up || { recover_transaction; return $EX_UNSAFE; }
  maybe_fail after-cache || { recover_transaction; return $EX_UNSAFE; }
  case "${CODEX_PROVIDER_COMPAT_TEST_MUTATE_CONFIG_BEFORE_WRITE:-}" in
    1|apply) printf '%s\n' '# late-external-change apply' >> "$config" ;;
  esac
  if [ "$(config_fingerprint "$config")" != "$PREPARED_CONFIG_HASH" ]; then
    warn 'config changed immediately before the atomic write; preserving the external edit'
    recover_transaction_preserving_config || warn 'automatic recovery could not fully restore apply-owned files'
    return $EX_UNSAFE
  fi
  maybe_fail config-write || { recover_transaction; return $EX_UNSAFE; }
  preserve=
  [ "$existed" = true ] && preserve=$config
  atomic_install "$TMP_ROOT/config.apply" "$config" "$preserve" "$LOCK_NONCE" || { recover_transaction; return $EX_UNSAFE; }
  [ "$(sha256 "$config")" = "$PREPARED_AFTER_HASH" ] || { recover_transaction; return $EX_UNSAFE; }
  set_transaction_phase config-written || { recover_transaction; return $EX_UNSAFE; }
  maybe_fail after-config || { recover_transaction; return $EX_UNSAFE; }
  maybe_fail state-write || { recover_transaction; return $EX_UNSAFE; }
  atomic_install "$TMP_ROOT/state.new" "$state" '' "$LOCK_NONCE" || { recover_transaction; return $EX_UNSAFE; }
  state_health_core "$SELECTED_VERSION" || { recover_transaction; return $EX_UNSAFE; }
  set_transaction_phase state-written || { recover_transaction; return $EX_UNSAFE; }
  maybe_fail after-state || { recover_transaction; return $EX_UNSAFE; }
  /bin/rm -f "$TX_PATH" || return $EX_UNSAFE
  info 'result=applied'
  restart_notice
  return 0
}

rollback_cmd() {
  if transaction_exists; then
    [ "$DRY_RUN" -eq 0 ] || { info 'result=recovery-required'; return $EX_UNSAFE; }
    ensure_home || return $EX_UNSAFE
    acquire_lock || return $EX_UNSAFE
    recover_transaction || return $EX_UNSAFE
  fi
  state="$CODEX_ROOT/provider-compat-state.json"
  [ -e "$state" ] || [ -L "$state" ] || { info 'result=not-applied'; return $EX_NOT_APPLICABLE; }
  state_validate_to_temp '' || return $EX_UNSAFE
  config=$(jxa_get "$TMP_ROOT/state-safe.json" config.path)
  generated=$(jxa_get "$TMP_ROOT/state-safe.json" generated_catalog.path)
  cache=$(jxa_get "$TMP_ROOT/state-safe.json" cache.original_path)
  cache_backup=$(jxa_get "$TMP_ROOT/state-safe.json" cache.backup_path)
  for p in "$config" "$generated" "$cache" "$state"; do path_guard "$CODEX_ROOT" "$p" inside >/dev/null || return $EX_UNSAFE; done
  [ -z "$cache_backup" ] || path_guard "$CODEX_ROOT" "$cache_backup" inside >/dev/null || return $EX_UNSAFE
  out="$TMP_ROOT/config.rollback"
  rmeta=$(jxa_config rollback "$config" "$out" '' 0 "$TMP_ROOT/state-safe.json") || { warn 'owned config keys drifted'; return $EX_UNSAFE; }
  printf '%s' "$rmeta" > "$TMP_ROOT/rollback-meta.json"
  before_confirm=$(config_fingerprint "$config")
  state_before_confirm=$(sha256 "$state")
  info "plan: restore tool-owned keys in $config"
  if [ "$DRY_RUN" -eq 1 ]; then info 'result=dry-run (zero writes)'; return 0; fi
  confirm_write 'Rollback responses-lite-standard-tools?' || return $EX_ERROR
  ensure_home || return $EX_UNSAFE
  [ -n "$LOCK_DIR" ] || acquire_lock || return $EX_UNSAFE
  recover_transaction || return $EX_UNSAFE
  [ "$(sha256 "$state")" = "$state_before_confirm" ] || { warn 'state changed after confirmation'; return $EX_UNSAFE; }
  if [ "$(config_fingerprint "$config")" != "$before_confirm" ]; then
    warn 'config changed after confirmation; rebuilding the rollback plan'
    rmeta=$(jxa_config rollback "$config" "$out" '' 0 "$TMP_ROOT/state-safe.json") || return $EX_UNSAFE
    printf '%s' "$rmeta" > "$TMP_ROOT/rollback-meta.json"
    before_confirm=$(config_fingerprint "$config")
    confirm_write 'Config changed; apply the rebuilt rollback plan?' || return $EX_ERROR
    [ "$(config_fingerprint "$config")" = "$before_confirm" ] || { warn 'config changed again; refusing to overwrite it'; return $EX_UNSAFE; }
  fi
  LOCK_NONCE=${LOCK_NONCE:-$(new_nonce)}
  snapshot="$CODEX_ROOT/.provider-compat-rollback-$LOCK_NONCE.config"
  pending="$generated.rollback-pending-$LOCK_NONCE"
  archive=$(unique_path "$CODEX_ROOT/provider-compat-state.json.rolled-back-$(timestamp)")
  for p in "$snapshot" "$pending" "$archive"; do path_guard "$CODEX_ROOT" "$p" inside >/dev/null || return $EX_UNSAFE; done
  config_before=$(sha256 "$config")
  config_after=$(sha256 "$out")
  config_mode_before=$(filemode "$config")
  state_hash=$(sha256 "$state")
  expected_generated_hash=$(jxa_get "$TMP_ROOT/state-safe.json" generated_catalog.sha256)
  if [ -f "$generated" ] && [ ! -L "$generated" ]; then generated_before_actual=$(sha256 "$generated"); transaction_generated_hash=$generated_before_actual; else generated_before_actual='<missing>'; transaction_generated_hash=; fi
  cache_hash=$(jxa_get "$TMP_ROOT/state-safe.json" cache.sha256)
  cache_backup_present=0
  [ -n "$cache_backup" ] && [ -f "$cache_backup" ] && [ ! -L "$cache_backup" ] && cache_backup_present=1
  delete_config=0
  [ "$(jxa_get "$TMP_ROOT/state-safe.json" config.existed)" = false ] && [ "$(jxa_get "$TMP_ROOT/rollback-meta.json" result_empty)" = true ] && delete_config=1
  transaction_config_after=$config_after
  [ "$delete_config" -eq 1 ] && transaction_config_after=
  generated_owned=0
  [ "$generated_before_actual" != '<missing>' ] && [ "$generated_before_actual" = "$expected_generated_hash" ] && generated_owned=1
  cache_restorable=0
  [ -n "$cache_backup" ] && [ -f "$cache_backup" ] && [ ! -L "$cache_backup" ] && [ ! -e "$cache" ] && [ ! -L "$cache" ] && [ "$(sha256 "$cache_backup")" = "$cache_hash" ] && cache_restorable=1
  [ "$(config_fingerprint "$config")" = "$config_before" ] && [ "$(sha256 "$state")" = "$state_hash" ] || { warn 'rollback inputs changed before transaction start'; return $EX_UNSAFE; }
  if [ "$generated_before_actual" = '<missing>' ]; then
    [ ! -e "$generated" ] && [ ! -L "$generated" ] || return $EX_UNSAFE
  else
    [ -f "$generated" ] && [ ! -L "$generated" ] && [ "$(sha256 "$generated")" = "$generated_before_actual" ] || return $EX_UNSAFE
  fi
  write_transaction rollback prepared "$LOCK_NONCE" "$CODEX_ROOT" "$(jxa_get "$TMP_ROOT/state-safe.json" codex_version)" "$config" '' "$snapshot" "$generated" "$pending" "$cache" "$cache_backup" "$state" "$archive" "$config_before" "$transaction_config_after" "$transaction_generated_hash" "$cache_hash" "$state_hash" 1 "$delete_config" "$generated_owned" "$cache_restorable" || return $EX_UNSAFE
  maybe_fail rollback-after-journal || { recover_transaction; return $EX_UNSAFE; }
  /bin/cp -p "$config" "$snapshot" || { recover_transaction; return $EX_UNSAFE; }
  [ "$(sha256 "$snapshot")" = "$config_before" ] || { recover_transaction; return $EX_UNSAFE; }
  set_transaction_phase config-snapshotted || { recover_transaction; return $EX_UNSAFE; }
  maybe_fail rollback-after-config-save || { recover_transaction; return $EX_UNSAFE; }
  if [ "$generated_owned" -eq 1 ]; then
    [ ! -e "$pending" ] && [ ! -L "$pending" ] || { recover_transaction; return $EX_UNSAFE; }
    /bin/mv -n "$generated" "$pending" || { recover_transaction; return $EX_UNSAFE; }
    [ ! -e "$generated" ] && [ -f "$pending" ] && [ "$(sha256 "$pending")" = "$expected_generated_hash" ] || { recover_transaction; return $EX_UNSAFE; }
  elif [ -e "$generated" ] || [ -L "$generated" ]; then
    warn 'generated catalog hash drifted; preserving it'
  fi
  set_transaction_phase generated-catalog-pending || { recover_transaction; return $EX_UNSAFE; }
  maybe_fail rollback-after-catalog || { recover_transaction; return $EX_UNSAFE; }
  if [ -n "$cache_backup" ] && [ -f "$cache_backup" ]; then
    if [ "$cache_restorable" -eq 1 ]; then
      /bin/mv -n "$cache_backup" "$cache" || { recover_transaction; return $EX_UNSAFE; }
    elif [ -e "$cache" ] || [ -L "$cache" ]; then
      warn 'a new models_cache.json exists; preserving both'
    else
      warn 'cache backup hash drifted; preserving it'
    fi
  fi
  if [ "$cache_restorable" -eq 1 ]; then
    [ -f "$cache" ] && [ ! -L "$cache" ] && [ "$(sha256 "$cache")" = "$cache_hash" ] && [ ! -e "$cache_backup" ] || { recover_transaction; return $EX_UNSAFE; }
  elif [ "$cache_backup_present" -eq 1 ]; then
    [ -f "$cache_backup" ] && [ ! -L "$cache_backup" ] || { recover_transaction; return $EX_UNSAFE; }
  fi
  set_transaction_phase cache-restored || { recover_transaction; return $EX_UNSAFE; }
  maybe_fail rollback-after-cache || { recover_transaction; return $EX_UNSAFE; }
  case "${CODEX_PROVIDER_COMPAT_TEST_MUTATE_CONFIG_BEFORE_WRITE:-}" in
    1|rollback) printf '%s\n' '# late-external-change rollback' >> "$config" ;;
  esac
  if [ "$(config_fingerprint "$config")" != "$config_before" ]; then
    warn 'config changed immediately before the rollback write; preserving the external edit'
    recover_transaction_preserving_config || warn 'automatic recovery could not fully restore rollback-owned files'
    return $EX_UNSAFE
  fi
  maybe_fail rollback-config-write || { recover_transaction; return $EX_UNSAFE; }
  if [ "$delete_config" -eq 1 ]; then
    /bin/rm -f "$config" || { recover_transaction; return $EX_UNSAFE; }
  else
    atomic_install "$out" "$config" "$config" "$LOCK_NONCE" || { recover_transaction; return $EX_UNSAFE; }
  fi
  if [ "$delete_config" -eq 1 ]; then
    [ ! -e "$config" ] && [ ! -L "$config" ] || { recover_transaction; return $EX_UNSAFE; }
  else
    [ -f "$config" ] && [ ! -L "$config" ] && [ "$(sha256 "$config")" = "$config_after" ] && [ "$(filemode "$config")" = "$config_mode_before" ] || { recover_transaction; return $EX_UNSAFE; }
    ( jxa_config analyze "$config" /dev/null ) >/dev/null || { recover_transaction; return $EX_UNSAFE; }
  fi
  set_transaction_phase config-written || { recover_transaction; return $EX_UNSAFE; }
  maybe_fail rollback-after-config || { recover_transaction; return $EX_UNSAFE; }
  if [ "$generated_owned" -eq 1 ]; then
    [ -f "$pending" ] && [ ! -L "$pending" ] && [ "$(sha256 "$pending")" = "$expected_generated_hash" ] && [ ! -e "$generated" ] || { recover_transaction; return $EX_UNSAFE; }
  elif [ "$generated_before_actual" = '<missing>' ]; then
    [ ! -e "$generated" ] && [ ! -L "$generated" ] || { recover_transaction; return $EX_UNSAFE; }
  else
    [ -f "$generated" ] && [ ! -L "$generated" ] && [ "$(sha256 "$generated")" = "$generated_before_actual" ] || { recover_transaction; return $EX_UNSAFE; }
  fi
  [ -f "$state" ] && [ ! -L "$state" ] && [ "$(sha256 "$state")" = "$state_hash" ] || { recover_transaction; return $EX_UNSAFE; }
  /bin/mv -n "$state" "$archive" || { recover_transaction; return $EX_UNSAFE; }
  [ ! -e "$state" ] && [ -f "$archive" ] && [ ! -L "$archive" ] && [ "$(sha256 "$archive")" = "$state_hash" ] || { recover_transaction; return $EX_UNSAFE; }
  ( jxa_validate_state "$archive" "$CODEX_ROOT" '' ) >/dev/null || { recover_transaction; return $EX_UNSAFE; }
  maybe_fail rollback-after-state || { recover_transaction; return $EX_UNSAFE; }
  set_transaction_phase state-archived || { recover_transaction; return $EX_UNSAFE; }
  [ ! -e "$pending" ] || remove_owned_temp "$pending" "$expected_generated_hash" || return $EX_UNSAFE
  [ ! -e "$snapshot" ] || remove_owned_temp "$snapshot" "$config_before" || return $EX_UNSAFE
  /bin/rm -f "$TX_PATH" || return $EX_UNSAFE
  [ ! -e "$TX_PATH" ] && [ -f "$archive" ] && [ "$(sha256 "$archive")" = "$state_hash" ] || return $EX_UNSAFE
  if [ "$delete_config" -eq 0 ]; then [ "$(sha256 "$config")" = "$config_after" ] && [ "$(filemode "$config")" = "$config_mode_before" ] || return $EX_UNSAFE; fi
  if [ "$cache_restorable" -eq 1 ]; then [ -f "$cache" ] && [ "$(sha256 "$cache")" = "$cache_hash" ] || return $EX_UNSAFE; fi
  info 'result=rolled-back'
  restart_notice
  return 0
}

trap 'cleanup' EXIT
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

parse_args "$@" || { warn 'usage: codex-provider-compat.sh doctor|apply|status|rollback [options]'; exit $EX_ERROR; }
resolve_home || { warn 'unsafe Codex home'; exit $EX_UNSAFE; }
internal_test_hooks_authorized || exit $EX_UNSAFE

case "$COMMAND" in
  doctor) doctor ;;
  apply) apply_cmd ;;
  status) status_cmd ;;
  rollback) rollback_cmd ;;
esac
exit $?
