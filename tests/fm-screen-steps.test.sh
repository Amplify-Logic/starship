#!/usr/bin/env bash
# Behavior tests for bin/fm-screen-steps.sh: the on-screen steps card over a
# page the captain fills in, its Arc opening, and its Done and Stuck replies.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STEPS="$ROOT/bin/fm-screen-steps.sh"
TMP_ROOT=$(fm_test_tmproot fm-screen-steps)
unset FM_STATE_OVERRIDE || true
export FM_SCREEN_STEPS_ARC_TIMEOUT=5

# A copy of the script in its own code root, with stand-ins for swift, open,
# osascript and bin/fm-desk-voice.sh, so no case reaches the real browser,
# screen or Firstmate chat. Each stand-in logs its arguments. The fake card
# app sleeps under its bundle path, so the script sees it running; open
# records its pid where the real card would. The fake osascript runs the
# script's AppleScript against arc.json, a model of Arc with a Little Arc
# popup in front of a private window and the captain's main window. Arc
# counts as installed unless arc.absent exists; arc.refuse makes Arc refuse
# its Automation permission, and arc.unready makes that many first calls fail
# as a just-started Arc does before its window exists.
new_root() {  # <name>
  local fx="$TMP_ROOT/$1"
  mkdir -p "$fx/root/bin" "$fx/root/screen-steps/Sources" "$fx/fake" "$fx/home/state"
  fx=$(cd "$fx" && pwd -P)
  cp "$STEPS" "$fx/root/bin/fm-screen-steps.sh"
  : > "$fx/root/screen-steps/Package.swift"
  : > "$fx/root/screen-steps/Sources/ScreenSteps.swift"
  cat > "$fx/root/bin/fm-desk-voice.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "FM_HOME=\$FM_HOME" "\$@" > "$fx/desk-voice.log"
printf 'sent: herdr 1-1\n'
EOF
  cat > "$fx/fake/swift" <<EOF
#!/usr/bin/env bash
printf 'build\n' >> "$fx/swift.log"
mkdir -p .build/release
printf '#!/bin/sh\nsleep 15\n' > .build/release/ScreenSteps
chmod +x .build/release/ScreenSteps
EOF
  cat > "$fx/fake/open" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$fx/open.log"
dir=""
for arg in "\$@"; do
  case "\$arg" in FM_SCREEN_STEPS_DIR=*) dir=\${arg#FM_SCREEN_STEPS_DIR=} ;; esac
done
last=\${*: -1}
case "\$last" in
  *ScreenSteps.app)
    "\$last/Contents/MacOS/ScreenSteps" >/dev/null 2>&1 &
    printf '%s\n' "\$!" > "\$dir/card.pid"
    printf '%s\n' "\$!" >> "$fx/card-pids"
    ;;
esac
EOF
  cat > "$fx/fake/osascript" <<'EOF'
#!/usr/bin/env python3
# Runs the AppleScript it is given against a model of Arc's windows kept in
# arc.json, understanding only a small closed subset; anything else is
# refused and logged to arc-unsupported.log, so no request goes unchecked.
# Each call is logged to osascript.log as its language and arguments, and
# each operation on Arc to arc-ops.log as one JSON line.
import json, os, re, sys

FX = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARC = "company.thebrowser.Browser"
APP = ("app", ARC)


def at(name):
    return os.path.join(FX, name)


def append(name, text):
    with open(at(name), "a") as f:
        f.write(text + "\n")


class Unsupported(Exception):
    pass


class ScriptError(Exception):
    pass


class ExitRepeat(Exception):
    pass


TOKEN = re.compile(r'\s*(?:(?P<str>"(?:[^"\\]|\\.)*")|(?P<num>\d+)|(?P<word>[A-Za-z_]\w*)|(?P<sym>[(){}:,<>=]))')


def tokenize(line):
    toks, pos = [], 0
    while line[pos:].strip():
        m = TOKEN.match(line, pos)
        if not m:
            raise Unsupported(line.strip())
        pos = m.end()
        kind = m.lastgroup
        val = m.group(kind)
        toks.append((kind, json.loads(val) if kind == "str" else int(val) if kind == "num" else val))
    return toks


def words(toks):
    return [v for _, v in toks]


def split_at(toks, word):
    for i, tok in enumerate(toks):
        if tok == ("word", word):
            return toks[:i], toks[i + 1:]
    return None


class Source:
    def __init__(self, text):
        self.lines = [tokenize(l) for l in text.splitlines() if l.strip() and not l.strip().startswith("--")]
        self.i = 0


def parse_block(src, enders):
    body = []
    while src.i < len(src.lines):
        toks = src.lines[src.i]
        src.i += 1
        w = words(toks)
        for e in enders or []:
            if w[:len(e)] == list(e) and (len(w) == len(e) or e == ("on", "error")):
                return body, w
        body.append(parse_stmt(toks, src))
    if enders:
        raise Unsupported("missing " + " or ".join(" ".join(e) for e in enders))
    return body, None


def parse_stmt(toks, src):
    w = words(toks)
    if w[:2] == ["on", "run"] and len(w) <= 3:
        body, _ = parse_block(src, [("end", "run")])
        return ("run", w[2] if len(w) == 3 else None, body)
    if w[0] == "tell":
        parts = split_at(toks[1:], "to")
        if parts:
            return ("tell", parts[0], [parse_stmt(parts[1], src)])
        body, _ = parse_block(src, [("end", "tell")])
        return ("tell", toks[1:], body)
    if w[:2] == ["repeat", "with"] and len(w) > 4 and w[3] == "in":
        body, _ = parse_block(src, [("end", "repeat")])
        return ("repeat", w[2], toks[4:], body)
    if w == ["exit", "repeat"]:
        return ("exit",)
    if w[0] == "if" and w[-1] == "then":
        body, end = parse_block(src, [("else",), ("end", "if")])
        other = parse_block(src, [("end", "if")])[0] if end == ["else"] else []
        return ("if", toks[1:-1], body, other)
    if w == ["try"]:
        body, end = parse_block(src, [("on", "error"), ("end", "try")])
        handler = parse_block(src, [("end", "try")])[0] if end[0] == "on" else []
        return ("try", body, handler)
    if w[0] == "set" and split_at(toks[1:], "to"):
        lhs, rhs = split_at(toks[1:], "to")
        return ("set", lhs, rhs)
    if w[:2] == ["make", "new"] and len(w) > 2:
        rest = toks[3:]
        if rest and words(rest[:2]) != ["with", "properties"]:
            raise Unsupported(" ".join(map(str, w)))
        return ("make", w[2], rest[2:] if rest else None)
    if w == ["activate"]:
        return ("activate",)
    raise Unsupported(" ".join(map(str, w)))


def same(a, b):
    return a is b if isinstance(a, dict) or isinstance(b, dict) else a == b


class Env:
    def __init__(self, state, argv):
        self.state, self.argv, self.vars, self.tells = state, argv, {}, []

    def windows(self):
        return self.state["windows"]

    def in_arc(self):
        return APP in self.tells

    def front(self):
        if not self.windows():
            raise ScriptError("Arc got an error: Can't get window 1. Invalid index. (-1719)")
        return self.windows()[0]

    def op(self, **entry):
        append("arc-ops.log", json.dumps(entry))


class Expr:
    def __init__(self, toks, env):
        self.t, self.i, self.env = toks, 0, env

    def peek(self, n=0):
        j = self.i + n
        return self.t[j] if j < len(self.t) else (None, None)

    def word(self, *ws):
        if all(self.peek(n) == ("word", w) for n, w in enumerate(ws)):
            self.i += len(ws)
            return True
        return False

    def sym(self, s):
        if self.peek() == ("sym", s):
            self.i += 1
            return True
        return False

    def expect(self, s):
        if not self.sym(s):
            raise Unsupported("expected %s in %s" % (s, " ".join(map(str, words(self.t)))))

    def value(self):
        v = self.or_()
        if self.i != len(self.t):
            raise Unsupported(" ".join(map(str, words(self.t))))
        return v

    def or_(self):
        v = self.and_()
        while self.word("or"):
            r = self.and_()
            v = v is True or r is True
        return v

    def and_(self):
        v = self.cmp()
        while self.word("and"):
            r = self.cmp()
            v = v is True and r is True
        return v

    def cmp(self):
        left = self.of()
        if self.word("is", "not"):
            return not same(left, self.of())
        if self.word("is") or self.sym("="):
            return same(left, self.of())
        if self.sym(">"):
            return left > self.of()
        if self.sym("<"):
            return left < self.of()
        return left

    def of(self):
        if self.word("count"):
            self.word("of")
            return len(self.of())
        if self.word("item"):
            n = self.atom()
            if not self.word("of"):
                raise Unsupported("item without of")
            seq = self.of()
            if not 1 <= n <= len(seq):
                raise ScriptError("Can't get item %d. (-1728)" % n)
            return seq[n - 1]
        kind, name = self.peek()
        if kind == "word" and self.peek(1) == ("word", "of") and name not in self.env.vars:
            self.i += 2
            return prop(self.env, self.of(), name)
        return self.atom()

    def atom(self):
        kind, v = self.peek()
        self.i += 1
        if kind in ("str", "num"):
            return v
        if (kind, v) == ("sym", "("):
            r = self.or_()
            self.expect(")")
            return r
        if (kind, v) == ("sym", "{"):
            return self.braces()
        if kind == "word":
            if v in ("true", "false"):
                return v == "true"
            if v == "missing" and self.word("value"):
                return None
            if v in self.env.vars:
                return self.env.vars[v]
            if self.env.in_arc():
                if v == "windows":
                    return list(self.env.windows())
                if v == "front" and self.word("window"):
                    return self.env.front()
                if v == "window":
                    n = self.atom()
                    if not 1 <= n <= len(self.env.windows()):
                        raise ScriptError("Can't get window %d. Invalid index. (-1719)" % n)
                    return self.env.windows()[n - 1]
        raise Unsupported("unknown term %s" % v)

    def braces(self):
        if self.sym("}"):
            return []
        record = self.peek()[0] == "word" and self.peek(1) == ("sym", ":")
        out = {} if record else []
        while True:
            if record:
                key = self.peek()[1]
                self.i += 1
                self.expect(":")
                out[key] = self.or_()
            else:
                out.append(self.or_())
            if self.sym("}"):
                return out
            self.expect(",")


def is_window(obj):
    return isinstance(obj, dict) and "tabs" in obj


def prop(env, obj, name):
    if not is_window(obj):
        raise Unsupported("property %s of a non-window" % name)
    if name == "index":
        return env.windows().index(obj) + 1
    if name == "spaces":
        return list(range(obj["spaces"]))
    if name not in obj:
        raise Unsupported("unknown window property %s" % name)
    return obj[name]


def set_prop(env, obj, name, val):
    if not is_window(obj):
        raise Unsupported("set %s of a non-window" % name)
    env.op(op="set", window=obj["name"], property=name, value=val)
    if name == "index":
        wins = env.windows()
        wins.remove(obj)
        wins.insert(max(0, min(val, len(wins) + 1) - 1), obj)
    else:
        obj[name] = val


def tell_target(toks, env):
    w = words(toks)
    if w and w[0] == "application":
        app = w[2] if w[1:2] == ["id"] and len(w) == 3 else w[1] if len(w) == 2 else None
        env.op(op="tell", app=app)
        if app not in (ARC, "Arc"):
            raise Unsupported("no fake for application %s" % app)
        return APP
    target = Expr(toks, env).value()
    if not is_window(target):
        raise Unsupported("tell a non-window")
    return target


def run(stmts, env):
    for s in stmts:
        execute(s, env)


def execute(s, env):
    kind = s[0]
    if kind == "run":
        if s[1]:
            env.vars[s[1]] = env.argv
        run(s[2], env)
    elif kind == "tell":
        env.tells.append(tell_target(s[1], env))
        try:
            run(s[2], env)
        finally:
            env.tells.pop()
    elif kind == "repeat":
        for item in list(Expr(s[2], env).value()):
            env.vars[s[1]] = item
            try:
                run(s[3], env)
            except ExitRepeat:
                break
    elif kind == "exit":
        raise ExitRepeat()
    elif kind == "if":
        cond = Expr(s[1], env).value()
        if not isinstance(cond, bool):
            raise Unsupported("non-boolean condition")
        run(s[2] if cond else s[3], env)
    elif kind == "try":
        try:
            run(s[1], env)
        except ScriptError:
            run(s[2], env)
    elif kind == "set":
        lhs, rhs = s[1], s[2]
        val = Expr(rhs, env).value()
        if len(lhs) == 1 and lhs[0][0] == "word":
            env.vars[lhs[0][1]] = val
        elif len(lhs) > 2 and lhs[0][0] == "word" and lhs[1] == ("word", "of"):
            set_prop(env, Expr(lhs[2:], env).value(), lhs[0][1], val)
        else:
            raise Unsupported("set " + " ".join(map(str, words(lhs))))
    elif kind == "make":
        if not env.in_arc():
            raise Unsupported("make outside Arc")
        props = Expr(s[2], env).value() if s[2] else {}
        if s[1] == "tab":
            win = next((t for t in reversed(env.tells) if is_window(t)), None) or env.front()
            win["tabs"].append(props.get("URL"))
            env.op(op="make", new="tab", window=win["name"], properties=props)
        elif s[1] == "window" and not props:
            env.windows().insert(0, {"name": "new", "spaces": 1, "incognito": False,
                                     "bounds": [0, 38, 1200, 800], "zoomed": False, "tabs": []})
            env.op(op="make", new="window")
        else:
            raise Unsupported("make new %s" % s[1])
    elif kind == "activate":
        if env.tells[-1:] != [APP]:
            raise Unsupported("activate outside Arc")
        env.state["frontmost"] = True
        env.op(op="activate")


def main(argv):
    lang, script, args, i = "AppleScript", [], [], 0
    while i < len(argv):
        if argv[i] == "-l":
            lang = argv[i + 1]
        elif argv[i] == "-e":
            script.append(argv[i + 1])
        else:
            args = argv[i:]
            break
        i += 2
    append("osascript.log", " ".join([lang] + args))
    if lang == "JavaScript":
        print("no" if os.path.exists(at("arc.absent")) else "yes")
        return 0
    if os.path.exists(at("arc.refuse")):
        sys.stderr.write("Not authorized to send Apple events to Arc. (-1743)\n")
        return 1
    if os.path.exists(at("arc.unready")):
        left = int(open(at("arc.unready")).read().strip() or 0)
        if left > 0:
            open(at("arc.unready"), "w").write("%d\n" % (left - 1))
            sys.stderr.write("Arc got an error: Can't get window 1. Invalid index. (-1719)\n")
            return 1
    with open(at("arc.json")) as f:
        state = json.load(f)
    try:
        prog, _ = parse_block(Source("\n".join(script)), None)
        run(prog, Env(state, args))
    except Unsupported as e:
        append("arc-unsupported.log", str(e))
        sys.stderr.write("fake osascript: unsupported AppleScript: %s\n" % e)
        return 64
    except ScriptError as e:
        sys.stderr.write("%s\n" % e)
        return 1
    finally:
        with open(at("arc.json"), "w") as f:
            json.dump(state, f)
    return 0


sys.exit(main(sys.argv[1:]))
EOF
  cat > "$fx/arc.json" <<'EOF'
{"frontmost": false, "windows": [
  {"name": "Little Arc", "spaces": 0, "incognito": false, "bounds": [900, 120, 1400, 700], "zoomed": false, "tabs": ["https://news.example.com"]},
  {"name": "private", "spaces": 1, "incognito": true, "bounds": [200, 200, 1000, 800], "zoomed": false, "tabs": []},
  {"name": "main", "spaces": 3, "incognito": false, "bounds": [0, 38, 1512, 982], "zoomed": true, "tabs": ["https://mail.example.com"]}
]}
EOF
  chmod +x "$fx/fake/"* "$fx/root/bin/"*
  touch "$fx/swift.log" "$fx/open.log" "$fx/osascript.log"
  printf '%s\n' "$fx"
}

# Runs the fixture's script as a person would at the desk: the automated-run
# markers are cleared, which is safe only because every tool it can reach is a
# stand-in. run_automated keeps them, as CI or a pipeline agent would.
run_steps() {  # <fixture> [args...]
  local fx=$1
  shift
  env -u CI -u GITHUB_ACTIONS -u NO_MISTAKES_GATE \
    PATH="$fx/fake:$PATH" FM_HOME="$fx/home" "$fx/root/bin/fm-screen-steps.sh" "$@"
}

run_automated() {  # <fixture> <VAR=value>... -- [args...]
  local fx=$1 vars=()
  shift
  while [ "$1" != -- ]; do
    vars+=("$1")
    shift
  done
  shift
  env -u CI -u GITHUB_ACTIONS -u NO_MISTAKES_GATE "${vars[@]}" \
    PATH="$fx/fake:$PATH" FM_HOME="$fx/home" "$fx/root/bin/fm-screen-steps.sh" "$@"
}

stop_cards() {  # <fixture>
  local pid
  [ -f "$1/card-pids" ] || return 0
  while IFS= read -r pid; do
    kill "$pid" 2>/dev/null || true
  done < "$1/card-pids"
}

# Portable mode bits. Platform-detected, never the `stat -f || stat -c` fallback:
# GNU stat reads the file system under -f and prints that block instead.
file_mode() {  # <file>
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

card_field() {  # <fixture> <python expression over card>
  python3 -c 'import json,sys; card=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' \
    "$1/home/state/screen-steps/card.json" "$2"
}

# Evaluates <expression> over the fake Arc's state (arc) and the operations
# it performed (ops).
arc_field() {  # <fixture> <python expression over arc and ops>
  python3 -c 'import json,os,sys
arc=json.load(open(os.path.join(sys.argv[1], "arc.json")))
log=os.path.join(sys.argv[1], "arc-ops.log")
ops=[json.loads(l) for l in open(log)] if os.path.exists(log) else []
print(eval(sys.argv[2]))' "$1" "$2"
}

write_steps() {  # <file>
  cat > "$1" <<'EOF'
# Create the app
Open My Apps first.

1. Click + and choose New App.
2. Platform: tick `iOS`.
3) Name: `Harbour Logbook` and SKU `logbook-1`
   Keep the capital letters, **exactly**.
- Bundle ID: `com.example.logbook`, again `iOS`
EOF
}

test_show_builds_the_card_and_opens_the_page_in_arc() {
  local fx out
  fx=$(new_root show)
  write_steps "$fx/steps.md"
  out=$(run_steps "$fx" show --url https://appstoreconnect.apple.com/apps --steps-file "$fx/steps.md" 2>"$fx/err") \
    || fail "show failed: $out $(cat "$fx/err")"
  assert_contains "$out" "opened: arc https://appstoreconnect.apple.com/apps" "the page opens in Arc"
  assert_contains "$out" "card: $fx/home/state/screen-steps/card.json" "show names the card it wrote"
  assert_equals "Create the app" "$(card_field "$fx" 'card["title"]')" "the first heading is the title"
  assert_equals "Open My Apps first." "$(card_field "$fx" 'card["note"]')" "lines before the first step are the note"
  assert_equals 4 "$(card_field "$fx" 'len(card["steps"])')" "numbered and bulleted lines are steps"
  assert_equals "[]" "$(card_field "$fx" 'card["steps"][0]["values"]')" "a step without code has nothing to copy"
  assert_equals "['Harbour Logbook', 'logbook-1']" "$(card_field "$fx" 'card["steps"][2]["values"]')" "every code span is a value to copy"
  assert_equals "Name: \`Harbour Logbook\` and SKU \`logbook-1\`|Keep the capital letters, **exactly**." \
    "$(card_field "$fx" '"|".join(card["steps"][2]["text"].splitlines())')" "an indented line joins its step"
  assert_equals "['com.example.logbook', 'iOS']" "$(card_field "$fx" 'card["steps"][3]["values"]')" "values are kept per step"
  assert_equals 600 "$(file_mode "$fx/home/state/screen-steps/card.json")" "the card file is private"
  assert_equals 1 "$(grep -c build "$fx/swift.log")" "the card app is built on first use"
  assert_absent "$fx/arc-unsupported.log" "every request show made to Arc was understood"
  assert_equals "['https://mail.example.com', 'https://appstoreconnect.apple.com/apps']" \
    "$(arc_field "$fx" '{w["name"]: w["tabs"] for w in arc["windows"]}["main"]')" "Arc opens the page as a new tab of its main window"
  assert_equals "[['https://news.example.com'], []]" \
    "$(arc_field "$fx" '[w["tabs"] for w in arc["windows"] if w["name"] != "main"]')" "the Little Arc popup and the private window get no tab"
  assert_equals "main True" "$(arc_field "$fx" 'arc["windows"][0]["name"], arc["frontmost"]' | tr -d "(),'")" "the main window and Arc come to the front"
  assert_grep "https://appstoreconnect.apple.com/apps" "$fx/osascript.log" "the URL is handed to Arc as an argument"
  assert_no_grep "appstoreconnect" "$fx/open.log" "the page is never opened with plain open, which Arc shows as a Little Arc popup"
  assert_grep "-n -g --env FM_HOME=$fx/home --env FM_SCREEN_STEPS_ROOT=$fx/root --env FM_SCREEN_STEPS_DIR=$fx/home/state/screen-steps $fx/root/screen-steps/.build/ScreenSteps.app" \
    "$fx/open.log" "the card starts in the background for this home, so the page keeps the keyboard"
  stop_cards "$fx"
  pass "fm-screen-steps: show writes the card from the Markdown steps and opens the page in Arc's main window"
}

test_second_show_replaces_the_running_card() {
  local fx out first
  fx=$(new_root replace)
  write_steps "$fx/steps.md"
  run_steps "$fx" show --steps-file "$fx/steps.md" >/dev/null 2>&1 || fail "first show failed"
  first=$(card_field "$fx" 'card["revision"]')
  printf '# Second\n1. Only step\n' > "$fx/steps2.md"
  out=$(run_steps "$fx" show --steps-file "$fx/steps2.md" 2>&1) || fail "second show failed: $out"
  assert_equals "Second" "$(card_field "$fx" 'card["title"]')" "the second show replaces the steps"
  assert_not_equals "$first" "$(card_field "$fx" 'card["revision"]')" "a replaced card gets a new revision, so its ticks reset"
  assert_equals 1 "$(grep -c ScreenSteps.app "$fx/open.log")" "the running card is reused, not started twice"
  assert_equals 1 "$(grep -c build "$fx/swift.log")" "an unchanged card app is not rebuilt"
  assert_equals 0 "$(grep -c . "$fx/osascript.log")" "without --url nothing is opened"
  run_steps "$fx" hide || fail "hide failed"
  assert_absent "$fx/home/state/screen-steps/card.json" "hide removes the card file the card closes on"
  stop_cards "$fx"
  pass "fm-screen-steps: a second show replaces the running card's steps and hide closes it"
}

test_show_falls_back_without_arc() {
  local fx out
  fx=$(new_root no-arc)
  write_steps "$fx/steps.md"
  touch "$fx/arc.absent"
  out=$(run_steps "$fx" show --url https://example.com/form --steps-file "$fx/steps.md" 2>"$fx/err") \
    || fail "show without Arc failed: $out"
  assert_contains "$out" "opened: default-browser https://example.com/form" "without Arc the default browser opens the page"
  assert_grep "Arc is not installed" "$fx/err" "the fallback says why"
  assert_grep "https://example.com/form" "$fx/open.log" "the page opens with the default browser"
  stop_cards "$fx"

  fx=$(new_root arc-refuses)
  write_steps "$fx/steps.md"
  touch "$fx/arc.refuse"
  out=$(run_steps "$fx" show --url https://example.com/form --steps-file "$fx/steps.md" 2>"$fx/err") \
    || fail "show with Arc refusing failed: $out"
  assert_contains "$out" "opened: default-browser https://example.com/form" "a refused Arc falls back to the default browser"
  assert_grep "no Automation permission for Arc" "$fx/err" "the refusal is named"
  assert_equals 1 "$(grep -c '^AppleScript https://example.com/form$' "$fx/osascript.log")" "a refused permission is not retried"
  stop_cards "$fx"

  pass "fm-screen-steps: without Arc, or when Arc refuses, show still opens the page and the card"
}

# The captain's own Arc windows keep their place and size: show only adds a
# tab and brings the main window forward, including while a just-started Arc
# has no window yet. The fake Arc applies every operation the script asks of
# it, so any geometry change would show in its windows.
test_show_never_moves_or_resizes_an_arc_window() {
  local fx out windows before
  fx=$(new_root geometry)
  write_steps "$fx/steps.md"
  windows='sorted((w["name"], sorted((k, v) for k, v in w.items() if k != "tabs")) for w in arc["windows"])'
  before=$(arc_field "$fx" "$windows")
  echo 2 > "$fx/arc.unready"
  out=$(run_steps "$fx" show --url https://example.com/form --steps-file "$fx/steps.md" 2>&1) \
    || fail "show with a just-started Arc failed: $out"
  assert_contains "$out" "opened: arc https://example.com/form" "the page opens once Arc's window exists"
  assert_equals 3 "$(grep -c '^AppleScript https://example.com/form$' "$fx/osascript.log")" "a just-started Arc is asked again until its window exists"
  run_steps "$fx" show --url https://example.com/next --steps-file "$fx/steps.md" >/dev/null 2>&1 \
    || fail "a second show with a URL failed"
  assert_absent "$fx/arc-unsupported.log" "every request show made to Arc was understood"
  assert_equals "$before" "$(arc_field "$fx" "$windows")" "every Arc window keeps its position, size and state"
  assert_equals "[]" "$(arc_field "$fx" 'sorted({o["property"] for o in ops if o["op"] == "set"} - {"index"})')" \
    "the only window property show sets is which window is in front"
  assert_equals "['company.thebrowser.Browser']" "$(arc_field "$fx" 'sorted({o["app"] for o in ops if o["op"] == "tell"})')" \
    "no other app, such as System Events, is asked to touch Arc's windows"
  stop_cards "$fx"
  pass "fm-screen-steps: show never moves or resizes the captain's Arc window"
}

test_show_refuses_bad_input() {
  local fx rc
  fx=$(new_root refuse)
  write_steps "$fx/steps.md"
  rc=0
  run_steps "$fx" show --url "file:///etc/passwd" --steps-file "$fx/steps.md" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a non-web URL"
  printf '# Only a title\nand a note\n' > "$fx/empty.md"
  rc=0
  run_steps "$fx" show --steps-file "$fx/empty.md" >/dev/null 2>"$fx/err" || rc=$?
  expect_code 2 "$rc" "a steps file with no step"
  assert_grep "no steps in" "$fx/err" "the empty file is named"
  rc=0
  run_steps "$fx" show --steps-file "$fx/missing.md" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a missing steps file"
  rc=0
  run_steps "$fx" show >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "show without steps"
  assert_absent "$fx/home/state/screen-steps/card.json" "nothing is shown after a refusal"
  assert_equals 0 "$(grep -c . "$fx/open.log")" "nothing is opened after a refusal"
  pass "fm-screen-steps: show refuses non-web URLs and files without steps, opening nothing"
}

test_reply_sends_through_the_desk_voice_path() {
  local fx out rc
  fx=$(new_root reply)
  write_steps "$fx/steps.md"
  rc=0
  run_steps "$fx" reply "done" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a reply with no card showing"
  run_steps "$fx" show --steps-file "$fx/steps.md" >/dev/null 2>&1 || fail "show failed"

  out=$(run_steps "$fx" reply "done" 2>&1) || fail "reply done failed: $out"
  assert_equals "sent: herdr 1-1" "$out" "reply prints the delivery outcome"
  assert_equals "FM_HOME=$fx/home|send|--source|screen-steps|--|Done with the on-screen steps: Create the app" \
    "$(paste -sd '|' "$fx/desk-voice.log")" "Done goes into the primary chat through the desk-voice send path"

  run_steps "$fx" reply stuck >/dev/null 2>&1 || fail "reply stuck failed"
  assert_equals "Stuck on the on-screen steps: Create the app" "$(tail -n 1 "$fx/desk-voice.log")" "Stuck with nothing ticked names the card"

  run_steps "$fx" reply stuck --step 3 >/dev/null 2>&1 || fail "reply stuck --step failed"
  assert_equals "Stuck at step 3 of the on-screen steps: Create the app (Name: Harbour Logbook and SKU logbook-1 Keep the capital letters, exactly.)" \
    "$(tail -n 1 "$fx/desk-voice.log")" "Stuck names the step on one line"

  rc=0
  run_steps "$fx" reply stuck --step x >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a step that is not a number"
  rc=0
  run_steps "$fx" reply maybe >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unknown reply"
  stop_cards "$fx"
  pass "fm-screen-steps: Done and Stuck send one line into the Firstmate chat through bin/fm-desk-voice.sh send"
}

# A test, CI job or pipeline agent never reaches the captain's screen or chat:
# in an automated run show and reply refuse before calling open, osascript,
# the card or the desk-voice delivery.
test_automated_runs_never_reach_the_screen() {
  local fx var rc
  for var in CI=true GITHUB_ACTIONS=true NO_MISTAKES_GATE=1; do
    fx=$(new_root "automated-${var%%=*}")
    write_steps "$fx/steps.md"
    rc=0
    run_automated "$fx" "$var" -- show --url https://example.com/form --steps-file "$fx/steps.md" >/dev/null 2>"$fx/err" || rc=$?
    expect_code 3 "$rc" "show under $var"
    assert_grep "automated run" "$fx/err" "the refusal under $var says why"
    assert_equals 0 "$(grep -c . "$fx/open.log")" "show under $var never calls open"
    assert_equals 0 "$(grep -c . "$fx/osascript.log")" "show under $var never calls osascript"
    assert_equals 0 "$(grep -c . "$fx/swift.log")" "show under $var never builds the card"
    assert_absent "$fx/card-pids" "show under $var never starts the card"
    assert_absent "$fx/home/state/screen-steps/card.json" "show under $var writes no card"

    run_steps "$fx" show --steps-file "$fx/steps.md" >/dev/null 2>&1 || fail "show at the desk failed"
    rc=0
    run_automated "$fx" "$var" -- reply "done" >/dev/null 2>&1 || rc=$?
    expect_code 3 "$rc" "reply under $var"
    assert_absent "$fx/desk-voice.log" "reply under $var never types into the Firstmate chat"
    stop_cards "$fx"
  done

  fx=$(new_root automated-worktree)
  write_steps "$fx/steps.md"
  mkdir -p "$fx/.no-mistakes/worktrees/run1"
  mv "$fx/root" "$fx/.no-mistakes/worktrees/run1/root"
  rc=0
  env -u CI -u GITHUB_ACTIONS -u NO_MISTAKES_GATE PATH="$fx/fake:$PATH" FM_HOME="$fx/home" \
    "$fx/.no-mistakes/worktrees/run1/root/bin/fm-screen-steps.sh" show --url https://example.com/form --steps-file "$fx/steps.md" \
    >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "show from a no-mistakes worktree"
  assert_equals 0 "$(grep -c . "$fx/open.log")" "show from a no-mistakes worktree never calls open"
  assert_equals 0 "$(grep -c . "$fx/osascript.log")" "show from a no-mistakes worktree never calls osascript"

  pass "fm-screen-steps: CI, GitHub Actions and no-mistakes runs never open a page, start the card or reply"
}

# The card itself is a Swift package, so compiling and testing it needs macOS
# and swift. Its Swift tests never show a window.
test_card_app_compiles() {
  local out
  if [ "$(uname)" != Darwin ] || ! command -v swift >/dev/null 2>&1; then
    pass "fm-screen-steps: card build skipped (needs macOS and swift)"
    return
  fi
  out=$(swift build -c release --product ScreenSteps --package-path "$ROOT/screen-steps" \
    --scratch-path "$TMP_ROOT/swift-build" 2>&1) || fail "the card app does not build: $out"
  out=$(swift test --package-path "$ROOT/screen-steps" \
    --scratch-path "$TMP_ROOT/swift-test" 2>&1) || fail "card Swift tests failed: $out"
  pass "fm-screen-steps: the card app builds and its Swift tests pass"
}

test_show_builds_the_card_and_opens_the_page_in_arc
test_second_show_replaces_the_running_card
test_show_falls_back_without_arc
test_show_never_moves_or_resizes_an_arc_window
test_show_refuses_bad_input
test_reply_sends_through_the_desk_voice_path
test_automated_runs_never_reach_the_screen
test_card_app_compiles
