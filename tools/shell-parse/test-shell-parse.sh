#!/bin/bash
# Tests for hooks/lib/shell-parse.sh (HOOK_LIB=<dir> tests another copy). Run: bash tools/shell-parse/test-shell-parse.sh
# A runner script sources the lib under HOOK_SHELL (default /bin/bash, 3.2) with HOME at a temp folder, defines the two
# callbacks to print what they get, and parses one command from the start folder /s. Each case lists the lines it
# expects, in order: a redirect target arrives when the parser reads it, a command when its segment ends.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LIB="${HOOK_LIB:-$HERE/../../hooks/lib}"
GUARD="${HOOK:-$HERE/../../hooks/protected-paths-guard.sh}"
SH="${HOOK_SHELL:-/bin/bash}"
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
T=$(mktemp -d "${TMPDIR:-/tmp}/shell-parse-XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/hooks" "$T/home"
cp -R "$LIB" "$T/hooks/lib"
HR=$(cd -P "$T/home" && pwd -P)

cat >"$T/run.sh" <<RUN
HOOK=runner
HOME="$T/home"
. "$T/hooks/lib/hook-common.sh" </dev/null
. "$T/hooks/lib/shell-parse.sh"
on_command() { local o="C[\$CWD]" w; for w in "\$@"; do o="\$o <\$w>"; done; echo "\$o"; if [ "\$1" = xargs ]; then shift; sp_xargs "\$@"; fi; }
on_redirect() { echo "R[\$CWD] <\$1>"; }
CWD=/s
[ -z "\${PARSE_SET_U:-}" ] || set -u
[ -z "\${PARSE_STALE:-}" ] || SP_T0=\$((SECONDS - 10))
shell_parse "\$1"
RUN

PASS=0
FAIL=0
expect() {  # expect <label> <command> <expected line>...: the callbacks' output, one line each
  local label=$1 cmd=$2 want got
  shift 2
  want=$(printf '%s\n' "$@")
  got=$("$SH" "$T/run.sh" "$cmd" 2>&1)
  if [ "$got" = "$want" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n--- want\n%s\n--- got\n%s\n' "$label" "$want" "$got"; fi
}
check() {  # check <label> <0|1: did the condition hold>
  if [ "$2" = 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1"; fi
}

refuse() {  # refuse <label> <command>: the text is unreadable, so the parser refuses it (the hooks deny)
  local got
  got=$("$SH" "$T/run.sh" "$2" 2>&1)
  case "$got" in *'cannot be read exactly'*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL: %s\n%s\n' "$1" "$got" ;; esac
}

# words and quotes
expect "plain words" 'echo a b' 'C[/s] <echo> <a> <b>'
expect "quotes and escapes" "echo \"a b\" 'c d' e\\ f" 'C[/s] <echo> <a b> <c d> <e f>'
expect "escaped quote in double quotes" 'echo "a\"b"' 'C[/s] <echo> <a"b>'
expect "ANSI-C tab and newline decoded (a newline reads as a separator)" "echo \$'x\\ty\\nz'" $'C[/s] <echo> <x\ty;z>'
expect "ANSI-C escaped quote does not end the word" "printf \$'it\\'s'; a" $'C[/s] <printf> <it\'s>' 'C[/s] <a>'
expect "ANSI-C hex and octal escapes decoded" "echo \$'a\\x6fb \\151 \\n \\xZZ \\x7'" 'C[/s] <echo> <aob i ; \xZZ \x7>'
expect "ANSI-C unterminated takes the rest" "echo \$'a b" 'C[/s] <echo> <a b>'
expect "locale string \$\"..\" is a plain quote" 'echo $"a b" c' 'C[/s] <echo> <a b> <c>'
expect "<< inside \$(( )) is not a heredoc" $'n=$((1<<3))\na' 'C[/s] <1<<3>' 'C[/s] <a>'
expect "<< inside a standalone (( )) is not a heredoc" $'(( n = 1 << 3 ))\na' 'C[/s] <n> <=> <1> <<<> <3>' 'C[/s] <a>'
expect "a redirect inside \$(( )) is still read" 'echo $((a >f; b)) c' 'R[/s] <f>' 'C[/s] <a>' 'C[/s] <b>' 'C[/s] <echo> <$(..)> <c>'
expect "ANSI-C \\u and \\U escapes decoded" "echo \$'\\u0061\\U00000062'" 'C[/s] <echo> <ab>'
expect "op run with a word holding -- does not hang" 'op run "x -- y"; a' 'C[/s] <x -- y>' 'C[/s] <a>'
expect "multi-line heredoc body to a shell, <<- with tabs" $'bash <<-EOF\n\ta\n\tb > f\n\tEOF\nc' 'C[/s] <a>' 'R[/s] <f>' 'C[/s] <b>' 'C[/s] <bash>' 'C[/s] <c>'
expect "# inside a word is not a comment" 'echo a#b' 'C[/s] <echo> <a#b>'
expect "comment to end of line" $'a # c; b\nd' 'C[/s] <a>' 'C[/s] <d>'

# assignments, wrappers, keywords
expect "assignments and wrappers skipped" 'FOO=1 env -u X BAR=2 sudo -u me nice -n 5 timeout 5 time -p command -p exec -a n rm -f x' 'C[/s] <rm> <-f> <x>'
expect "the verb keeps the path as written" '/usr/bin/env FOO=1 /bin/rm x' 'C[/s] </bin/rm> <x>'
expect "keywords skipped" 'if a; then b' 'C[/s] <a>' 'C[/s] <b>'
expect "negation and braces" '! c; { d; }' 'C[/s] <c>' 'C[/s] <d>'
expect "nohup" 'nohup a b' 'C[/s] <a> <b>'
expect "wrapper and shell names in any case" 'SUDO -u me ENV X=1 Nice a; Bash -c "b"; ZSH -lc "c"' 'C[/s] <a>' 'C[/s] <b>' 'C[/s] <Bash> <-c> <b>' 'C[/s] <c>' 'C[/s] <ZSH> <-lc> <c>'
expect "cd and eval stay case-sensitive" 'CD /x; a' 'C[/s] <CD> </x>' 'C[/s] <a>'
expect "nohup and setsid options skipped" 'nohup -- a; setsid -f -w b; doas -a style c' 'C[/s] <a>' 'C[/s] <b>' 'C[/s] <c>'
expect "xcrun, arch, direnv exec, op run" 'xcrun --sdk macosx a; arch -arm64 b; arch -e X=1 c; direnv exec /p e; op run --env-file x -- f' 'C[/s] <a>' 'C[/s] <b>' 'C[/s] <c>' 'C[/s] <e>' 'C[/s] <f>'
expect "watch reads its command words as a string" 'watch -n 5 a b' 'C[/s] <a> <b>' 'C[/s] <watch> <-n> <5> <a> <b>'
expect "noglob and nocorrect are skipped" 'noglob nocorrect a' 'C[/s] <a>'
expect "a PID then a quote is not an ANSI-C string" $'echo $$\'a\\\'; b; echo \'x\'' 'C[/s] <echo> <$$a\>' 'C[/s] <b>' 'C[/s] <echo> <x>'
expect "ANSI-C NUL ends the string, octal wraps at a byte" "echo \$'g\\0it' \$'\\551'" 'C[/s] <echo> <g> <i>'
expect "direnv and op without exec or run are commands" 'direnv allow; op item get x' 'C[/s] <direnv> <allow>' 'C[/s] <op> <item> <get> <x>'
expect "op run stops at the first non-option word" 'op run -- a; op run b -- c' 'C[/s] <a>' 'C[/s] <b> <--> <c>'
expect "function, coproc, trap" 'function f { a; }; coproc N { b; }; coproc c; trap "d" EXIT' 'C[/s] <a>' 'C[/s] <b>' 'C[/s] <c>' 'C[/s] <d>' 'C[/s] <trap> <d> <EXIT>'

# separators
expect "separators" $'a | b && c || d & e\nf' 'C[/s] <a>' 'C[/s] <b>' 'C[/s] <c>' 'C[/s] <d>' 'C[/s] <e>' 'C[/s] <f>'

# redirects and heredocs
expect "output redirects" 'a >o 2>&1 >>p >|q &>r 3>s k' 'R[/s] <o>' 'R[/s] <p>' 'R[/s] <q>' 'R[/s] <r>' 'R[/s] <s>' 'C[/s] <a> <k>'
expect "input redirects dropped" 'a <in <<<"h" k' 'C[/s] <a> <k>'
expect "heredoc body skipped" $'cat <<EOF\n> not a cmd\nEOF\nafter' 'C[/s] <cat>' 'C[/s] <after>'
expect "heredoc with tab strip and quoted delimiter" $'cat <<-"EOT"\n\tbody > x\n\tEOT\nafter' 'C[/s] <cat>' 'C[/s] <after>'

# the tracked folder
expect "cd absolute" 'cd /x/y; a' 'C[/x/y] <a>'
expect "cd relative and .." 'cd /x; cd y; cd ../z; a' 'C[/x/z] <a>'
expect "cd with no argument is home" 'cd; a' "C[$HR] <a>"
expect "cd ~/dir" 'cd ~/t; a' "C[$HR/t] <a>"
expect "cd \$HOME/dir" 'cd $HOME/u; a' "C[$HR/u] <a>"
expect "cd option skipped" 'cd -P /x; a' 'C[/x] <a>'
expect "cd to a variable: folder unknown" 'cd "$V"; a; cd /q; b' 'C[] <a>' 'C[/q] <b>'
expect "cd to a glob: folder unknown" 'cd /x/*; a' 'C[] <a>'
expect "cd - and ~user: folder unknown" 'cd /q; cd -; a; cd ~root; b' 'C[] <a>' 'C[] <b>'
expect "pushd and popd" 'pushd /y; a; popd; b' 'C[/y] <a>' 'C[] <b>'
expect "cd is not passed on" 'cd /x' ''
expect "subshell scopes cd" 'cd /x; a; (cd /z; b); c' 'C[/x] <a>' 'C[/z] <b>' 'C[/x] <c>'
expect "\$( ) and backticks scope cd" 'cd /x; echo $(cd /w; d); e `cd /v; f`; g' 'C[/w] <d>' 'C[/x] <echo> <$(..)>' 'C[/v] <f>' 'C[/x] <e> <$(..)>' 'C[/x] <g>'
expect "braces do not scope cd" '{ cd /q; a; }; b' 'C[/q] <a>' 'C[/q] <b>'

# the words of the command around a substitution stay with it (they used to become commands of their own). $(...) stands
# for a quoted substitution, $(..) for an unquoted one, which the shell may split into several words.
expect "operand after a substitution" 'cp "$(mk)" /p/f' 'C[/s] <mk>' 'C[/s] <cp> <$(...)> </p/f>'
expect "operand after backticks (unquoted)" 'cp `mk` /p/f' 'C[/s] <mk>' 'C[/s] <cp> <$(..)> </p/f>'
expect "substitution in the middle of the operands" 'cp -a /src "$(mk)/sub" /p/f' 'C[/s] <mk>' 'C[/s] <cp> <-a> </src> <$(...)/sub> </p/f>'
expect "substitution glued to text" 'echo pre$(mk)post "a$(mk)b"' 'C[/s] <mk>' 'C[/s] <mk>' 'C[/s] <echo> <pre$(..)post> <a$(...)b>'
expect "nested substitutions" 'a "$(b "$(c)" d)" e' 'C[/s] <c>' 'C[/s] <b> <$(...)> <d>' 'C[/s] <a> <$(...)> <e>'
expect "substitution then a redirect target" 'a > "$(mk)/f" b' 'C[/s] <mk>' 'R[/s] <$(...)/f>' 'C[/s] <a> <b>'
expect "a redirect before the substitution survives it" 'a >f "$(mk)" b' 'R[/s] <f>' 'C[/s] <mk>' 'C[/s] <a> <$(...)> <b>'
expect "process substitution keeps the words around it" 'cp <(mk) /p/f' 'C[/s] <mk>' 'C[/s] <cp> <$(...)> </p/f>'
expect ">( ) keeps the words around it" 'x | tee >(mk) /p/f' 'C[/s] <x>' 'C[/s] <mk>' 'C[/s] <tee> <$(...)> </p/f>'
expect "a substitution in an assignment" 'x=$(mk) cp a /p/f' 'C[/s] <mk>' 'C[/s] <cp> <a> </p/f>'
expect "folder tracked through a substitution" 'cd /x; a "$(cd /y; mk)" b; c' 'C[/y] <mk>' 'C[/x] <a> <$(...)> <b>' 'C[/x] <c>'
expect "an arithmetic expansion is a word too" 'cp $((1+2)) /p/f' 'C[/s] <1+2>' 'C[/s] <cp> <$(..)> </p/f>'
expect "a subshell in front of a command is unchanged" '(a; b) c' 'C[/s] <a>' 'C[/s] <b>' 'C[/s] <c>'
expect "an unquoted substitution as the verb: what follows may be the command" '$(:) rm -rf /p' 'C[/s] <:>' 'C[/s] <rm> <-rf> </p>' 'C[/s] <$(..)> <rm> <-rf> </p>'
expect "the same behind env" 'env $(mk) rm /p' 'C[/s] <mk>' 'C[/s] <rm> </p>' 'C[/s] <$(..)> <rm> </p>'
expect "a quoted substitution as the verb is one command name" '"$(mk)" rm /p' 'C[/s] <mk>' 'C[/s] <$(...)> <rm> </p>'
expect "a shell keeps its heredoc across a substitution" $'bash -s "$(mk)" <<EOF\na > f\nEOF' 'C[/s] <mk>' 'R[/s] <f>' 'C[/s] <a>' 'C[/s] <bash> <-s> <$(...)>'
expect "a substitution that is the whole -c string is not read again" 'bash -c "$(mk)"' 'C[/s] <mk>' 'C[/s] <bash> <-c> <$(...)>'
# a hook that runs under set -u parses a group whose parked words are empty
PARSE_SET_U=1 expect "groups under set -u" '(a; b) c; echo "$(mk)" x; cp $(mk) y' 'C[/s] <a>' 'C[/s] <b>' 'C[/s] <c>' 'C[/s] <mk>' 'C[/s] <echo> <$(...)> <x>' 'C[/s] <mk>' 'C[/s] <cp> <$(..)> <y>'
expect "a group the text leaves open gives back the words parked in front of it" 'cp x $(mk' 'C[/s] <mk>' 'C[/s] <cp> <x>'

# a heredoc piped to a shell on the same line reaches that shell
expect "heredoc piped to a shell" $'cat <<EOF | bash\nrm /x\nEOF' 'C[/s] <cat>' 'C[/s] <rm> </x>' 'C[/s] <bash>'
expect "heredoc piped to a non-shell is skipped" $'cat <<EOF | wc\nrm /x\nEOF' 'C[/s] <cat>' 'C[/s] <wc>'
SP_ALL_HEREDOCS=1 expect "opt-in: every heredoc body is a script" $'ssh h <<EOF\nrm /x\nEOF' 'C[/s] <ssh> <h>' 'C[/s] <rm> </x>'
SP_ALL_HEREDOCS=1 expect "opt-in: a refused line drops only itself" $'ssh h <<EOF\necho done (in that case)\nrm /x\nEOF' 'C[/s] <ssh> <h>' 'C[/s] <rm> </x>'
SP_ALL_HEREDOCS=1 expect "opt-in: a body of one refused line is skipped" $'cat <<EOF\nskip it (in that case).\nEOF' 'C[/s] <cat>'
expect "a body does not reach a shell after &&" $'cat <<EOF > f && bash run.sh\nrm /x\nEOF' 'R[/s] <f>' 'C[/s] <cat>' 'C[/s] <bash> <run.sh>'
expect "a body does not reach a shell after ;" $'cat <<EOF > f ; bash run.sh\nrm /x\nEOF' 'R[/s] <f>' 'C[/s] <cat>' 'C[/s] <bash> <run.sh>'
expect "a body does not reach a shell after ||" $'cat <<EOF > f || bash run.sh\nrm /x\nEOF' 'R[/s] <f>' 'C[/s] <cat>' 'C[/s] <bash> <run.sh>'
expect "without the opt-in a body for a non-shell is skipped" $'ssh h <<EOF\nrm /x\nEOF' 'C[/s] <ssh> <h>'
# a group ends exactly at its ): a case pattern (whose ) ends nothing) or a ) inside ${x/)/} in a substitution is refused
refuse "case in a substitution" 'echo $(case x in x) rm /p;; esac) y'
refuse "case in a substitution, glued to the verb" 'echo$(case x in x) rm /p;; esac)'
refuse "case in a process substitution, glued" 'cat<(case x in x) rm /p;; esac)'
refuse "case in an output process substitution" 'x>(case x in x) rm /p;; esac)'
refuse "case in a quoted substitution" 'echo "$(case x in x) rm /p;; esac)"'
refuse "case in backticks" 'echo `case x in x) rm /p;; esac`'
refuse "a quoted case in a substitution" 'echo $("case" x in x) rm /p;; esac)'
refuse "case behind time in a substitution" 'echo $(time case x in x) rm /p;; esac)'
refuse "case in a substitution inside a subshell" '(echo $(case x in x) rm /p;; esac); cd /n)'
refuse "case as an argument in a substitution" 'echo $(echo case; a) b'
refuse "a ) inside \${x/)/} in a substitution" 'echo $(echo ${x/)/} rm /p)'
refuse "case in a plain subshell pops the folder" 'cd /t; (cd /x; case x in x) rm p;; esac)'
refuse "case in a subshell inside a function body" 'f() { (case x in x) a;; esac); }'
refuse "a space before the ) inside \${ }" 'cd /t; (cd /x; echo $(echo ${x:-a )}); rm p)'
refuse "a ( inside \${ }" 'rm$(echo ${x#(}) -rf /p'
refuse "an escaped backtick inside backticks" 'echo `echo \`case x in x) rm /p;; esac\``'
refuse "a heredoc ended by EOF) inside a substitution" $'echo $(cat <<EOF\nx\nEOF) ; rm /p'
refuse "case behind bash -c in a substitution" 'bash -c '"'"'echo $(case x in x) rm /p;; esac)'"'"
expect "case in a function body outside any group" 'f() { case x in x) a;; esac; }' 'C[/s] <f>' 'C[/s] <case> <x> <in> <x>' 'C[/s] <a>' 'C[/s] <esac>'
expect "a plain subshell" '(cd /n; a); b' 'C[/n] <a>' 'C[/s] <b>'
expect "parameter expansions keep their braces" 'echo ${x:-$(date)} ${y#a} ${#arr[@]} z' 'C[/s] <date>' 'C[/s] <echo> <${x:-$(..)}> <${y#a}> <${#arr[@]}> <z>'
expect "a heredoc in a substitution reads normally" $'echo $(cat <<EOF\nx)\nEOF\n) a' 'C[/s] <cat>' 'C[/s] <echo> <$(..)> <a>'
refuse "nested quotes inside \${ } inside a string" 'echo $(eval "${x:+")"}" rm /p)'
refuse "a comment inside backticks" 'echo `#` ; rm /p'
refuse "a heredoc inside backticks" $'echo `cat <<X`\nrm /p'
refuse "a backtick inside a substitution inside backticks" 'rm `: $(` /p'
expect "a substitution glued before the verb" '$(a)rm /p' 'C[/s] <a>' 'C[/s] <rm> </p>' 'C[/s] <$(..)rm> </p>'
expect "backticks glued before the verb" '`a`rm /p' 'C[/s] <a>' 'C[/s] <rm> </p>' 'C[/s] <$(..)rm> </p>'
expect "a quoted substitution glued before the verb" '"$(a)"rm /p' 'C[/s] <a>' 'C[/s] <rm> </p>' 'C[/s] <$(...)rm> </p>'
expect "text glued before a substitution in the verb" 'rm$(a) /p' 'C[/s] <a>' 'C[/s] <rm> </p>' 'C[/s] <rm$(..)> </p>'
expect "a quoted substitution that is the whole verb stays a word" '"$(a)" rm /p' 'C[/s] <a>' 'C[/s] <$(...)> <rm> </p>'
expect "case outside a substitution is plain words" 'case x in x) rm /p;; esac' 'C[/s] <case> <x> <in> <x>' 'C[/s] <rm> </p>' 'C[/s] <esac>'
expect "case inside a bash -c string is read" 'bash -c "case x in x) rm /p;; esac"' 'C[/s] <case> <x> <in> <x>' 'C[/s] <rm> </p>' 'C[/s] <esac>' 'C[/s] <bash> <-c> <case x in x) rm /p;; esac>'
expect "a plain substitution with parameter expansion reads normally" 'echo $(echo ${x:-a} b) c' 'C[/s] <echo> <${x:-a}> <b>' 'C[/s] <echo> <$(..)> <c>'
expect "the word case in a plain string is not a case" 'echo "case x" $(a)' 'C[/s] <a>' 'C[/s] <echo> <case x> <$(..)>'
# nested strings
expect "bash -c" 'bash -c "cd /n; a > f"; b' 'R[/n] <f>' 'C[/n] <a>' 'C[/s] <bash> <-c> <cd /n; a > f>' 'C[/s] <b>'
# wrapper edges
expect "time --" 'time -- rm /x' 'C[/s] <rm> </x>'
expect "sudo -T" 'sudo -T 5 rm /x' 'C[/s] <rm> </x>'
expect "eval --" 'eval -- "rm /x"' 'C[/s] <rm> </x>' 'C[/s] <eval> <--> <rm /x>'
# options between -c and its string are not the string
expect "bash -c --" 'bash -c -- "rm /x"' 'C[/s] <rm> </x>' 'C[/s] <bash> <-c> <--> <rm /x>'
expect "bash -c -x" 'bash -c -x "rm /x"' 'C[/s] <rm> </x>' 'C[/s] <bash> <-c> <-x> <rm /x>'
expect "sh -c -e" 'sh -c -e "rm /x"' 'C[/s] <rm> </x>' 'C[/s] <sh> <-c> <-e> <rm /x>'
expect "bash -c -o pipefail" 'bash -c -o pipefail "rm /x"' 'C[/s] <rm> </x>' 'C[/s] <bash> <-c> <-o> <pipefail> <rm /x>'
expect "bash -O extglob -c" 'bash -O extglob -c "rm /x"' 'C[/s] <rm> </x>' 'C[/s] <bash> <-O> <extglob> <-c> <rm /x>'
expect "sh -ec and bash -lc" "sh -ec \"a\"; bash -lc 'b'" 'C[/s] <a>' 'C[/s] <sh> <-ec> <a>' 'C[/s] <b>' 'C[/s] <bash> <-lc> <b>'
expect "eval" 'eval "x; y > z" w' 'C[/s] <x>' 'R[/s] <z>' 'C[/s] <y> <w>' 'C[/s] <eval> <x; y > z> <w>'
expect "three levels are read, the fourth is not" 'bash -c "bash -c \"bash -c \\\"bash -c a\\\"\""' \
  'C[/s] <bash> <-c> <a>' 'C[/s] <bash> <-c> <bash -c a>' 'C[/s] <bash> <-c> <bash -c "bash -c a">' 'C[/s] <bash> <-c> <bash -c "bash -c \"bash -c a\"">'

expect "eval runs in the current shell: its cd stays" 'eval "cd /n"; a' 'C[/n] <eval> <cd /n>' 'C[/n] <a>'

# sp_command: the runner's on_command hands the words behind xargs to it
expect "xargs: wrappers skipped" 'xargs env FOO=1 rm x' 'C[/s] <xargs> <env> <FOO=1> <rm> <x>' 'C[/s] <rm> <x>'
expect "xargs cd moves the folder" 'xargs cd /x; a' 'C[/s] <xargs> <cd> </x>' 'C[/x] <a>'
expect "xargs bash -c is read" 'xargs bash -c "a > f"' 'C[/s] <xargs> <bash> <-c> <a > f>' 'R[/s] <f>' 'C[/s] <a>' 'C[/s] <bash> <-c> <a > f>'
expect "xargs options skipped" 'xargs -0 -r -n 1 rm x' 'C[/s] <xargs> <-0> <-r> <-n> <1> <rm> <x>' 'C[/s] <rm> <x>'
expect "xargs option values skipped (BSD -J, GNU long)" 'xargs -J % --max-args 2 rm %' 'C[/s] <xargs> <-J> <%> <--max-args> <2> <rm> <%>' 'C[/s] <rm> <%>'
expect "doas, caffeinate and their option values skipped" 'doas -u me caffeinate -i -t 5 rm x' 'C[/s] <rm> <x>'
expect "su -c is a nested string" "su -c 'a > f' me" 'R[/s] <f>' 'C[/s] <a>' 'C[/s] <su> <-c> <a > f> <me>'
expect "su --command forms" "su --command='a' me; su me --command 'b'; su --co 'c'" 'C[/s] <a>' 'C[/s] <su> <--command=a> <me>' 'C[/s] <b>' 'C[/s] <su> <me> <--command> <b>' 'C[/s] <c>' 'C[/s] <su> <--co> <c>'
# env -S splits its string and appends the words after it: one command line, read once
expect "env -S is a nested string" 'env -S "a" x; env -Sb\ y; env --split-string="c"; env -i -S "FOO=1 d"' 'C[/s] <a> <x>' 'C[/s] <b> <y>' 'C[/s] <c>' 'C[/s] <d>'
expect "env -S joins the words after the string" "env -S 'a b' c d; env -Sa b; env --split-string='a b' c" 'C[/s] <a> <b> <c> <d>' 'C[/s] <a> <b>' 'C[/s] <a> <b> <c>'

# a shell with no -c string reads the heredoc or here-string it is given
expect "bash <<EOF is read" $'bash <<EOF\na > f\nEOF\nb' 'R[/s] <f>' 'C[/s] <a>' 'C[/s] <bash>' 'C[/s] <b>'
expect "sh -s <<'X' is read" $'sh -s <<\'X\'\na\nX' 'C[/s] <a>' 'C[/s] <sh> <-s>'
expect "bash <<< string is read" 'bash <<< "a; b"' 'C[/s] <a>' 'C[/s] <b>' 'C[/s] <bash>'
expect "heredoc then a pipe: the shell is the one it feeds" $'bash <<EOF | cat\na\nEOF\nb' 'C[/s] <a>' 'C[/s] <bash>' 'C[/s] <cat>' 'C[/s] <b>'
expect "a -c string wins over a heredoc" $'bash -c "a" <<EOF\nb\nEOF' 'C[/s] <a>' 'C[/s] <bash> <-c> <a>'
expect "a heredoc fed to cat is not read" $'cat <<EOF\na\nEOF' 'C[/s] <cat>'

# size: a long heredoc to cat and a long script must not make the parser slow (a locale-dependent [A-Z] once forked per word)
big=$(awk 'BEGIN { print "cat > f <<EOF"; for (k = 0; k < 1500; k++) print "line " k " xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; print "EOF"; for (k = 0; k < 150; k++) print "echo " k }')
t0=$SECONDS
out=$("$SH" "$T/run.sh" "$big" 2>&1 | wc -l)
check "a 75 KB heredoc and 150 commands parse in under 10 s ($((SECONDS - t0)) s)" "$([ "$((SECONDS - t0))" -lt 10 ] && [ "$out" -eq 152 ] && echo 1 || echo 0)"

# many parses in one function: bash 3.2 leaks a file descriptor per `done < <(cmd)` and crashed after about 250 (exit 133, a hook that fails open).
# Only bash 3.2 crashes; on another shell this still checks that every parse ran.
cat >"$T/loop.sh" <<LOOP
HOOK=runner
HOME="$T/home"
. "$T/hooks/lib/hook-common.sh" </dev/null
. "$T/hooks/lib/shell-parse.sh"
N=0
on_command() { N=\$((N + 1)); }
on_redirect() { :; }
CWD=/s
g() { local i; for ((i = 0; i < 400; i++)); do shell_parse "echo \$i"; done; echo "done \$N"; }
g
LOOP
out=$("$SH" "$T/loop.sh" 2>&1)
check "400 parses in one function do not crash bash 3.2 (got: $(printf '%s' "$out" | head -c 40))" "$([ "$out" = "done 400" ] && echo 1 || echo 0)"

# the clock budget: a parse that has run for 6 s is denied (a hook past its 10 s timeout lets the call through)
got=$(PARSE_STALE=1 "$SH" "$T/run.sh" 'echo a' 2>&1)
case "$got" in *'takes too long'*) check "a parse past the clock budget is denied" 1 ;; *) check "a parse past the clock budget is denied (got: $got)" 0 ;; esac
got=$("$SH" "$T/run.sh" 'echo a' 2>&1)
check "a fresh parse is not" "$([ "$got" = 'C[/s] <echo> <a>' ] && echo 1 || echo 0)"

# refusals
for c in $'a\001b' $'a\033b' $'a\177b'; do
  out=$("$SH" "$T/run.sh" "$c" 2>&1)
  check "control byte denied ($(printf '%s' "$c" | od -An -c | tr -d ' '))" "$([ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = deny ] && echo 1 || echo 0)"
done
out=$(sed 's/^on_redirect.*//' "$T/run.sh" >"$T/norun.sh"; "$SH" "$T/norun.sh" 'a' 2>&1)
check "a hook without on_redirect is denied" "$([ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = deny ] && echo 1 || echo 0)"
out=$("$SH" "$T/run.sh" $'a\tb\nc' 2>&1)
check "tab and newline are not refused" "$([ "$(printf '%s\n' "$out" | head -1)" = 'C[/s] <a> <b>' ] && echo 1 || echo 0)"

# fail-closed: sourcing succeeds on an empty or cut-short file, so each lib ends by setting a marker and the guard's
# source line checks it. A guard with a lib file missing, empty or cut short (its last line dropped) exits 1, which the
# `|| exit 2` wiring blocks, for a Bash, an Edit and a git MCP call alike.
GIN='{"tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/tmp"}'
EIN='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x"},"cwd":"/tmp"}'
MIN='{"tool_name":"mcp__git-mcp__git_add","tool_input":{"path":"/tmp/x"},"cwd":"/tmp"}'
rc_of() {  # rc_of <hook file> <input>: the hook's exit code
  printf '%s' "$2" | HOME="$T/home" "$SH" "$1" >/dev/null 2>&1
  echo $?
}
damage() {  # damage <lib name> <ok|missing|empty|cut>: lay out $T/part with that lib file in that state
  rm -r "$T/part" 2>/dev/null
  mkdir -p "$T/part/lib"
  cp "$GUARD" "${GUARD%/*}/destructive-blocker.sh" "${GUARD%/*}/secret-detector.sh" "${GUARD%/*}/git-mcp-guard.sh" "$T/part/"
  cp "$T/hooks/lib/hook-common.sh" "$T/hooks/lib/shell-parse.sh" "$T/part/lib/"
  case "$2" in
    missing) rm "$T/part/lib/$1.sh" ;;
    empty) : >"$T/part/lib/$1.sh" ;;
    cut) sed '$d' "$T/hooks/lib/$1.sh" >"$T/part/lib/$1.sh" ;;
  esac
}
damage shell-parse ok
check "guard with both lib files exits 0" "$([ "$(rc_of "$T/part/protected-paths-guard.sh" "$GIN")" = 0 ] && echo 1 || echo 0)"
for lib in hook-common shell-parse; do
  for state in missing empty cut; do
    damage $lib $state
    for in in "$GIN" "$EIN" "$MIN"; do
      check "guard with $state lib/$lib.sh exits 1 ($(printf '%s' "$in" | jq -r .tool_name))" "$([ "$(rc_of "$T/part/protected-paths-guard.sh" "$in")" = 1 ] && echo 1 || echo 0)"
    done
  done
done
damage hook-common ok
check "destructive-blocker with an intact lib exits 0" "$([ "$(rc_of "$T/part/destructive-blocker.sh" "$GIN")" = 0 ] && echo 1 || echo 0)"
check "secret-detector with an intact lib exits 0" "$([ "$(rc_of "$T/part/secret-detector.sh" "$GIN")" = 0 ] && echo 1 || echo 0)"
check "git-mcp-guard with an intact lib exits 0" "$([ "$(rc_of "$T/part/git-mcp-guard.sh" "$MIN")" = 0 ] && echo 1 || echo 0)"
for state in empty cut; do
  damage hook-common $state
  check "destructive-blocker with $state lib/hook-common.sh exits 1" "$([ "$(rc_of "$T/part/destructive-blocker.sh" "$GIN")" = 1 ] && echo 1 || echo 0)"
  check "secret-detector with $state lib/hook-common.sh exits 1" "$([ "$(rc_of "$T/part/secret-detector.sh" "$GIN")" = 1 ] && echo 1 || echo 0)"
  check "git-mcp-guard with $state lib/hook-common.sh exits 1" "$([ "$(rc_of "$T/part/git-mcp-guard.sh" "$MIN")" = 1 ] && echo 1 || echo 0)"
done

echo "shell-parse: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
