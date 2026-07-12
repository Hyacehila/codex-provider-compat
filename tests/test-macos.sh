#!/bin/sh

set -u
umask 077
CODEX_PROVIDER_COMPAT_INTERNAL_TEST_CONFIRM=I-understand-this-is-test-only
export CODEX_PROVIDER_COMPAT_INTERNAL_TEST_CONFIRM

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TOOL="$ROOT/codex-provider-compat.sh"
FIXTURES="$ROOT/tests/fixtures"
PASSED=0
FAILED=0
CASE_NO=0
TMP_BASE=${TMPDIR:-/tmp}
SUITE_ROOT=$(/usr/bin/mktemp -d "$TMP_BASE/cpc-macos-suite.XXXXXX") || exit 1
RUN_OUT="$SUITE_ROOT/run.out"
NEW_HOME=

new_home() {
  CASE_NO=$((CASE_NO + 1))
  NEW_HOME="$SUITE_ROOT/$1-$CASE_NO"
  /bin/mkdir -m 700 "$NEW_HOME" || exit 1
}

run_tool() {
  /bin/sh "$TOOL" "$@" > "$RUN_OUT" 2>&1
  RUN_CODE=$?
}

run_tool_env() {
  env_name=$1
  env_value=$2
  shift 2
  /usr/bin/env "$env_name=$env_value" /bin/sh "$TOOL" "$@" > "$RUN_OUT" 2>&1
  RUN_CODE=$?
}

assert_eq() {
  expected=$1
  actual=$2
  label=$3
  [ "$expected" = "$actual" ] || {
    printf '%s\n' "$label expected=[$expected] actual=[$actual]"
    return 1
  }
}

assert_file() {
  [ -f "$1" ] && [ ! -L "$1" ] || {
    printf '%s\n' "missing or unsafe file: $1"
    return 1
  }
}

assert_no_path() {
  [ ! -e "$1" ] && [ ! -L "$1" ] || {
    printf '%s\n' "unexpected path: $1"
    return 1
  }
}

assert_contains() {
  /usr/bin/grep -F "$2" "$1" >/dev/null || {
    printf '%s\n' "missing text [$2] in $1"
    return 1
  }
}

assert_not_contains() {
  ! /usr/bin/grep -F "$2" "$1" >/dev/null || {
    printf '%s\n' "unexpected text [$2] in $1"
    return 1
  }
}

hash_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print toupper($1)}'
}

first_three_hex() {
  /usr/bin/od -An -tx1 -N3 "$1" | /usr/bin/tr -d ' \n'
}

assert_no_atomic_temps() {
  ! /usr/bin/find "$1" -name '*.provider-compat-*.tmp' -type f | /usr/bin/grep . >/dev/null
}

case_run() {
  name=$1
  shift
  : > "$RUN_OUT"
  if "$@"; then
    PASSED=$((PASSED + 1))
    printf 'PASS %s\n' "$name"
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL %s\n' "$name"
    [ -f "$RUN_OUT" ] && /bin/cat "$RUN_OUT"
  fi
}

snapshot_real() {
  r=${CODEX_HOME:-$HOME/.codex}
  for n in config.toml models_cache.json provider-compat-state.json provider-compat-transaction.json; do
    p="$r/$n"
    if [ -f "$p" ]; then
      /usr/bin/shasum -a 256 "$p"
    elif [ -e "$p" ] || [ -L "$p" ]; then
      /usr/bin/stat -f '%HT %N' "$p"
    else
      printf '<missing> %s\n' "$p"
    fi
  done
  if [ -d "$r/model-catalogs" ]; then
    for p in "$r"/model-catalogs/*; do [ -f "$p" ] && /usr/bin/shasum -a 256 "$p"; done | /usr/bin/sort
  fi
  if [ -d "$r/provider-compat.lock.d" ]; then
    /usr/bin/stat -f '%HT %N' "$r/provider-compat.lock.d"
    [ -f "$r/provider-compat.lock.d/lock.json" ] && /usr/bin/shasum -a 256 "$r/provider-compat.lock.d/lock.json"
  else
    printf '<missing> %s\n' "$r/provider-compat.lock.d"
  fi
}

json_set_string() {
  file=$1
  dotted=$2
  value=$3
  /usr/bin/osascript -l JavaScript - "$file" "$dotted" "$value" <<'JXA'
ObjC.import('Foundation');
function run(a) {
  let e = Ref(), s = $.NSString.stringWithContentsOfFileEncodingError($(a[0]), $.NSUTF8StringEncoding, e);
  if (!s) throw Error('read');
  let o = JSON.parse(s.js), p = a[1].split('.'), x = o;
  for (let i = 0; i < p.length - 1; i++) x = x[p[i]];
  x[p[p.length - 1]] = a[2];
  if (!$(JSON.stringify(o, null, 2) + '\n').writeToFileAtomicallyEncodingError($(a[0]), true, $.NSUTF8StringEncoding, e)) throw Error('write');
}
JXA
}

json_set_boolean() {
  file=$1
  dotted=$2
  value=$3
  /usr/bin/osascript -l JavaScript - "$file" "$dotted" "$value" <<'JXA'
ObjC.import('Foundation');
function run(a) {
  if (a[2] !== 'true' && a[2] !== 'false') throw Error('invalid boolean');
  let e=Ref(),s=$.NSString.stringWithContentsOfFileEncodingError($(a[0]),$.NSUTF8StringEncoding,e),o=JSON.parse(s.js),p=a[1].split('.'),x=o;
  for (let i=0;i<p.length-1;i++) x=x[p[i]];
  x[p[p.length-1]]=a[2] === 'true';
  if (!$(JSON.stringify(o,null,2)+'\n').writeToFileAtomicallyEncodingError($(a[0]),true,$.NSUTF8StringEncoding,e)) throw Error('write');
}
JXA
}

json_get_value() {
  /usr/bin/osascript -l JavaScript - "$1" "$2" <<'JXA'
ObjC.import('Foundation');
function run(a){let e=Ref(),s=$.NSString.stringWithContentsOfFileEncodingError($(a[0]),$.NSUTF8StringEncoding,e),o=JSON.parse(s.js);for(let k of a[1].split('.'))o=o[k];return String(o);}
JXA
}

json_assert_patch() {
  state=$1
  /usr/bin/osascript -l JavaScript - "$state" <<'JXA'
ObjC.import('Foundation');
function read(p) {
  let e = Ref(), s = $.NSString.stringWithContentsOfFileEncodingError($(p), $.NSUTF8StringEncoding, e);
  if (!s) throw Error('read');
  return JSON.parse(s.js);
}
function run(a) {
  let state = read(a[0]);
  if (state.patch_id !== 'responses-lite-standard-tools' || state.schema_version !== 1) throw Error('state identity');
  let c = read(state.generated_catalog.path);
  for (let t of ['gpt-5.6-sol','gpt-5.6-terra','gpt-5.6-luna']) {
    let m = c.models.find(function(x){return x.slug === t;});
    if (!m || m.use_responses_lite !== false) throw Error(t);
  }
  let future = c.models.find(function(x){return x.slug === 'future-lite-model';});
  if (!future || future.use_responses_lite !== true) throw Error('other Lite model changed');
  if (c.metadata.fixture !== 'complete' || c.metadata.preserve !== true) throw Error('metadata drift');
}
JXA
}

make_all_false_catalog() {
  /usr/bin/osascript -l JavaScript - "$FIXTURES/models-valid.json" "$1" <<'JXA'
ObjC.import('Foundation');
function run(a) {
  let e = Ref(), s = $.NSString.stringWithContentsOfFileEncodingError($(a[0]), $.NSUTF8StringEncoding, e), o = JSON.parse(s.js);
  for (let m of o.models) if (['gpt-5.6-sol','gpt-5.6-terra','gpt-5.6-luna'].indexOf(m.slug) >= 0) m.use_responses_lite = false;
  if (!$(JSON.stringify(o, null, 2) + '\n').writeToFileAtomicallyEncodingError($(a[1]), true, $.NSUTF8StringEncoding, e)) throw Error('write');
}
JXA
}

make_duplicate_catalog() {
  /usr/bin/osascript -l JavaScript - "$FIXTURES/models-valid.json" "$1" <<'JXA'
ObjC.import('Foundation');
function run(a) {
  let e = Ref(), s = $.NSString.stringWithContentsOfFileEncodingError($(a[0]), $.NSUTF8StringEncoding, e), o = JSON.parse(s.js);
  o.models.push(JSON.parse(JSON.stringify(o.models[0])));
  if (!$(JSON.stringify(o, null, 2) + '\n').writeToFileAtomicallyEncodingError($(a[1]), true, $.NSUTF8StringEncoding, e)) throw Error('write');
}
JXA
}

make_proto_duplicate_catalog() {
  /usr/bin/osascript -l JavaScript - "$FIXTURES/models-valid.json" "$1" <<'JXA'
ObjC.import('Foundation');
function run(a) {
  let e = Ref(), s = $.NSString.stringWithContentsOfFileEncodingError($(a[0]), $.NSUTF8StringEncoding, e), o = JSON.parse(s.js);
  o.models[3].slug = '__proto__';
  o.models[4].slug = '__proto__';
  if (!$(JSON.stringify(o, null, 2) + '\n').writeToFileAtomicallyEncodingError($(a[1]), true, $.NSUTF8StringEncoding, e)) throw Error('write');
}
JXA
}

apply_default() {
  h=$1
  shift
  run_tool apply --yes --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json" "$@"
}

rollback_default() {
  run_tool rollback --yes --codex-home "$1"
}

REAL_BEFORE=$(snapshot_real)

t_cycle() {
  new_home 'cycle 中文 space'
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-complex.toml" "$h/config.toml"
  [ "$(first_three_hex "$h/config.toml")" != efbbbf ] || return 1
  printf cache > "$h/models_cache.json"
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" apply || return 1
  [ "$(first_three_hex "$h/config.toml")" != efbbbf ] || return 1
  assert_file "$h/provider-compat-state.json" || return 1
  [ "$(json_get_value "$h/provider-compat-state.json" config.had_bom)" = false ] || return 1
  assert_no_path "$h/provider-compat-transaction.json" || return 1
  assert_not_contains "$h/provider-compat-state.json" 'provider.example.invalid' || return 1
  assert_not_contains "$h/provider-compat-state.json" 'keep this comment' || return 1
  json_assert_patch "$h/provider-compat-state.json" || return 1
  assert_contains "$h/config.toml" 'section-value-must-not-change.json' || return 1
  assert_contains "$h/config.toml" 'web_search = "disabled" # user choice' || return 1
  run_tool status --codex-home "$h" --codex-version 0.144.1
  assert_eq 0 "$RUN_CODE" status || return 1
  assert_contains "$RUN_OUT" 'unverified_lite_models=future-lite-model' || return 1
  printf 'model_catalog_json = "profile-only.json"\n' > "$h/work.config.toml"
  run_tool status --codex-home "$h" --codex-version 0.144.1
  assert_eq 0 "$RUN_CODE" status-unselected-profile || return 1
  assert_contains "$RUN_OUT" 'profile config may override user config only when explicitly selected' || return 1
  /bin/rm "$h/work.config.toml"
  printf '\n# later user change 中文\n' >> "$h/config.toml"
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" rollback || return 1
  assert_contains "$h/config.toml" '# later user change 中文' || return 1
  assert_not_contains "$h/config.toml" 'standard-responses-compat' || return 1
  assert_file "$h/models_cache.json" || return 1
  assert_no_path "$h/provider-compat-state.json" || return 1
  assert_no_path "$h/model-catalogs/models-0.144.1.standard-responses-compat.json" || return 1
  [ "$(first_three_hex "$h/config.toml")" != efbbbf ] || return 1
}

t_web_search() {
  new_home web
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-complex.toml" "$h/config.toml"
  apply_default "$h" --enable-web-search
  assert_eq 0 "$RUN_CODE" apply || return 1
  assert_contains "$RUN_OUT" 'plan: set web_search = "live"' || return 1
  assert_contains "$h/config.toml" 'web_search = "live" # user choice' || return 1
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" rollback || return 1
  assert_contains "$h/config.toml" 'web_search = "disabled" # user choice' || return 1
  for mode in cached indexed live; do
    new_home "web-$mode"
    h=$NEW_HOME
    printf 'model = "gpt-5.6-sol"\nmodel_provider = "custom"\nweb_search = "%s" # preserve-%s\n\n[model_providers.custom]\nwire_api = "responses"\n' "$mode" "$mode" > "$h/config.toml" || return 1
    apply_default "$h"
    assert_eq 0 "$RUN_CODE" "$mode-base-apply" || return 1
    assert_not_contains "$RUN_OUT" 'plan: set web_search = "live"' || return 1
    assert_contains "$h/config.toml" "web_search = \"$mode\" # preserve-$mode" || return 1
    rollback_default "$h"
    assert_eq 0 "$RUN_CODE" "$mode-base-rollback" || return 1
    apply_default "$h" --enable-web-search
    assert_eq 0 "$RUN_CODE" "$mode-enabled-apply" || return 1
    assert_contains "$RUN_OUT" 'plan: set web_search = "live"' || return 1
    assert_contains "$h/config.toml" 'web_search = "live"' || return 1
    rollback_default "$h"
    assert_eq 0 "$RUN_CODE" "$mode-enabled-rollback" || return 1
    assert_contains "$h/config.toml" "web_search = \"$mode\" # preserve-$mode" || return 1
  done
}

t_dry_run_and_doctor() {
  new_home dry
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  before=$(hash_file "$h/config.toml")
  run_tool doctor --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 0 "$RUN_CODE" doctor || return 1
  [ "$(hash_file "$h/config.toml")" = "$before" ] || return 1
  [ "$(find "$h" -type f | /usr/bin/wc -l | tr -d ' ')" = 1 ] || return 1
  run_tool apply --yes --dry-run --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 0 "$RUN_CODE" dry || return 1
  [ "$(hash_file "$h/config.toml")" = "$before" ] || return 1
  [ "$(find "$h" -type f | /usr/bin/wc -l | tr -d ' ')" = 1 ]
}

t_unauthorized_test_hook() {
  new_home unauthorized-hook
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  before=$(hash_file "$h/config.toml")
  before_listing=$(/usr/bin/find "$h" -print | /usr/bin/sort)
  CODEX_PROVIDER_COMPAT_INTERNAL_TEST_CONFIRM= CODEX_PROVIDER_COMPAT_TEST_FAIL_STAGE=after-journal \
    /bin/sh "$TOOL" apply --yes --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json" > "$RUN_OUT" 2>&1
  RUN_CODE=$?
  assert_eq 3 "$RUN_CODE" unauthorized-hook || return 1
  assert_contains "$RUN_OUT" 'test-only confirmation gate' || return 1
  [ "$(hash_file "$h/config.toml")" = "$before" ] || return 1
  after_listing=$(/usr/bin/find "$h" -print | /usr/bin/sort)
  [ "$after_listing" = "$before_listing" ] || return 1
  assert_no_path "$h/provider-compat.lock.d" || return 1
  assert_no_path "$h/provider-compat-transaction.json" || return 1
  assert_no_path "$h/provider-compat-state.json"
}

t_doctor_conclusions() {
  new_home conclusions
  h=$NEW_HOME
  printf 'model = "gpt-5.6-sol"\nmodel_provider = "openai"\n' > "$h/config.toml"
  run_tool doctor --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 2 "$RUN_CODE" official || return 1
  assert_contains "$RUN_OUT" 'result=not-needed' || return 1
  printf 'model = "gpt-5.6-sol"\nmodel_provider = "openai"\nopenai_base_url = "https://proxy.example.invalid/v1"\n' > "$h/config.toml"
  run_tool doctor --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 3 "$RUN_CODE" openai-base-url-override || return 1
  assert_contains "$RUN_OUT" 'provider_scope=openai-overridden-or-ambiguous' || return 1
  printf 'model = "gpt-5.6-sol"\nmodel_provider = "openai"\n["model_providers"."openai"]\nbase_url = "https://proxy.example.invalid/v1"\n' > "$h/config.toml"
  run_tool doctor --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 3 "$RUN_CODE" openai-provider-table-override || return 1
  printf 'note = """\nopenai_base_url = "inside multiline"\n[model_providers.openai]\n"""\nmodel = "gpt-5.6-sol"\nmodel_provider = "openai"\n' > "$h/config.toml"
  run_tool doctor --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 2 "$RUN_CODE" openai-text-only || return 1
  printf 'model = "gpt-5.5"\nmodel_provider = "custom"\n' > "$h/config.toml"
  run_tool doctor --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 2 "$RUN_CODE" nontarget || return 1
  printf 'model_catalog_json = "override.json"\n' > "$h/work.config.toml"
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  run_tool doctor --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 0 "$RUN_CODE" unselected-profile || return 1
  assert_contains "$RUN_OUT" 'result=applicable' || return 1
  assert_contains "$RUN_OUT" 'profile config may override user config only when explicitly selected' || return 1
  /bin/rm "$h/work.config.toml"
  printf 'model = "gpt-5.6-sol"\nmodel_provider = "chatgpt"\n' > "$h/config.toml"
  run_tool doctor --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 0 "$RUN_CODE" custom-chatgpt || return 1
  assert_contains "$RUN_OUT" 'result=applicable' || return 1
  printf 'model_provider = "custom"\n' > "$h/config.toml"
  run_tool doctor --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 3 "$RUN_CODE" missing-model || return 1
  assert_contains "$RUN_OUT" 'result=unknown' || return 1
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  run_tool doctor --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 0 "$RUN_CODE" custom || return 1
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" apply || return 1
  run_tool doctor --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 0 "$RUN_CODE" already || return 1
  assert_contains "$RUN_OUT" 'result=already-applied'
}

t_catalog_failures() {
  for f in models-missing-target.json models-minimal.json models-empty.json models-wrong-type.json models-invalid.json; do
    new_home "bad-$f"
    h=$NEW_HOME
    /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
    run_tool apply --yes --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/$f"
    assert_eq 3 "$RUN_CODE" "$f" || return 1
    assert_no_path "$h/provider-compat-state.json" || return 1
  done
  new_home duplicate
  h=$NEW_HOME
  make_duplicate_catalog "$h/duplicate.json"
  run_tool apply --yes --codex-home "$h" --codex-version 0.144.1 --catalog-file "$h/duplicate.json"
  assert_eq 3 "$RUN_CODE" duplicate || return 1
  new_home proto-duplicate
  h=$NEW_HOME
  make_proto_duplicate_catalog "$h/duplicate.json"
  run_tool apply --yes --codex-home "$h" --codex-version 0.144.1 --catalog-file "$h/duplicate.json"
  assert_eq 3 "$RUN_CODE" proto-duplicate || return 1
  new_home false
  h=$NEW_HOME
  make_all_false_catalog "$h/false.json"
  run_tool apply --yes --codex-home "$h" --codex-version 0.144.1 --catalog-file "$h/false.json"
  assert_eq 2 "$RUN_CODE" already-false || return 1
  assert_no_path "$h/provider-compat-state.json"
}

t_config_lexer() {
  new_home lexer
  h=$NEW_HOME
  /bin/cat > "$h/config.toml" <<'TOML'
note = """
model_catalog_json = "inside-multiline"
web_search = "inside-multiline"
"""
note_four_quotes = """
model_catalog_json = "inside-four-quote-multiline"
ends-with-one-quote""""
note_five_quotes = '''
web_search = "inside-five-quote-multiline"
ends-with-two-quotes'''''
items = [
  "model_catalog_json = inside-array",
  "web_search = inside-array",
]
"model_catalog_json" = '/old catalog path' # keep catalog comment
'web_search' = "disabled" # keep web comment
model = "gpt-5.6-sol"
model_provider = "custom"
[model_providers.custom]
model_catalog_json = "inside-section"
web_search = "inside-section"
["quoted]table"."complex.part"]
"key=with-symbols" = { nested = ["model_catalog_json = still section"] }
TOML
  original="$h/original.toml"
  /bin/cp "$h/config.toml" "$original"
  apply_default "$h" --enable-web-search
  assert_eq 0 "$RUN_CODE" lexer-apply || return 1
  assert_contains "$h/config.toml" 'model_catalog_json = "inside-multiline"' || return 1
  assert_contains "$h/config.toml" 'model_catalog_json = "inside-four-quote-multiline"' || return 1
  assert_contains "$h/config.toml" 'web_search = "inside-five-quote-multiline"' || return 1
  assert_contains "$h/config.toml" '"model_catalog_json" = "' || return 1
  assert_contains "$h/config.toml" '# keep catalog comment' || return 1
  assert_contains "$h/config.toml" "'web_search' = \"live\" # keep web comment" || return 1
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" lexer-rollback || return 1
  [ "$(hash_file "$h/config.toml")" = "$(hash_file "$original")" ] || return 1
  for bad in dotted duplicate unterminated mixed-newline; do
    new_home "lexer-$bad"
    b=$NEW_HOME
    case "$bad" in
      dotted) printf 'model_catalog_json.child = "x"\nmodel = "gpt-5.6-sol"\nmodel_provider = "custom"\n' > "$b/config.toml" ;;
      duplicate) printf 'model_catalog_json = "a"\n"model_catalog_json" = "b"\n' > "$b/config.toml" ;;
      unterminated) printf 'note = """\nmodel_catalog_json = "inside"\n' > "$b/config.toml" ;;
      mixed-newline) printf 'model = "gpt-5.6-sol"\r\nmodel_provider = "custom"\n' > "$b/config.toml" ;;
    esac
    before=$(hash_file "$b/config.toml")
    apply_default "$b"
    assert_eq 3 "$RUN_CODE" "$bad" || return 1
    [ "$(hash_file "$b/config.toml")" = "$before" ] || return 1
    assert_no_path "$b/provider-compat-state.json" || return 1
  done
}

t_bom_crlf_permissions() {
  new_home encoding
  h=$NEW_HOME
  {
    printf '\357\273\277'
    printf '# encoding\r\nmodel = "gpt-5.6-sol"\r\nmodel_provider = "custom"\r\nweb_search = "cached"\r\n\r\n[model_providers.custom]\r\nwire_api = "responses"\r\n'
  } > "$h/config.toml"
  /bin/chmod 600 "$h/config.toml"
  /usr/bin/xattr -w com.codex-provider-compat.test keep "$h/config.toml"
  [ "$(first_three_hex "$h/config.toml")" = efbbbf ] || return 1
  original=$(hash_file "$h/config.toml")
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" apply || return 1
  [ "$(/usr/bin/od -An -tx1 -N3 "$h/config.toml" | tr -d ' \n')" = efbbbf ] || return 1
  [ "$(json_get_value "$h/provider-compat-state.json" config.had_bom)" = true ] || return 1
  [ "$(/usr/bin/stat -f '%Lp' "$h/config.toml")" = 600 ] || return 1
  [ "$(/usr/bin/xattr -p com.codex-provider-compat.test "$h/config.toml")" = keep ] || return 1
  /usr/bin/osascript -l JavaScript - "$h/config.toml" <<'JXA' >/dev/null || return 1
ObjC.import('Foundation');
function run(a){let e=Ref(),s=$.NSString.stringWithContentsOfFileEncodingError($(a[0]),$.NSUTF8StringEncoding,e).js;if(s.replace(/\r\n/g,'').indexOf('\n')>=0)throw Error('lone LF');}
JXA
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" rollback || return 1
  [ "$(first_three_hex "$h/config.toml")" = efbbbf ] || return 1
  [ "$(hash_file "$h/config.toml")" = "$original" ] || return 1
  [ "$(/usr/bin/stat -f '%Lp' "$h/config.toml")" = 600 ] || return 1
  [ "$(/usr/bin/xattr -p com.codex-provider-compat.test "$h/config.toml")" = keep ]
}

t_missing_and_empty_config() {
  new_home missing
  h=$NEW_HOME
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" missing-apply || return 1
  assert_file "$h/config.toml" || return 1
  [ "$(first_three_hex "$h/config.toml")" != efbbbf ] || return 1
  [ "$(/usr/bin/stat -f '%Lp' "$h/config.toml")" = 600 ] || return 1
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" missing-rollback || return 1
  assert_no_path "$h/config.toml" || return 1
  new_home empty
  h=$NEW_HOME
  : > "$h/config.toml"
  original=$(hash_file "$h/config.toml")
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" empty-apply || return 1
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" empty-rollback || return 1
  [ "$(hash_file "$h/config.toml")" = "$original" ]
}

t_symlink_guards() {
  new_home symlink
  h=$NEW_HOME
  outside="$SUITE_ROOT/outside-symlink"
  /bin/mkdir "$outside"
  printf victim > "$outside/victim"
  /bin/ln -s "$outside" "$h/model-catalogs"
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  apply_default "$h"
  assert_eq 3 "$RUN_CODE" catalog-symlink || return 1
  [ "$(/bin/cat "$outside/victim")" = victim ] || return 1
  assert_no_path "$outside/models-0.144.1.standard-responses-compat.json" || return 1
  /bin/rm "$h/model-catalogs"
  /bin/mv "$h/config.toml" "$outside/config-real.toml"
  /bin/ln -s "$outside/config-real.toml" "$h/config.toml"
  before=$(hash_file "$outside/config-real.toml")
  apply_default "$h"
  assert_eq 3 "$RUN_CODE" config-symlink || return 1
  [ "$(hash_file "$outside/config-real.toml")" = "$before" ] || return 1
  /bin/rm "$h/config.toml"
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" setup || return 1
  victim="$outside/do-not-delete"
  printf keep > "$victim"
  json_set_string "$h/provider-compat-state.json" generated_catalog.path "$victim"
  run_tool status --codex-home "$h" --codex-version 0.144.1
  assert_eq 3 "$RUN_CODE" tampered-status || return 1
  rollback_default "$h"
  assert_eq 3 "$RUN_CODE" tampered-rollback || return 1
  [ "$(/bin/cat "$victim")" = keep ]
}

t_home_path_guards() {
  new_home home-target
  target=$NEW_HOME
  link="$SUITE_ROOT/home-link"
  /bin/ln -s "$target" "$link"
  run_tool doctor --codex-home "$link" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 3 "$RUN_CODE" home-symlink || return 1
  run_tool doctor --codex-home . --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 3 "$RUN_CODE" relative || return 1
  run_tool doctor --codex-home / --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 3 "$RUN_CODE" root || return 1
  run_tool doctor --codex-home /Applications/Codex.app --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 3 "$RUN_CODE" app-package || return 1
  run_tool doctor --codex-home '' --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 3 "$RUN_CODE" explicit-empty-home || return 1
  run_tool doctor --codex-home "$target" --codex-version '' --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 1 "$RUN_CODE" explicit-empty-version || return 1
  run_tool doctor --codex-home "$target" --codex-version 0.144.1 --catalog-file ''
  assert_eq 1 "$RUN_CODE" explicit-empty-catalog || return 1
  /usr/bin/env HOME= CODEX_HOME= /bin/sh "$TOOL" doctor --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json" > "$RUN_OUT" 2>&1
  RUN_CODE=$?
  assert_eq 3 "$RUN_CODE" empty-default-home || return 1
  /bin/cp "$FIXTURES/config-basic.toml" "$target/config.toml"
  /usr/bin/env HOME= CODEX_HOME= /bin/sh "$TOOL" doctor --codex-home "$target" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json" > "$RUN_OUT" 2>&1
  RUN_CODE=$?
  assert_eq 0 "$RUN_CODE" empty-home-with-explicit-codex-home || return 1
  fake_home_link="$SUITE_ROOT/fake-home-link"
  /bin/ln -s "$target" "$fake_home_link"
  /usr/bin/env HOME="$fake_home_link" CODEX_HOME= /bin/sh "$TOOL" doctor --codex-home "$target" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json" > "$RUN_OUT" 2>&1
  RUN_CODE=$?
  assert_eq 3 "$RUN_CODE" canonical-home-symlink-equality
}

t_system_alias_normalization() {
  fn="$SUITE_ROOT/absolute-path-function.sh"
  /usr/bin/awk '
    /^absolute_path\(\) \{/ { copying=1 }
    copying && /^new_nonce\(\) \{/ { exit }
    copying { print }
  ' "$TOOL" > "$fn" || return 1
  . "$fn" || return 1
  assert_eq '/private/var/cpc-alias-probe' "$(absolute_path '/var/cpc-alias-probe')" var-alias || return 1
  assert_eq '/private/tmp/cpc-alias-probe' "$(absolute_path '/tmp/cpc-alias-probe')" tmp-alias || return 1
  assert_eq '/private/etc/cpc-alias-probe' "$(absolute_path '/etc/cpc-alias-probe')" etc-alias || return 1
  existing="$SUITE_ROOT/existing-alias-probe"
  /bin/mkdir "$existing" || return 1
  expected=$(printf '%s\n' "$existing" | /usr/bin/awk '{gsub(/\/+/,"/");if($0~/^\/(var|tmp|etc)(\/|$)/)print "/private"$0;else print $0}')
  canonical_root=$(absolute_path "$SUITE_ROOT") || return 1
  canonical_child=$(absolute_path "$existing") || return 1
  assert_eq "$expected" "$canonical_child" existing-system-alias || return 1
  guard_fn="$SUITE_ROOT/path-guard-function.sh"
  /usr/bin/awk '
    /^path_guard\(\) \{/ { copying=1 }
    copying && /^path_in_home\(\) \{/ { exit }
    copying { print }
  ' "$TOOL" > "$guard_fn" || return 1
  . "$guard_fn" || return 1
  assert_eq "$canonical_child" "$(path_guard "$canonical_root" "$canonical_child" inside)" existing-path-guard || return 1
  guard_home="$SUITE_ROOT/path-guard-home"
  /bin/mkdir "$guard_home" || return 1
  canonical_guard_home=$(absolute_path "$guard_home") || return 1
  missing_child="$canonical_guard_home/not-yet-created/child"
  assert_eq "$missing_child" "$(path_guard "$canonical_guard_home" "$missing_child" inside)" missing-path-guard || return 1
  guard_outside="$SUITE_ROOT/path-guard-outside"
  /bin/mkdir "$guard_outside" || return 1
  /bin/ln -s "$guard_outside" "$guard_home/live-link" || return 1
  if path_guard "$canonical_guard_home" "$canonical_guard_home/live-link/child" inside >/dev/null 2>&1; then return 1; fi
  /bin/ln -s "$guard_home/missing-target" "$guard_home/dangling-link" || return 1
  if path_guard "$canonical_guard_home" "$canonical_guard_home/dangling-link/child" inside >/dev/null 2>&1; then return 1; fi
  new_home alias-user-link
  outside="$SUITE_ROOT/alias-user-target"
  /bin/mkdir "$outside" || return 1
  /bin/ln -s "$outside" "$NEW_HOME/user-link" || return 1
  if absolute_path "$NEW_HOME/user-link/child" >/dev/null 2>&1; then return 1; fi
}

t_state_and_transaction_tamper() {
  new_home tamper
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" setup || return 1
  json_set_string "$h/provider-compat-state.json" config.backup_path "$SUITE_ROOT/outside-backup"
  rollback_default "$h"
  assert_eq 3 "$RUN_CODE" backup-path || return 1
  new_home empty-state-fields
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  printf cache > "$h/models_cache.json"
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" empty-state-fields-setup || return 1
  for field in config.backup_path config.before_sha256 config.previous_web_search_literal cache.backup_path cache.sha256 other_lite_models.0; do
    original_value=$(json_get_value "$h/provider-compat-state.json" "$field") || return 1
    [ -n "$original_value" ] || return 1
    json_set_string "$h/provider-compat-state.json" "$field" '' || return 1
    rollback_default "$h"
    assert_eq 3 "$RUN_CODE" "empty-$field" || return 1
    assert_file "$h/provider-compat-state.json" || return 1
    json_set_string "$h/provider-compat-state.json" "$field" "$original_value" || return 1
  done
  run_tool status --codex-home "$h" --codex-version 0.144.1
  assert_eq 0 "$RUN_CODE" empty-state-fields-restored || return 1
  new_home nested-config-backup
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" nested-config-setup || return 1
  config_backup=$(find "$h" -name 'config.toml.bak-provider-compat-*' -type f | /usr/bin/awk 'NR==1{print;exit}')
  /bin/mkdir "$h/nested"
  nested_config_backup="$h/nested/${config_backup##*/}"
  /bin/mv "$config_backup" "$nested_config_backup"
  json_set_string "$h/provider-compat-state.json" config.backup_path "$nested_config_backup"
  rollback_default "$h"
  assert_eq 3 "$RUN_CODE" nested-config-backup || return 1
  assert_file "$nested_config_backup" || return 1
  new_home nested-cache-backup
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  printf cache > "$h/models_cache.json"
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" nested-cache-setup || return 1
  cache_backup=$(find "$h" -name 'models_cache.json.bak-provider-compat-*' -type f | /usr/bin/awk 'NR==1{print;exit}')
  /bin/mkdir "$h/nested"
  nested_cache_backup="$h/nested/${cache_backup##*/}"
  /bin/mv "$cache_backup" "$nested_cache_backup"
  json_set_string "$h/provider-compat-state.json" cache.backup_path "$nested_cache_backup"
  rollback_default "$h"
  assert_eq 3 "$RUN_CODE" nested-cache-backup || return 1
  assert_file "$nested_cache_backup" || return 1
  assert_no_path "$h/models_cache.json" || return 1
  new_home tx
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  printf '{"schema_version":1,"operation":"apply","root":"/tmp/escape"}\n' > "$h/provider-compat-transaction.json"
  run_tool status --codex-home "$h" --codex-version 0.144.1
  assert_eq 3 "$RUN_CODE" tx-status || return 1
  assert_contains "$RUN_OUT" 'recovery-required' || return 1
  apply_default "$h"
  assert_eq 3 "$RUN_CODE" tx-apply || return 1
  assert_file "$h/provider-compat-transaction.json" || return 1
  new_home transaction-cache-pair
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  run_tool_env CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE after-journal apply --yes --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 137 "$RUN_CODE" transaction-cache-pair-crash || return 1
  json_set_string "$h/provider-compat-transaction.json" hashes.cache AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
  apply_default "$h"
  assert_eq 3 "$RUN_CODE" transaction-cache-pair || return 1
  assert_file "$h/provider-compat-transaction.json" || return 1
  new_home transaction-cache-restore-flag
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" transaction-cache-restore-flag-setup || return 1
  run_tool_env CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE rollback-after-journal rollback --yes --codex-home "$h"
  assert_eq 137 "$RUN_CODE" transaction-cache-restore-flag-crash || return 1
  json_set_boolean "$h/provider-compat-transaction.json" flags.cache_should_restore true
  rollback_default "$h"
  assert_eq 3 "$RUN_CODE" transaction-cache-restore-flag || return 1
  assert_file "$h/provider-compat-transaction.json" || return 1
  new_home nested-state-archive
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" nested-archive-setup || return 1
  run_tool_env CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE rollback-after-config-save rollback --yes --codex-home "$h"
  assert_eq 137 "$RUN_CODE" nested-archive-crash || return 1
  archive=$(json_get_value "$h/provider-compat-transaction.json" paths.state_archive)
  /bin/mkdir "$h/nested"
  nested_archive="$h/nested/${archive##*/}"
  json_set_string "$h/provider-compat-transaction.json" paths.state_archive "$nested_archive"
  rollback_default "$h"
  assert_eq 3 "$RUN_CODE" nested-state-archive || return 1
  assert_file "$h/provider-compat-transaction.json" || return 1
  new_home nested-transaction-config-backup
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  run_tool_env CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE after-backup apply --yes --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 137 "$RUN_CODE" nested-tx-config-crash || return 1
  tx_config_backup=$(json_get_value "$h/provider-compat-transaction.json" paths.config_backup)
  /bin/mkdir "$h/nested"
  nested_tx_config_backup="$h/nested/${tx_config_backup##*/}"
  /bin/mv "$tx_config_backup" "$nested_tx_config_backup"
  json_set_string "$h/provider-compat-transaction.json" paths.config_backup "$nested_tx_config_backup"
  apply_default "$h"
  assert_eq 3 "$RUN_CODE" nested-transaction-config-backup || return 1
  assert_file "$nested_tx_config_backup" || return 1
  assert_file "$h/provider-compat-transaction.json" || return 1
  new_home nested-transaction-cache-backup
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  printf cache > "$h/models_cache.json"
  run_tool_env CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE after-cache apply --yes --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 137 "$RUN_CODE" nested-tx-cache-crash || return 1
  tx_cache_backup=$(json_get_value "$h/provider-compat-transaction.json" paths.cache_backup)
  /bin/mkdir "$h/nested"
  nested_tx_cache_backup="$h/nested/${tx_cache_backup##*/}"
  /bin/mv "$tx_cache_backup" "$nested_tx_cache_backup"
  json_set_string "$h/provider-compat-transaction.json" paths.cache_backup "$nested_tx_cache_backup"
  apply_default "$h"
  assert_eq 3 "$RUN_CODE" nested-transaction-cache-backup || return 1
  assert_file "$nested_tx_cache_backup" || return 1
  assert_file "$h/provider-compat-transaction.json" || return 1
  new_home state-link
  h=$NEW_HOME
  outside_state="$SUITE_ROOT/outside-state.json"
  printf '{"patch_id":"do-not-touch"}\n' > "$outside_state"
  /bin/ln -s "$outside_state" "$h/provider-compat-state.json"
  rollback_default "$h"
  assert_eq 3 "$RUN_CODE" state-symlink || return 1
  assert_contains "$outside_state" 'do-not-touch'
}

t_apply_fault_recovery() {
  for stage in after-journal after-backup after-catalog after-cache config-write after-config state-write; do
    new_home "fault-$stage"
    h=$NEW_HOME
    /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
    printf cache > "$h/models_cache.json"
    original=$(hash_file "$h/config.toml")
    run_tool_env CODEX_PROVIDER_COMPAT_TEST_FAIL_STAGE "$stage" apply --yes --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
    assert_eq 3 "$RUN_CODE" "$stage" || return 1
    [ "$(hash_file "$h/config.toml")" = "$original" ] || return 1
    assert_file "$h/models_cache.json" || return 1
    assert_no_path "$h/provider-compat-state.json" || return 1
    assert_no_path "$h/provider-compat-transaction.json" || return 1
    assert_no_path "$h/model-catalogs/models-0.144.1.standard-responses-compat.json" || return 1
    assert_no_path "$h/provider-compat.lock.d" || return 1
    ! find "$h" -name 'config.toml.bak-provider-compat-*' -type f | /usr/bin/grep . >/dev/null || return 1
  done
}

t_rollback_fault_recovery() {
  for stage in rollback-after-journal rollback-after-config-save rollback-after-catalog rollback-config-write rollback-after-config rollback-after-cache rollback-after-state; do
    new_home "rollback-fault-$stage"
    h=$NEW_HOME
    /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
    printf cache > "$h/models_cache.json"
    apply_default "$h"
    assert_eq 0 "$RUN_CODE" "setup-$stage" || return 1
    patched=$(hash_file "$h/config.toml")
    generated="$h/model-catalogs/models-0.144.1.standard-responses-compat.json"
    genhash=$(hash_file "$generated")
    run_tool_env CODEX_PROVIDER_COMPAT_TEST_FAIL_STAGE "$stage" rollback --yes --codex-home "$h"
    assert_eq 3 "$RUN_CODE" "$stage" || return 1
    [ "$(hash_file "$h/config.toml")" = "$patched" ] || return 1
    [ "$(hash_file "$generated")" = "$genhash" ] || return 1
    assert_file "$h/provider-compat-state.json" || return 1
    assert_no_path "$h/provider-compat-transaction.json" || return 1
    assert_no_path "$h/models_cache.json" || return 1
    run_tool status --codex-home "$h" --codex-version 0.144.1
    assert_eq 0 "$RUN_CODE" "status-$stage" || return 1
    rollback_default "$h"
    assert_eq 0 "$RUN_CODE" "cleanup-$stage" || return 1
  done
}

t_signal_and_crash_recovery() {
  new_home signal
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  printf cache > "$h/models_cache.json"
  original=$(hash_file "$h/config.toml")
  run_tool_env CODEX_PROVIDER_COMPAT_TEST_SIGNAL_STAGE after-catalog apply --yes --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 143 "$RUN_CODE" signal || return 1
  [ "$(hash_file "$h/config.toml")" = "$original" ] || return 1
  assert_file "$h/models_cache.json" || return 1
  assert_no_path "$h/provider-compat-transaction.json" || return 1
  new_home crash
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  printf cache > "$h/models_cache.json"
  crash_tmp="$SUITE_ROOT/script tmp 中文"
  /bin/mkdir "$crash_tmp"
  /usr/bin/env TMPDIR="$crash_tmp/" CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE=after-catalog /bin/sh "$TOOL" apply --yes --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json" > "$RUN_OUT" 2>&1
  RUN_CODE=$?
  assert_eq 137 "$RUN_CODE" crash || return 1
  assert_file "$h/provider-compat-transaction.json" || return 1
  [ "$(json_get_value "$h/provider-compat-transaction.json" phase)" = generated-catalog-written ] || return 1
  state_tx_hash=$(json_get_value "$h/provider-compat-transaction.json" hashes.state)
  [ "${#state_tx_hash}" -eq 64 ] || return 1
  nonce=$(json_get_value "$h/provider-compat-transaction.json" nonce)
  generated=$(json_get_value "$h/provider-compat-transaction.json" paths.generated_catalog)
  config_path=$(json_get_value "$h/provider-compat-transaction.json" paths.config)
  state_path=$(json_get_value "$h/provider-compat-transaction.json" paths.state)
  for atomic_dest in "$config_path" "$generated" "$state_path" "$h/provider-compat-transaction.json"; do
    atomic_dir=${atomic_dest%/*}
    atomic_base=${atomic_dest##*/}
    printf partial > "$atomic_dir/.$atomic_base.provider-compat-$nonce.tmp"
  done
  run_tool status --codex-home "$h" --codex-version 0.144.1
  assert_eq 3 "$RUN_CODE" recovery-status || return 1
  assert_contains "$RUN_OUT" 'recovery-required' || return 1
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" recovered-apply || return 1
  assert_no_atomic_temps "$h" || return 1
  run_tool status --codex-home "$h" --codex-version 0.144.1
  assert_eq 0 "$RUN_CODE" recovered-status || return 1
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" recovered-rollback || return 1
  new_home crash-config-backup
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  /usr/bin/env CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE=config-backup-copy /bin/sh "$TOOL" apply --yes --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json" > "$RUN_OUT" 2>&1
  RUN_CODE=$?
  assert_eq 137 "$RUN_CODE" config-backup-crash || return 1
  assert_file "$h/provider-compat-transaction.json" || return 1
  [ "$(json_get_value "$h/provider-compat-transaction.json" phase)" = prepared ] || return 1
  nonce=$(json_get_value "$h/provider-compat-transaction.json" nonce)
  config_backup=$(json_get_value "$h/provider-compat-transaction.json" paths.config_backup)
  assert_no_path "$config_backup" || return 1
  backup_dir=${config_backup%/*}
  backup_base=${config_backup##*/}
  backup_tmp="$backup_dir/.$backup_base.provider-compat-$nonce.tmp"
  assert_file "$backup_tmp" || return 1
  printf partial > "$backup_tmp"
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" config-backup-recovered-apply || return 1
  assert_no_atomic_temps "$h" || return 1
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" config-backup-recovered-rollback || return 1
  new_home crash-rollback-snapshot
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" snapshot-setup || return 1
  /usr/bin/env CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE=rollback-snapshot-copy /bin/sh "$TOOL" rollback --yes --codex-home "$h" > "$RUN_OUT" 2>&1
  RUN_CODE=$?
  assert_eq 137 "$RUN_CODE" snapshot-crash || return 1
  assert_file "$h/provider-compat-transaction.json" || return 1
  [ "$(json_get_value "$h/provider-compat-transaction.json" phase)" = prepared ] || return 1
  nonce=$(json_get_value "$h/provider-compat-transaction.json" nonce)
  snapshot=$(json_get_value "$h/provider-compat-transaction.json" paths.config_snapshot)
  assert_no_path "$snapshot" || return 1
  snapshot_dir=${snapshot%/*}
  snapshot_base=${snapshot##*/}
  snapshot_tmp="$snapshot_dir/.$snapshot_base.provider-compat-$nonce.tmp"
  assert_file "$snapshot_tmp" || return 1
  printf partial > "$snapshot_tmp"
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" snapshot-recovered-rollback || return 1
  assert_no_atomic_temps "$h"
}

t_tmpdir_safety() {
  new_home 'tmpdir inside home'
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  original=$(hash_file "$h/config.toml")
  inside_tmp="$h/temporary files"
  /bin/mkdir "$inside_tmp"
  run_tool_env TMPDIR "$inside_tmp/" doctor --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 3 "$RUN_CODE" tmpdir-inside-home || return 1
  [ "$(hash_file "$h/config.toml")" = "$original" ] || return 1
  ! /usr/bin/find "$inside_tmp" -mindepth 1 -print | /usr/bin/grep . >/dev/null || return 1
  inside_tmp_link="$SUITE_ROOT/tmpdir-inside-link"
  /bin/ln -s "$inside_tmp" "$inside_tmp_link"
  run_tool_env TMPDIR "$inside_tmp_link/" doctor --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 3 "$RUN_CODE" tmpdir-symlink-inside-home || return 1
  ! /usr/bin/find "$inside_tmp" -mindepth 1 -print | /usr/bin/grep . >/dev/null || return 1

  new_home 'tmpdir external home'
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  external_tmp="$SUITE_ROOT/external tmp 中文"
  /bin/mkdir "$external_tmp"
  run_tool_env TMPDIR "$external_tmp/" apply --yes --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 0 "$RUN_CODE" tmpdir-external-apply || return 1
  ! /usr/bin/find "$external_tmp" -mindepth 1 -print | /usr/bin/grep . >/dev/null || return 1
  run_tool_env TMPDIR "$external_tmp/" status --codex-home "$h" --codex-version 0.144.1
  assert_eq 0 "$RUN_CODE" tmpdir-external-status || return 1
  ! /usr/bin/find "$external_tmp" -mindepth 1 -print | /usr/bin/grep . >/dev/null || return 1
  run_tool_env TMPDIR "$external_tmp/" rollback --yes --codex-home "$h"
  assert_eq 0 "$RUN_CODE" tmpdir-external-rollback || return 1
  ! /usr/bin/find "$external_tmp" -mindepth 1 -print | /usr/bin/grep . >/dev/null
}

t_crash_cache_conflict() {
  new_home crash-cache
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  printf old > "$h/models_cache.json"
  /usr/bin/env CODEX_PROVIDER_COMPAT_TEST_CRASH_STAGE=after-cache /bin/sh "$TOOL" apply --yes --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json" > "$RUN_OUT" 2>&1
  RUN_CODE=$?
  assert_eq 137 "$RUN_CODE" crash || return 1
  printf new > "$h/models_cache.json"
  apply_default "$h"
  assert_eq 3 "$RUN_CODE" conflict || return 1
  assert_file "$h/provider-compat-transaction.json" || return 1
  [ "$(/bin/cat "$h/models_cache.json")" = new ] || return 1
  backup=$(find "$h" -name 'models_cache.json.bak-provider-compat-*' -type f | /usr/bin/awk 'NR==1{print;exit}')
  [ -n "$backup" ] && [ "$(/bin/cat "$backup")" = old ]
}

t_toctou() {
  new_home toctou
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  run_tool_env CODEX_PROVIDER_COMPAT_TEST_TOCTOU once apply --yes --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 0 "$RUN_CODE" once || return 1
  assert_contains "$h/config.toml" '# concurrent test edit 1' || return 1
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" once-rollback || return 1
  new_home toctou-transaction
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  run_tool_env CODEX_PROVIDER_COMPAT_TEST_TOCTOU transaction apply --yes --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 0 "$RUN_CODE" transaction || return 1
  assert_contains "$RUN_OUT" 'recovery=restored-pre-apply-state' || return 1
  assert_file "$h/model-catalogs/models-0.144.1.standard-responses-compat.json" || return 1
  assert_no_path "$h/model-catalogs/models-0.143.0.standard-responses-compat.json" || return 1
  assert_no_path "$h/provider-compat-transaction.json" || return 1
  assert_no_path "$h/provider-compat.lock.d" || return 1
  assert_no_atomic_temps "$h" || return 1
  run_tool status --codex-home "$h" --codex-version 0.144.1
  assert_eq 0 "$RUN_CODE" transaction-status || return 1
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" transaction-rollback || return 1
  new_home toctou-twice
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  run_tool_env CODEX_PROVIDER_COMPAT_TEST_TOCTOU twice apply --yes --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 3 "$RUN_CODE" twice || return 1
  assert_contains "$h/config.toml" '# concurrent test edit 2' || return 1
  assert_no_path "$h/provider-compat-state.json" || return 1
  assert_no_path "$h/provider-compat-transaction.json" || return 1
  assert_no_path "$h/model-catalogs/models-0.144.1.standard-responses-compat.json"
}

t_late_transaction_config_race() {
  new_home 'late apply 中文 space'
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  printf old-cache > "$h/models_cache.json"
  run_tool_env CODEX_PROVIDER_COMPAT_TEST_MUTATE_CONFIG_BEFORE_WRITE apply apply --yes --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 3 "$RUN_CODE" late-apply || return 1
  assert_contains "$h/config.toml" '# late-external-change apply' || return 1
  [ "$(/bin/cat "$h/models_cache.json")" = old-cache ] || return 1
  assert_no_path "$h/provider-compat-state.json" || return 1
  assert_no_path "$h/provider-compat-transaction.json" || return 1
  assert_no_path "$h/model-catalogs/models-0.144.1.standard-responses-compat.json" || return 1
  ! find "$h" -name 'config.toml.bak-provider-compat-*' -type f | /usr/bin/grep . >/dev/null || return 1
  ! find "$h" -name 'models_cache.json.bak-provider-compat-*' -type f | /usr/bin/grep . >/dev/null || return 1
  assert_no_atomic_temps "$h" || return 1
  new_home 'late rollback 中文 space'
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  printf old-cache > "$h/models_cache.json"
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" late-rollback-setup || return 1
  run_tool_env CODEX_PROVIDER_COMPAT_TEST_MUTATE_CONFIG_BEFORE_WRITE rollback rollback --yes --codex-home "$h"
  assert_eq 3 "$RUN_CODE" late-rollback || return 1
  assert_contains "$h/config.toml" '# late-external-change rollback' || return 1
  assert_file "$h/provider-compat-state.json" || return 1
  assert_file "$h/model-catalogs/models-0.144.1.standard-responses-compat.json" || return 1
  assert_no_path "$h/models_cache.json" || return 1
  find "$h" -name 'models_cache.json.bak-provider-compat-*' -type f | /usr/bin/grep . >/dev/null || return 1
  assert_no_path "$h/provider-compat-transaction.json" || return 1
  assert_no_atomic_temps "$h" || return 1
  run_tool status --codex-home "$h" --codex-version 0.144.1
  assert_eq 0 "$RUN_CODE" late-rollback-status || return 1
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" late-rollback-cleanup || return 1
  assert_contains "$h/config.toml" '# late-external-change rollback' || return 1
  [ "$(/bin/cat "$h/models_cache.json")" = old-cache ]
}

t_locks() {
  new_home lock-signal
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  original=$(hash_file "$h/config.toml")
  run_tool_env CODEX_PROVIDER_COMPAT_TEST_SIGNAL_STAGE lock-mkdir-critical apply --yes --codex-home "$h" --codex-version 0.144.1 --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 143 "$RUN_CODE" signal-in-lock-critical-section || return 1
  [ "$(hash_file "$h/config.toml")" = "$original" ] || return 1
  assert_no_path "$h/provider-compat.lock.d" || return 1
  assert_no_path "$h/provider-compat-transaction.json" || return 1
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" signal-retry || return 1
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" signal-retry-rollback || return 1
  new_home lock
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  /bin/mkdir "$h/provider-compat.lock.d"
  apply_default "$h"
  assert_eq 3 "$RUN_CODE" empty-active || return 1
  [ -d "$h/provider-compat.lock.d" ] || return 1
  /bin/rmdir "$h/provider-compat.lock.d"
  /bin/mkdir "$h/provider-compat.lock.d"
  /usr/bin/touch -t 200001010000 "$h/provider-compat.lock.d"
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" empty-stale || return 1
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" empty-stale-rollback || return 1
  /bin/mkdir "$h/provider-compat.lock.d"
  printf '{"pid":%s,"epoch":%s,"nonce":"0123456789abcdef0123456789abcdef"}\n' "$$" "$(/bin/date +%s)" > "$h/provider-compat.lock.d/lock.json"
  apply_default "$h"
  assert_eq 3 "$RUN_CODE" live || return 1
  /bin/rm "$h/provider-compat.lock.d/lock.json"
  /bin/rmdir "$h/provider-compat.lock.d"
  /bin/mkdir "$h/provider-compat.lock.d"
  stale_nonce=0123456789abcdef0123456789abcdef
  printf '{"pid":999999,"epoch":1,"nonce":"%s"}\n' "$stale_nonce" > "$h/provider-compat.lock.d/lock.json"
  orphan_tx_tmp="$h/.provider-compat-transaction.json.provider-compat-$stale_nonce.tmp"
  printf partial > "$orphan_tx_tmp"
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" stale || return 1
  assert_no_path "$orphan_tx_tmp" || return 1
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" stale-rollback || return 1
  /bin/mkdir "$h/provider-compat.lock.d"
  printf '{"pid":999999,"epoch":1,"nonce":"12345678-1234-1234-1234-123456789ABC"}\n' > "$h/provider-compat.lock.d/lock.json"
  apply_default "$h"
  assert_eq 3 "$RUN_CODE" malformed-nonce || return 1
  assert_file "$h/provider-compat.lock.d/lock.json" || return 1
  /bin/rm "$h/provider-compat.lock.d/lock.json"
  /bin/rmdir "$h/provider-compat.lock.d"
  /bin/mkdir "$h/provider-compat.lock.d"
  pending_nonce=abcdefabcdefabcdefabcdefabcdefab
  printf '{"pid":%s,"epoch":%s,"nonce":"%s"}\n' "$$" "$(/bin/date +%s)" "$pending_nonce" > "$h/provider-compat.lock.d/.lock.json.$pending_nonce.tmp"
  apply_default "$h"
  assert_eq 3 "$RUN_CODE" pending-active || return 1
  assert_file "$h/provider-compat.lock.d/.lock.json.$pending_nonce.tmp"
}

t_cache_conflict_and_drift() {
  new_home cache
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  printf old > "$h/models_cache.json"
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" apply || return 1
  printf new > "$h/models_cache.json"
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" rollback || return 1
  [ "$(/bin/cat "$h/models_cache.json")" = new ] || return 1
  find "$h" -name 'models_cache.json.bak-provider-compat-*' -type f | /usr/bin/grep . >/dev/null || return 1
  new_home drift
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" drift-setup || return 1
  /usr/bin/osascript -l JavaScript - "$h/config.toml" <<'JXA' || return 1
ObjC.import('Foundation');
function run(a) {
  let e = Ref(), s = $.NSString.stringWithContentsOfFileEncodingError($(a[0]), $.NSUTF8StringEncoding, e);
  if (!s) throw Error('read');
  let text = s.js, matches = text.match(/^model_catalog_json[ \t]*=.*$/gm) || [];
  if (matches.length !== 1) throw Error('expected one top-level catalog key');
  text = text.replace(/^model_catalog_json[ \t]*=.*$/m, 'model_catalog_json = "/user/change"');
  if (!$(text).writeToFileAtomicallyEncodingError($(a[0]), true, $.NSUTF8StringEncoding, e)) throw Error('write');
}
JXA
  run_tool status --codex-home "$h" --codex-version 0.144.1
  assert_eq 3 "$RUN_CODE" drift-status
}

t_unique_backups() {
  new_home unique
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  printf cache > "$h/models_cache.json"
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" first-apply || return 1
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" first-rollback || return 1
  printf collision > "$h/models_cache.json.bak-provider-compat-20000101-000000"
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" second-apply || return 1
  config_count=$(find "$h" -name 'config.toml.bak-provider-compat-*' -type f | /usr/bin/wc -l | tr -d ' ')
  cache_count=$(find "$h" -name 'models_cache.json.bak-provider-compat-*' -type f | /usr/bin/wc -l | tr -d ' ')
  [ "$config_count" -eq 2 ] && [ "$cache_count" -eq 2 ] || return 1
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" second-rollback
}

t_status_semantic_and_stale() {
  new_home semantic
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" setup || return 1
  generated="$h/model-catalogs/models-0.144.1.standard-responses-compat.json"
  /usr/bin/osascript -l JavaScript - "$generated" <<'JXA' || return 1
ObjC.import('Foundation');
function run(a){let e=Ref(),s=$.NSString.stringWithContentsOfFileEncodingError($(a[0]),$.NSUTF8StringEncoding,e),o=JSON.parse(s.js);o.models.find(function(x){return x.slug==='gpt-5.6-sol';}).use_responses_lite=true;if(!$(JSON.stringify(o,null,2)+'\n').writeToFileAtomicallyEncodingError($(a[0]),true,$.NSUTF8StringEncoding,e))throw Error('write');}
JXA
  json_set_string "$h/provider-compat-state.json" generated_catalog.sha256 "$(hash_file "$generated")"
  run_tool status --codex-home "$h" --codex-version 0.144.1
  assert_eq 3 "$RUN_CODE" semantic || return 1
  drift_hash=$(hash_file "$generated")
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" semantic-rollback || return 1
  [ "$(hash_file "$generated")" = "$drift_hash" ] || return 1
  assert_not_contains "$h/config.toml" 'standard-responses-compat' || return 1
  assert_no_path "$h/provider-compat-state.json" || return 1
  assert_no_path "$h/provider-compat-transaction.json" || return 1
  new_home stale
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" stale-setup || return 1
  run_tool_env CODEX_PROVIDER_COMPAT_TEST_VERSIONS 'cli=' status --codex-home "$h"
  assert_eq 3 "$RUN_CODE" unknown-version || return 1
  assert_contains "$RUN_OUT" 'result=unknown' || return 1
  run_tool status --codex-home "$h" --codex-version 0.145.0
  assert_eq 4 "$RUN_CODE" stale
}

t_state_backup_health() {
  new_home backup-health
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  printf cache > "$h/models_cache.json"
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" setup || return 1
  config_backup=$(find "$h" -name 'config.toml.bak-provider-compat-*' -type f | /usr/bin/awk 'NR==1{print;exit}')
  /bin/rm "$config_backup"
  run_tool status --codex-home "$h" --codex-version 0.144.1
  assert_eq 3 "$RUN_CODE" missing-config-backup || return 1
  new_home cache-health
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  printf cache > "$h/models_cache.json"
  apply_default "$h"
  assert_eq 0 "$RUN_CODE" cache-setup || return 1
  cache_backup=$(find "$h" -name 'models_cache.json.bak-provider-compat-*' -type f | /usr/bin/awk 'NR==1{print;exit}')
  /bin/rm "$cache_backup"
  run_tool status --codex-home "$h" --codex-version 0.144.1
  assert_eq 3 "$RUN_CODE" missing-cache-backup
}

t_version_and_network() {
  new_home actual-version-conflict
  h=$NEW_HOME
  /bin/mkdir -p "$h/bin" "$h/plugins/.plugin-appserver" "$h/run-cwd"
  printf '#!/bin/sh\nprintf "codex-cli 0.144.1\\n"\n' > "$h/bin/codex"
  printf '#!/bin/sh\nprintf "codex-app-server 0.143.0\\n"\n' > "$h/plugins/.plugin-appserver/codex"
  /bin/chmod 700 "$h/bin/codex" "$h/plugins/.plugin-appserver/codex"
  (
    cd "$h/run-cwd" || exit 1
    /usr/bin/env PATH="$h/bin:$PATH" /bin/sh "$TOOL" apply --yes --codex-home "$h" --catalog-file "$FIXTURES/models-valid.json"
  ) > "$RUN_OUT" 2>&1
  RUN_CODE=$?
  assert_eq 3 "$RUN_CODE" actual-conflict || return 1
  assert_contains "$RUN_OUT" 'version source: PATH CLI -> 0.144.1' || return 1
  assert_contains "$RUN_OUT" 'version source: Codex home app-server -> 0.143.0' || return 1
  [ "$(find "$h/run-cwd" -type f | /usr/bin/wc -l | tr -d ' ')" = 0 ] || return 1
  new_home actual-cli-only
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  /bin/mkdir "$h/bin" "$h/run-cwd"
  printf '#!/bin/sh\nprintf "codex-cli 0.144.1\\n"\n' > "$h/bin/codex"
  /bin/chmod 700 "$h/bin/codex"
  (
    cd "$h/run-cwd" || exit 1
    /usr/bin/env PATH="$h/bin:$PATH" /bin/sh "$TOOL" apply --yes --codex-home "$h" --catalog-file "$FIXTURES/models-valid.json"
  ) > "$RUN_OUT" 2>&1
  RUN_CODE=$?
  assert_eq 0 "$RUN_CODE" actual-cli-only || return 1
  assert_contains "$RUN_OUT" 'version source: PATH CLI -> 0.144.1' || return 1
  [ "$(find "$h/run-cwd" -type f | /usr/bin/wc -l | tr -d ' ')" = 0 ] || return 1
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" actual-cli-rollback || return 1
  new_home versions
  h=$NEW_HOME
  run_tool_env CODEX_PROVIDER_COMPAT_TEST_VERSIONS 'cli=0.144.1;desktop=0.143.0' apply --yes --codex-home "$h" --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 3 "$RUN_CODE" conflict || return 1
  new_home cli-only
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  run_tool_env CODEX_PROVIDER_COMPAT_TEST_VERSIONS 'cli=0.144.1' apply --yes --codex-home "$h" --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 0 "$RUN_CODE" cli-only || return 1
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" cli-rollback || return 1
  new_home desktop-only
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  run_tool_env CODEX_PROVIDER_COMPAT_TEST_VERSIONS 'desktop=0.144.1' apply --yes --codex-home "$h" --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 0 "$RUN_CODE" desktop-only || return 1
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" desktop-rollback || return 1
  new_home same-version
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  run_tool_env CODEX_PROVIDER_COMPAT_TEST_VERSIONS 'cli=0.144.1;desktop=0.144.1' apply --yes --codex-home "$h" --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 0 "$RUN_CODE" same-version || return 1
  rollback_default "$h"
  assert_eq 0 "$RUN_CODE" same-rollback || return 1
  new_home malformed-version
  h=$NEW_HOME
  run_tool_env CODEX_PROVIDER_COMPAT_TEST_VERSIONS 'cli=not-a-version' apply --yes --codex-home "$h" --catalog-file "$FIXTURES/models-valid.json"
  assert_eq 3 "$RUN_CODE" malformed || return 1
  for mode in 404 500 timeout redirect slow truncated empty oversize; do
    new_home "net-$mode"
    h=$NEW_HOME
    run_tool_env CODEX_PROVIDER_COMPAT_TEST_DOWNLOAD_MODE "$mode" apply --yes --codex-home "$h" --codex-version 0.144.1
    assert_eq 5 "$RUN_CODE" "$mode" || return 1
    [ "$(find "$h" -type f | /usr/bin/wc -l | tr -d ' ')" = 0 ] || return 1
  done
}

t_permission_failure() {
  new_home permission
  h=$NEW_HOME
  /bin/cp "$FIXTURES/config-basic.toml" "$h/config.toml"
  original=$(hash_file "$h/config.toml")
  /bin/chmod 500 "$h"
  apply_default "$h"
  rc=$RUN_CODE
  /bin/chmod 700 "$h"
  assert_eq 3 "$rc" permission || return 1
  [ "$(hash_file "$h/config.toml")" = "$original" ] || return 1
  assert_no_path "$h/provider-compat-state.json"
}

t_curl_capability() {
  /usr/bin/curl --help all 2>/dev/null | /usr/bin/grep -- '--max-filesize' >/dev/null
}

case_run lifecycle t_cycle
case_run web-search t_web_search
case_run dry-run-doctor t_dry_run_and_doctor
case_run unauthorized-test-hook t_unauthorized_test_hook
case_run doctor-conclusions t_doctor_conclusions
case_run catalog-failures t_catalog_failures
case_run config-lexer t_config_lexer
case_run bom-crlf-permissions t_bom_crlf_permissions
case_run missing-empty-config t_missing_and_empty_config
case_run symlink-guards t_symlink_guards
case_run home-path-guards t_home_path_guards
case_run system-alias-normalization t_system_alias_normalization
case_run state-transaction-tamper t_state_and_transaction_tamper
case_run apply-fault-recovery t_apply_fault_recovery
case_run rollback-fault-recovery t_rollback_fault_recovery
case_run signal-crash-recovery t_signal_and_crash_recovery
case_run tmpdir-safety t_tmpdir_safety
case_run crash-cache-conflict t_crash_cache_conflict
case_run toctou t_toctou
case_run late-transaction-config-race t_late_transaction_config_race
case_run locks t_locks
case_run cache-conflict-drift t_cache_conflict_and_drift
case_run unique-backups t_unique_backups
case_run status-semantic-stale t_status_semantic_and_stale
case_run state-backup-health t_state_backup_health
case_run version-network t_version_and_network
case_run permission-failure t_permission_failure
case_run curl-capability t_curl_capability

REAL_AFTER=$(snapshot_real)
if [ "$REAL_BEFORE" = "$REAL_AFTER" ]; then
  PASSED=$((PASSED + 1))
  printf 'PASS real-home-unchanged\n'
else
  FAILED=$((FAILED + 1))
  printf 'FAIL real-home-unchanged\n'
  printf '%s\n' '--- before ---' "$REAL_BEFORE" '--- after ---' "$REAL_AFTER"
fi

case "$SUITE_ROOT" in
  "$TMP_BASE"/cpc-macos-suite.*)
    /usr/bin/find "$SUITE_ROOT" -depth -type l -exec /bin/rm -f {} \;
    /usr/bin/find "$SUITE_ROOT" -depth -type f -exec /bin/rm -f {} \;
    /usr/bin/find "$SUITE_ROOT" -depth -type d -exec /bin/rmdir {} \; 2>/dev/null || true
    ;;
  *)
    warn_path=$SUITE_ROOT
    printf 'unsafe cleanup path: %s\n' "$warn_path" >&2
    FAILED=$((FAILED + 1))
    ;;
esac

printf 'macOS tests: passed=%s failed=%s\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
