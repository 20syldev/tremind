#!/usr/bin/env bash
# Tests of tremind. No framework: plain bash, one sandbox per test.
#
#   tests/run.sh            run every test
#   tests/run.sh cancel     run the tests whose name contains "cancel"
#
# Nothing here touches the real session: systemctl and notify-send are fakes put first on PATH, and
# the state folder, the unit folder and HOME are inside a temporary folder. The fakes record what
# they were asked, and the tests read those records. The clock is fixed with TREMIND_NOW_EPOCH.
# A sandbox is removed file by file at the end (no recursive delete).
set -uo pipefail
shopt -u patsub_replacement 2>/dev/null || true

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TREMIND="$ROOT/tremind"
BASEPATH=/usr/bin:/bin
BASE_NOW=$(TZ=UTC date -d '2027-04-15 08:00:00' +%s)

pass=0
fail=0
current=""

# ---- Assertions ------------------------------------------------------------------------------

ok() { pass=$((pass + 1)); }
bad() {
    fail=$((fail + 1))
    printf 'FAIL %s: %s\n' "$current" "$1" >&2
    shift
    local line
    for line in "$@"; do printf '       %s\n' "$line" >&2; done
}
eq() { # eq NAME EXPECTED ACTUAL
    if [[ $2 == "$3" ]]; then ok; else bad "$1" "expected: $2" "     got: $3"; fi
}
match() { # match NAME REGEX TEXT
    if [[ $3 =~ $2 ]]; then ok; else bad "$1" "expected to match: $2" "            got: $3"; fi
}
has() { # has NAME NEEDLE TEXT
    if [[ $3 == *"$2"* ]]; then ok; else bad "$1" "expected to contain: $2" "            got: $3"; fi
}
hasnt() { # hasnt NAME NEEDLE TEXT
    if [[ $3 != *"$2"* ]]; then ok; else bad "$1" "expected NOT to contain: $2" "                got: $3"; fi
}
exists() { if [[ -e $2 ]]; then ok; else bad "$1" "missing: $2"; fi; }
absent() { if [[ ! -e $2 ]]; then ok; else bad "$1" "should not exist: $2"; fi; }

# ---- Sandbox ---------------------------------------------------------------------------------

S=""
NOW=$BASE_NOW
EXTRA=()
T_LANG=C.UTF-8
T_TZ=UTC
T_PATH=""
SCRIPT=$TREMIND
RC=0 OUT="" ERR="" ID=""

new_sandbox() {
    S=$(mktemp -d)
    mkdir -p "$S/bin" "$S/home" "$S/state" "$S/config"
    NOW=$BASE_NOW EXTRA=() T_LANG=C.UTF-8 T_TZ=UTC T_PATH="" SCRIPT=$TREMIND

    cat >"$S/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
dir=$(dirname "$0")/..
printf '%s\n' "$*" >>"$dir/systemctl.log"
if [[ -e $dir/no-systemd ]]; then
    echo "Failed to connect to bus: No medium found" >&2
    exit 1
fi
[[ $1 == --user ]] && shift
case $1 in
    is-active) [[ -e $dir/timer-active ]] ;;
    enable) : >"$dir/timer-active" ;;
    disable) rm -f "$dir/timer-active" ;;
    show-environment | daemon-reload | is-system-running) : ;;
    *) echo "fake systemctl: unexpected: $*" >&2; exit 1 ;;
esac
EOF
    cat >"$S/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
dir=$(dirname "$0")/..
[[ -e $dir/notify-fail ]] && exit 1
f="$dir/notify.$(date +%s%N)"
printf '%s\0' "$@" >"$f"
# A helper that outlives the call, as a notification daemon started on demand can.
[[ -e $dir/notify-linger ]] && { sleep 4 & }
exit 0
EOF
    chmod +x "$S/bin/systemctl" "$S/bin/notify-send"
}

# wipe_dir DIR: delete the files of DIR, then DIR itself if it is empty. Never recursive.
wipe_dir() {
    local d=$1
    [[ -d $d ]] || return 0
    rm -f -- "$d"/* "$d"/.[!.]* 2>/dev/null
    rmdir "$d" 2>/dev/null || printf 'note: left in place: %s\n' "$d" >&2
}

wipe_sandbox() {
    wipe_dir "$S/config/systemd/user"
    wipe_dir "$S/config/systemd"
    wipe_dir "$S/config"
    wipe_dir "$S/state/tremind"
    wipe_dir "$S/state"
    wipe_dir "$S/state2/tremind"
    wipe_dir "$S/state2"
    wipe_dir "$S/home/.local/state/tremind"
    wipe_dir "$S/home/.local/state"
    wipe_dir "$S/home/.local"
    wipe_dir "$S/home"
    wipe_dir "$S/odd"
    wipe_dir "$S/bin"
    wipe_dir "$S/rbin"
    wipe_dir "$S"
}

# run ARGS...: run tremind in the sandbox; set RC, OUT, ERR.
run() {
    local path=${T_PATH:-$S/bin:$BASEPATH}
    env -i PATH="$path" HOME="$S/home" XDG_STATE_HOME="$S/state" XDG_CONFIG_HOME="$S/config" \
        LANG="$T_LANG" TZ="$T_TZ" TREMIND_NOW_EPOCH="$NOW" ${EXTRA[@]+"${EXTRA[@]}"} \
        "$BASH" "$SCRIPT" "$@" >"$S/out" 2>"$S/err"
    RC=$?
    OUT=$(<"$S/out")
    ERR=$(<"$S/err")
}

# add ARGS...: run "add" and take the id of the new reminder.
add() {
    run add "$@"
    ID=$(sed -n 's/^Reminder \([^ ]*\) on .*/\1/p' <<<"$OUT")
}

state_file() { printf '%s/state/tremind/%s' "$S" "$1"; }
# body_of ID: the message of a reminder (the file is: due line, epoch line, blank line, message).
body_of() { sed '1,3d' "$(state_file "$1")"; }
epoch_of() { TZ=${2:-UTC} date -d "$1" +%s; }
# put_state ID DUE BODY: write a state file by hand (due in UTC).
put_state() { mkdir -p "$S/state/tremind"; printf 'due=%s\nepoch=%s\n\n%s\n' "$2" "$(epoch_of "$2")" "$3" >"$S/state/tremind/$1"; }
count_files() { local n=0 f; for f in "$S"/state/tremind/[0-9]*; do [[ -f $f ]] && n=$((n + 1)); done; printf '%d' "$n"; }
count_in() { local n=0 f; for f in "$1"/[0-9]*; do [[ -f $f ]] && n=$((n + 1)); done; printf '%d' "$n"; }
count_notify() { local n=0 f; for f in "$S"/notify.*; do [[ -f $f ]] && n=$((n + 1)); done; printf '%d' "$n"; }
# notify_args N: the arguments of the Nth notification, in ARGS.
notify_args() {
    local files=("$S"/notify.*)
    mapfile -d '' -t ARGS <"${files[$(($1 - 1))]}"
}
systemctl_calls() { grep -c -- "$1" "$S/systemctl.log" 2>/dev/null || true; }
# longstr N [CHAR]: CHAR (default x) repeated N times; CHAR may be a multi-byte character.
longstr() { local i out=""; for ((i = 0; i < $1; i++)); do out+=${2:-x}; done; printf '%s' "$out"; }

# ---- Tests: add ------------------------------------------------------------------------------

t_add_delay() {
    add -t 30m Buy milk
    eq "rc" 0 "$RC"
    match "output" '^Reminder [0-9]{10}-[a-z0-9]{3} on 2027-04-15 08:30$' "$OUT"
    eq "id starts with the due time" 2704150830- "${ID:0:11}"
    eq "due line" "due=2027-04-15 08:30" "$(sed -n 1p "$(state_file "$ID")")"
    eq "epoch line" "epoch=$(epoch_of '2027-04-15 08:30')" "$(sed -n 2p "$(state_file "$ID")")"
    eq "blank line" "" "$(sed -n 3p "$(state_file "$ID")")"
    eq "message" "Buy milk" "$(body_of "$ID")"
    eq "state file mode" 600 "$(stat -c %a "$(state_file "$ID")")"
    eq "state folder mode" 700 "$(stat -c %a "$S/state/tremind")"
}

t_add_rounds_up_to_the_next_minute() {
    NOW=$((BASE_NOW + 20))
    add -t 30m x
    has "08:31" "on 2027-04-15 08:31" "$OUT"
}

t_add_delay_forms() {
    local form want
    for form in "1h30m=2027-04-15 09:30" "4d=2027-04-19 08:00" "1w=2027-04-22 08:00" "2d3h=2027-04-17 11:00" "90m=2027-04-15 09:30" "1m=2027-04-15 08:01"; do
        add --at "${form%%=*}" x
        eq "rc ${form%%=*}" 0 "$RC"
        has "due ${form%%=*}" "on ${form#*=}" "$OUT"
    done
}

t_add_exact_time() {
    add --at "2027-04-15 09:30" x
    has "--at VALUE" "on 2027-04-15 09:30" "$OUT"
    add --at="2027-12-24 18:00" x
    has "--at=VALUE" "on 2027-12-24 18:00" "$OUT"
    add --at "2027-04-15 08:00" x
    eq "the current minute is accepted" 0 "$RC"
    add --at "2027-04-15 07:59" x
    eq "the minute before is refused" 1 "$RC"
}

t_add_refuses_bad_times() {
    local bad
    for bad in 30s 0m abc 5 "2027-4-5 9:00" "2027-02-30 10:00" "2027-13-01 10:00" "2027-04-14 10:00" 3651d "2037-04-16 08:00" "1h 30m" "2027-04-15T09:30" '$(id)'; do
        add --at "$bad" x
        eq "rc for [$bad]" 1 "$RC"
        match "message for [$bad]" 'tremind: .+' "$ERR"
    done
    eq "nothing was stored" 0 "$(count_files)"
}

t_add_refuses_a_time_that_does_not_exist() {
    [[ -e /usr/share/zoneinfo/Europe/Paris ]] || { echo "skip: no tzdata" >&2; return 0; }
    NOW=$(TZ=UTC date -d '2027-03-01 12:00:00' +%s)
    T_TZ=Europe/Paris
    add --at "2027-03-28 02:30" x
    eq "rc (spring forward gap)" 1 "$RC"
    has "message" "not a valid time" "$ERR"
    add --at "2027-03-28 03:30" x
    eq "rc (after the gap)" 0 "$RC"
}

t_add_usage_errors() {
    local args
    run
    eq "no command" 2 "$RC"
    run bogus
    eq "unknown command" 2 "$RC"
    for args in "add" "add -t 1h" "add --at" "add -t" "add -t 1h -x hello" "add -t 1h --body a b" "add -t 1h --body" "add -t 1h --line" "cancel" "cancel a b" "cancel --all x" "cancel --"; do
        # shellcheck disable=SC2086
        run $args
        eq "rc for [$args]" 2 "$RC"
    done
    run add -t 1h -x hello
    has "unknown option is named" "unknown option: -x" "$ERR"
    run add --at "" x
    eq "empty --at" 2 "$RC"
    run -V
    eq "-V" 0 "$RC"
    run -h
    eq "-h" 0 "$RC"
    run help
    eq "help" 0 "$RC"
    run ls
    eq "ls is list" 0 "$RC"
    run add -t 1h --line ""
    eq "only an empty line" 2 "$RC"
}

t_add_words_and_dash() {
    add -t 1h Buy some milk
    eq "words are joined" "Buy some milk" "$(body_of "$ID")"
    add -t 1h -- -starts with a dash
    eq "text after --" "-starts with a dash" "$(body_of "$ID")"
    add --at 1h --body "-b"
    eq "dash body" "-b" "$(body_of "$ID")"
}

t_add_multiline_body() {
    add -t 1h --body $'first\nsecond\n\nthird'
    eq "rc" 0 "$RC"
    eq "lines kept" $'first\nsecond\n\nthird' "$(body_of "$ID")"
    add -t 1h --body $'one\r\ntwo\r\n'
    eq "CRLF becomes LF" $'one\ntwo' "$(body_of "$ID")"
    add -t 1h --body $'\n\n  padded  \n\n'
    eq "blank ends are trimmed" "  padded  " "$(body_of "$ID")"
}

t_add_lines() {
    add -t 1h --line "Call Alex" --line "Send the invoice"
    eq "two lines get dashes" $'- Call Alex\n- Send the invoice' "$(body_of "$ID")"
    add -t 1h --line "Call Alex"
    eq "one line stays plain" "Call Alex" "$(body_of "$ID")"
    add -t 1h --line "" --line "Only one" --line ""
    eq "empty lines are dropped before counting" "Only one" "$(body_of "$ID")"
    add -t 1h --body "Shopping" --line milk --line eggs
    eq "body then list" $'Shopping\n- milk\n- eggs' "$(body_of "$ID")"
    add -t 1h --line=a --line b --line=c
    eq "both spellings" $'- a\n- b\n- c' "$(body_of "$ID")"
    run add -t 1h --line $'two\nlines'
    eq "a line with LF" 2 "$RC"
}

t_add_hostile_text_is_inert() {
    local text='$(touch '"$S"'/pwned) `touch '"$S"'/pwned2`; touch '"$S"'/pwned3 "quoted" '"'"'single'"'"' \n %s <b>x</b> &amp;'
    add -t 1h --body "$text"
    eq "rc" 0 "$RC"
    eq "stored as typed" "$text" "$(body_of "$ID")"
    NOW=$((BASE_NOW + 7200))
    run tick
    eq "tick rc" 0 "$RC"
    absent "no command ran (1)" "$S/pwned"
    absent "no command ran (2)" "$S/pwned2"
    absent "no command ran (3)" "$S/pwned3"
    notify_args 1
    eq "the body is one argument" 11 "${#ARGS[@]}"
    local want=${text//\\/\\\\}
    want=${want//&/&amp;}
    want=${want//</&lt;}
    want=${want//>/&gt;}
    eq "backslashes doubled, markup escaped, nothing else" "$want" "${ARGS[10]}"
}

t_add_body_limits() {
    add -t 1h --body "$(longstr 1000)"
    eq "1000 bytes" 0 "$RC"
    add -t 1h --body "$(longstr 1001)"
    eq "1001 bytes" 1 "$RC"
    has "message" "1000 bytes" "$ERR"
    add -t 1h --body "$(longstr 500 é)"
    eq "500 accents = 1000 bytes" 0 "$RC"
    add -t 1h --body "$(longstr 501 é)"
    eq "501 accents = 1002 bytes" 1 "$RC"
    add -t 1h --body "$(printf 'l%s\n' {1..16})"
    eq "16 lines" 0 "$RC"
    add -t 1h --body "$(printf 'l%s\n' {1..17})"
    eq "17 lines" 1 "$RC"
    has "message" "16 lines" "$ERR"
}

t_add_refuses_bad_characters() {
    local name text
    local -A cases=(
        [tab]=$'a\tb' [escape]=$'a\x1b[31mb' [bell]=$'a\ab' [carriage return]=$'a\rb' [delete]=$'a\x7fb'
        [bidi override]=$'a\xe2\x80\xaeb' [bidi isolate]=$'a\xe2\x81\xa6b' [zero width]=$'a\xe2\x80\x8bb'
        [byte order mark]=$'a\xef\xbb\xbfb' [invalid utf8]=$'a\xffb' [spaces only]='   '
    )
    for name in "${!cases[@]}"; do
        text=${cases[$name]}
        add -t 1h --body "$text"
        eq "refused: $name" 1 "$RC"
    done
    eq "nothing was stored" 0 "$(count_files)"
    add -t 1h --body "Réunion à 14h — café ☕ 日本語 🚀"
    eq "accents, dashes, CJK and emoji are fine" 0 "$RC"
}

# ---- Tests: list, ids, presets ---------------------------------------------------------------

t_list_empty() {
    run list
    eq "rc" 0 "$RC"
    eq "text" "No pending reminder." "$OUT"
    run ids
    eq "ids rc" 0 "$RC"
    eq "ids empty" "" "$OUT"
}

t_list_sorted_and_shortened() {
    add --at "2027-06-01 10:00" "Later one"
    add --at "2027-04-16 10:00" --body $'Soon one\nsecond line\nthird line'
    add --at "2027-05-01 10:00" "$(longstr 80 y)"
    run list
    eq "rc" 0 "$RC"
    match "header" '^ID +WHEN +MESSAGE' "$OUT"
    local rows
    rows=$(sed -n '2,$p' <<<"$OUT")
    match "soonest first" '^2704161000-[a-z0-9]{3} +2027-04-16 10:00 +Soon one  \[\+2 lines\]' "$(sed -n 1p <<<"$rows")"
    match "then" '^2705011000-[a-z0-9]{3} +2027-05-01 10:00 +y{59}…$' "$(sed -n 2p <<<"$rows")"
    match "last" '^2706011000-[a-z0-9]{3} +2027-06-01 10:00 +Later one$' "$(sed -n 3p <<<"$rows")"
    run ids
    eq "ids count" 3 "$(wc -l <<<"$OUT")"
    match "ids shape" '^[0-9]{10}-[a-z0-9]{3}$' "$(sed -n 1p <<<"$OUT")"
}

t_list_skips_foreign_files() {
    add -t 1h x
    : >"$S/state/tremind/notes.txt"
    : >"$S/state/tremind/.new.abc"
    run ids
    eq "only the reminder" "$ID" "$OUT"
}

t_presets() {
    run presets
    eq "rc" 0 "$RC"
    has "30m" $'\n30m\n' $'\n'"$OUT"$'\n'
    eq "tomorrow morning" "2027-04-16 09:00" "$(sed -n '/^2027/p' <<<"$OUT" | sed -n 1p)"
    eq "tomorrow evening" "2027-04-16 18:00" "$(sed -n '/^2027/p' <<<"$OUT" | sed -n 2p)"
    local line n=0
    while IFS= read -r line; do
        add --at "$line" x
        eq "preset [$line] is accepted" 0 "$RC"
        n=$((n + 1))
    done <<<"$OUT"
    eq "number of presets" 11 "$n"
}

# ---- Tests: cancel ---------------------------------------------------------------------------

t_cancel_one() {
    add -t 1h one
    local first=$ID
    add -t 2h two
    run cancel "$first"
    eq "rc" 0 "$RC"
    has "message" "cancelled" "$OUT"
    absent "removed" "$(state_file "$first")"
    exists "the other stays" "$(state_file "$ID")"
    eq "timer still on" 0 "$(systemctl_calls 'disable')"
    run cancel -- "$ID"
    eq "-- form" 0 "$RC"
    eq "timer disabled with the last reminder" 1 "$(systemctl_calls 'disable --now tremind.timer')"
}

t_cancel_refuses() {
    add -t 1h x
    run cancel 2704150900-zzz
    eq "unknown id" 1 "$RC"
    has "message" "no such reminder" "$ERR"
    local bad
    printf 'x' >"$S/state/victim"
    for bad in ../x ../victim ../../etc/passwd "$ID/../$ID" "2704150900" "2704150900-ABC" "27041509000-abc" "2704150900-abc/" " 2704150900-abc" '$(id)' "*" ""; do
        run cancel "$bad"
        eq "rc for [$bad]" 1 "$RC"
        has "message for [$bad]" "not a reminder id" "$ERR"
    done
    exists "outside file untouched" "$S/state/victim"
    rm -f -- "$S/state/victim"
    exists "the reminder is intact" "$(state_file "$ID")"
}

t_cancel_all() {
    add -t 1h a
    add -t 2h b
    add -t 3h c
    run cancel --all
    eq "rc" 0 "$RC"
    eq "all gone" 0 "$(count_files)"
    eq "timer disabled" 1 "$(systemctl_calls 'disable --now tremind.timer')"
}

# ---- Tests: tick -----------------------------------------------------------------------------

t_tick_fires_what_is_due() {
    add -t 30m "First"
    add -t 2h "Second"
    NOW=$((BASE_NOW + 1800))
    run tick
    eq "rc" 0 "$RC"
    eq "one notification" 1 "$(count_notify)"
    notify_args 1
    eq "arguments" "-u|normal|-t|0|-i|appointment-soon|-a|tremind|--|Reminder|First" "$(IFS='|'; printf '%s' "${ARGS[*]}")"
    eq "one left" 1 "$(count_files)"
    eq "the timer stays on" 0 "$(systemctl_calls 'disable')"
}

t_tick_before_the_time_does_nothing() {
    add -t 30m "Not yet"
    NOW=$((BASE_NOW + 1799))
    run tick
    eq "rc" 0 "$RC"
    eq "no notification" 0 "$(count_notify)"
    eq "still there" 1 "$(count_files)"
}

t_tick_fires_an_overdue_reminder_once() {
    add -t 30m "Late"
    NOW=$((BASE_NOW + 86400 * 30))
    run tick
    eq "first tick" 1 "$(count_notify)"
    run tick
    run tick
    eq "no repeat" 1 "$(count_notify)"
    eq "gone" 0 "$(count_files)"
}

t_tick_disarms_when_idle() {
    run tick
    eq "rc" 0 "$RC"
    eq "empty folder: timer disabled" 1 "$(systemctl_calls 'disable --now tremind.timer')"
    add -t 1h x
    : >"$S/systemctl.log"
    run tick
    eq "pending reminder: timer kept" 0 "$(systemctl_calls 'disable')"
    NOW=$((BASE_NOW + 3600))
    run tick
    eq "last one fired: timer disabled" 1 "$(systemctl_calls 'disable --now tremind.timer')"
    add -t 1h again
    eq "add arms the timer again" 1 "$([[ -e $S/timer-active ]] && echo 1 || echo 0)"
}

t_tick_title_and_language() {
    add -t 1m x
    NOW=$((BASE_NOW + 3600))
    T_LANG=fr_FR.UTF-8
    run tick
    notify_args 1
    eq "French locale" Rappel "${ARGS[9]}"
    add -t 1m x
    T_LANG=C.UTF-8
    EXTRA=(TREMIND_TITLE="My <title> & more")
    NOW=$((BASE_NOW + 7200))
    run tick
    notify_args 2
    eq "TREMIND_TITLE, plain text" "My <title> & more" "${ARGS[9]}"
}

t_tick_escapes_markup() {
    add -t 1m --body '<b>bold</b> & "q" -x'
    NOW=$((BASE_NOW + 3600))
    run tick
    notify_args 1
    eq "escaped" '&lt;b&gt;bold&lt;/b&gt; &amp; "q" -x' "${ARGS[10]}"
    eq "after --" "--" "${ARGS[8]}"
}

t_tick_keeps_a_reminder_when_the_notification_fails() {
    add -t 1m "Keep me"
    : >"$S/notify-fail"
    NOW=$((BASE_NOW + 3600))
    run tick
    eq "rc" 1 "$RC"
    has "message" "stays for the next tick" "$ERR"
    exists "kept" "$(state_file "$ID")"
    eq "no hidden leftovers" 1 "$(count_files)"
    absent "no .fire file" "$S/state/tremind/.fire.$ID"
    eq "timer kept" 0 "$(systemctl_calls 'disable')"
    rm -f -- "$S/notify-fail"
    run tick
    eq "second tick rc" 0 "$RC"
    eq "shown at last" 1 "$(count_notify)"
}

t_tick_without_notify_send() {
    mkdir -p "$S/rbin"
    local tool
    for tool in date sed mktemp mv rm head wc iconv flock readlink mkdir cat dirname timeout; do
        ln -s "$(command -v "$tool")" "$S/rbin/$tool"
    done
    ln -s "$S/bin/systemctl" "$S/rbin/systemctl"
    add -t 1m "Keep me"
    T_PATH=$S/rbin
    NOW=$((BASE_NOW + 3600))
    run tick
    eq "rc" 1 "$RC"
    has "message" "notify-send is missing" "$ERR"
    exists "kept" "$(state_file "$ID")"
    eq "timer kept" 0 "$(systemctl_calls 'disable')"
}

t_tick_recovers_an_orphan() {
    mkdir -p "$S/state/tremind"
    printf 'due=2027-04-15 08:30\nepoch=%s\n\nOrphan\n' "$(epoch_of '2027-04-15 08:30')" >"$S/state/tremind/.fire.2704150830-abc"
    run tick
    eq "not due yet: restored" 0 "$RC"
    exists "back under its id" "$S/state/tremind/2704150830-abc"
    absent "no .fire file" "$S/state/tremind/.fire.2704150830-abc"
    eq "not shown" 0 "$(count_notify)"
    NOW=$((BASE_NOW + 3600))
    run tick
    eq "then shown" 1 "$(count_notify)"
}

t_tick_skips_a_damaged_file() {
    mkdir -p "$S/state/tremind"
    printf 'garbage\n' >"$S/state/tremind/2704150830-zzz"
    add -t 1m ok
    NOW=$((BASE_NOW + 3600))
    run tick
    eq "rc" 0 "$RC"
    has "warning" "skipping 2704150830-zzz" "$ERR"
    exists "kept" "$S/state/tremind/2704150830-zzz"
    eq "the good one fired" 1 "$(count_notify)"
    eq "timer kept (a file is left)" 0 "$(systemctl_calls 'disable')"
}

t_tick_parallel_shows_once() {
    add -t 1m "Once"
    NOW=$((BASE_NOW + 3600))
    local i
    for i in 1 2 3 4 5 6; do
        env -i PATH="$S/bin:$BASEPATH" HOME="$S/home" XDG_STATE_HOME="$S/state" XDG_CONFIG_HOME="$S/config" \
            LANG=C.UTF-8 TREMIND_NOW_EPOCH="$NOW" "$BASH" "$SCRIPT" tick >/dev/null 2>&1 &
    done
    wait
    eq "one notification for six ticks" 1 "$(count_notify)"
    eq "gone" 0 "$(count_files)"
}

# ---- Tests: units, systemd -------------------------------------------------------------------

t_add_installs_the_timer_once() {
    add -t 1h a
    exists "service" "$S/config/systemd/user/tremind.service"
    exists "timer" "$S/config/systemd/user/tremind.timer"
    local service timer
    service=$(<"$S/config/systemd/user/tremind.service")
    timer=$(<"$S/config/systemd/user/tremind.timer")
    has "ExecStart names bash" "ExecStart=/usr/bin/env bash \"$TREMIND\" tick" "$service"
    has "Type" "Type=oneshot" "$service"
    has "state folder follows the session" "Environment=\"XDG_STATE_HOME=$S/state\"" "$service"
    has "every minute" "OnCalendar=minutely" "$timer"
    has "accuracy" "AccuracySec=1s" "$timer"
    has "catches up" "Persistent=true" "$timer"
    has "wanted by" "WantedBy=timers.target" "$timer"
    eq "daemon-reload once" 1 "$(systemctl_calls 'daemon-reload')"
    eq "enabled once" 1 "$(systemctl_calls 'enable --now tremind.timer')"
    add -t 2h b
    eq "no second reload" 1 "$(systemctl_calls 'daemon-reload')"
    eq "no second enable (already active)" 1 "$(systemctl_calls 'enable --now tremind.timer')"
    rm -f -- "$S/timer-active"
    add -t 3h c
    eq "a stopped timer is started again" 2 "$(systemctl_calls 'enable --now tremind.timer')"
    eq "without a reload" 1 "$(systemctl_calls 'daemon-reload')"
}

t_units_are_rewritten_when_stale() {
    add -t 1h a
    printf '[Service]\nExecStart=/old/place tick\n' >"$S/config/systemd/user/tremind.service"
    add -t 2h b
    has "rewritten" "ExecStart=/usr/bin/env bash \"$TREMIND\" tick" "$(<"$S/config/systemd/user/tremind.service")"
    eq "reloaded" 2 "$(systemctl_calls 'daemon-reload')"
}

t_unit_quoting() {
    mkdir -p "$S/odd"
    local dir="$S/odd/my dir %s"
    mkdir -p "$dir"
    cp "$TREMIND" "$dir/tremind"
    SCRIPT="$dir/tremind"
    add -t 1h x
    eq "rc" 0 "$RC"
    has "ExecStart quoted, % doubled" "ExecStart=/usr/bin/env bash \"$S/odd/my dir %%s/tremind\" tick" "$(<"$S/config/systemd/user/tremind.service")"
    rm -f -- "$dir/tremind"
    rmdir "$dir"
}

t_unit_refuses_unquotable_paths() {
    mkdir -p "$S/odd"
    local name dir
    for name in 'with $x' 'with "q"' "with 'q'" 'with \b'; do
        dir="$S/odd/$name"
        mkdir -p "$dir"
        cp "$TREMIND" "$dir/tremind"
        SCRIPT="$dir/tremind"
        add -t 1h x
        eq "rc for [$name]" 1 "$RC"
        has "message for [$name]" "cannot go in a unit file" "$ERR"
        eq "nothing left for [$name]" 0 "$(count_files)"
        rm -f -- "$dir/tremind"
        rmdir "$dir"
    done
}

t_no_state_folder_variable_means_the_default() {
    EXTRA=(XDG_STATE_HOME=relative/path)
    add -t 1h x
    eq "rc" 0 "$RC"
    exists "default folder under HOME" "$S/home/.local/state/tremind/$ID"
    hasnt "no Environment line for a relative path" "Environment=" "$(<"$S/config/systemd/user/tremind.service")"
}

t_add_leaves_nothing_when_systemd_is_down() {
    : >"$S/no-systemd"
    add -t 1h x
    eq "rc" 1 "$RC"
    match "message" 'cannot (reach|start)' "$ERR"
    eq "no reminder left behind" 0 "$(count_files)"
}

t_install_and_uninstall() {
    run install
    eq "install rc" 0 "$RC"
    exists "service" "$S/config/systemd/user/tremind.service"
    add -t 1h keep
    run uninstall
    eq "uninstall rc" 0 "$RC"
    absent "service removed" "$S/config/systemd/user/tremind.service"
    absent "timer removed" "$S/config/systemd/user/tremind.timer"
    exists "reminders kept" "$(state_file "$ID")"
    has "message" "Pending reminders are kept" "$OUT"
    eq "timer stopped" 1 "$(systemctl_calls 'disable --now tremind.timer')"
    eq "units reloaded after the removal (the install did the first reload)" 2 "$(systemctl_calls 'daemon-reload')"
}

t_test_command() {
    run test
    eq "rc" 0 "$RC"
    has "notify-send" "notify-send:  found" "$OUT"
    has "systemd" "systemd user: reachable" "$OUT"
    has "pending" "pending:      0" "$OUT"
    has "units not installed yet" "units:        not installed" "$OUT"
    has "state folder" "state folder: $S/state/tremind" "$OUT"
    eq "a notification was shown" 1 "$(count_notify)"
    notify_args 1
    eq "text" "tremind works" "${ARGS[10]}"
    rm -f -- "$S"/notify.*
    add -t 1h x
    run test
    has "units current" "units:        current" "$OUT"
    has "timer" "timer:        active" "$OUT"
    has "pending count" "pending:      1" "$OUT"
    : >"$S/notify-fail"
    run test
    eq "rc when the notification fails" 1 "$RC"
    has "failure shown" "notification: FAILED" "$OUT"
    rm -f -- "$S/notify-fail" "$S"/notify.*
    : >"$S/no-systemd"
    run test
    eq "rc without systemd" 1 "$RC"
    has "systemd NOT reachable" "NOT reachable" "$OUT"
}

t_parallel_adds() {
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        env -i PATH="$S/bin:$BASEPATH" HOME="$S/home" XDG_STATE_HOME="$S/state" XDG_CONFIG_HOME="$S/config" \
            LANG=C.UTF-8 TREMIND_NOW_EPOCH="$NOW" "$BASH" "$SCRIPT" add --at "2027-05-01 10:00" "n$i" >/dev/null 2>&1 &
    done
    wait
    eq "ten reminders with ten different ids" 10 "$(count_files)"
    local leftovers=0 f
    for f in "$S"/state/tremind/.new.*; do [[ -e $f ]] && leftovers=$((leftovers + 1)); done
    eq "no temporary file left" 0 "$leftovers"
    eq "units written once" 1 "$(systemctl_calls 'daemon-reload')"
}

t_help_and_version() {
    run --help
    eq "help rc" 0 "$RC"
    has "usage" "Usage: tremind COMMAND" "$OUT"
    run --version
    eq "version rc" 0 "$RC"
    match "version" '^tremind [0-9]+\.[0-9]+\.[0-9]+$' "$OUT"
}


# ---- Tests: instants, clock changes ----------------------------------------------------------

t_boundaries_of_times() {
    NOW=$((BASE_NOW + 1))
    add -t 30m x
    has "a second past the minute rounds up" "on 2027-04-15 08:31" "$OUT"
    NOW=$((BASE_NOW + 30))
    add --at "2027-04-15 08:00" x
    eq "the current minute, 30 s in" 0 "$RC"
    add -t 3650d x
    eq "3650 days from a moment inside a minute" 0 "$RC"
    add -t 3651d x
    eq "3651 days" 1 "$RC"
    add -t 08m x
    eq "leading zero" 0 "$RC"
    add -t 1h30 x
    eq "no unit at the end" 1 "$RC"
    add -t 1h30s x
    eq "seconds" 1 "$RC"
}

t_delay_across_the_autumn_clock_change() {
    [[ -e /usr/share/zoneinfo/Europe/Paris ]] || { echo "skip: no tzdata" >&2; return 0; }
    T_TZ=Europe/Paris
    NOW=$(TZ=UTC date -d '2026-10-25 00:50:00' +%s)   # 02:50 summer time, the clock goes back at 03:00
    add -t 1h x
    has "shown as local text" "on 2026-10-25 02:50" "$OUT"
    NOW=$(TZ=UTC date -d '2026-10-25 00:55:00' +%s)   # 02:55 summer time: only 5 minutes later
    run tick
    eq "not shown after 5 minutes" 0 "$(count_notify)"
    NOW=$(TZ=UTC date -d '2026-10-25 01:49:00' +%s)
    run tick
    eq "not shown at 59 minutes" 0 "$(count_notify)"
    NOW=$(TZ=UTC date -d '2026-10-25 01:50:00' +%s)
    run tick
    eq "shown after the hour" 1 "$(count_notify)"
}

t_exact_time_in_the_repeated_hour_is_the_later() {
    [[ -e /usr/share/zoneinfo/Europe/Paris ]] || { echo "skip: no tzdata" >&2; return 0; }
    T_TZ=Europe/Paris
    NOW=$(TZ=UTC date -d '2026-10-20 12:00:00' +%s)
    add --at "2026-10-25 02:30" x
    eq "rc" 0 "$RC"
    eq "the 02:30 of winter time, the later one" "epoch=$(TZ=UTC date -d '2026-10-25 01:30:00' +%s)" "$(sed -n 2p "$(state_file "$ID")")"
}

t_a_zone_change_does_not_move_a_reminder() {
    [[ -e /usr/share/zoneinfo/Asia/Tokyo ]] || { echo "skip: no tzdata" >&2; return 0; }
    add -t 1h x
    T_TZ=Asia/Tokyo
    NOW=$((BASE_NOW + 3599))
    run tick
    eq "not yet, in another zone" 0 "$(count_notify)"
    NOW=$((BASE_NOW + 3600))
    run tick
    eq "shown at the same instant" 1 "$(count_notify)"
}

# ---- Tests: cancel, orphans, folders ---------------------------------------------------------

t_cancel_double_dash_is_literal() {
    add -t 1h a
    add -t 2h b
    run cancel -- --all
    eq "rc" 1 "$RC"
    has "treated as an id" "not a reminder id: --all" "$ERR"
    eq "both remain" 2 "$(count_files)"
}

t_orphan_does_not_come_back_after_cancel() {
    add -t 1m "Doomed"
    mv "$(state_file "$ID")" "$S/state/tremind/.fire.$ID"
    run cancel "$ID"
    eq "rc" 0 "$RC"
    absent "gone" "$(state_file "$ID")"
    absent "no orphan left" "$S/state/tremind/.fire.$ID"
    NOW=$((BASE_NOW + 3600))
    run tick
    eq "never shown" 0 "$(count_notify)"
}

t_orphan_keeps_the_timer_armed() {
    put_state 2704150830-abc "2027-04-15 08:30" "Orphan"
    mv "$S/state/tremind/2704150830-abc" "$S/state/tremind/.fire.2704150830-abc"
    add -t 1h other
    run cancel "$ID"
    eq "the recovered orphan counts as pending" 0 "$(systemctl_calls 'disable')"
    run ids
    eq "visible again" "2704150830-abc" "$OUT"
}

t_a_second_state_folder_is_refused_while_reminders_wait() {
    add -t 1h first
    eq "first add" 0 "$RC"
    EXTRA=(XDG_STATE_HOME="$S/state2")
    add -t 1h second
    eq "other folder refused" 1 "$RC"
    has "message" "the timer reads $S/state/tremind" "$ERR"
    eq "no stranded reminder" 0 "$(count_in "$S/state2/tremind")"
    EXTRA=(XDG_STATE_HOME=)
    add -t 1h third
    eq "no variable (the default folder) refused too" 1 "$RC"
    EXTRA=()
    run cancel --all
    EXTRA=(XDG_STATE_HOME="$S/state2")
    add -t 1h fourth
    eq "allowed once the old folder is empty" 0 "$RC"
    has "the unit follows" "XDG_STATE_HOME=$S/state2" "$(<"$S/config/systemd/user/tremind.service")"
}

t_add_leaves_nothing_when_enable_fails() {
    add -t 1h a
    rm -f -- "$S/timer-active"
    # A systemctl that refuses "enable" while the units are current.
    cat >"$S/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case $2 in is-active) exit 3 ;; enable) echo "boom" >&2; exit 1 ;; *) exit 0 ;; esac
EOF
    add -t 2h b
    eq "rc" 1 "$RC"
    has "message" "cannot start tremind.timer" "$ERR"
    eq "only the first reminder is left" 1 "$(count_files)"
}

t_install_without_systemd_fails() {
    : >"$S/no-systemd"
    run install
    eq "rc" 1 "$RC"
    match "message" 'cannot (reach|start)' "$ERR"
}

# ---- Tests: notification text ----------------------------------------------------------------

t_backslashes_survive_notify_send() {
    add -t 1m --body 'C:\new\table \033[31m end\'
    NOW=$((BASE_NOW + 3600))
    run tick
    notify_args 1
    eq "doubled, so that notify-send gives them back" 'C:\\new\\table \\033[31m end\\' "${ARGS[10]}"
}

t_title_rules() {
    local case want
    for case in "LC_ALL=fr_FR.UTF-8 LANG=C|Rappel" "LC_ALL=C LANG=fr_FR.UTF-8|Reminder" "LC_MESSAGES=fr_FR.UTF-8 LANG=C|Rappel" "LANG=fr|Rappel" "LANG=de_DE.UTF-8|Reminder"; do
        want=${case#*|}
        NOW=$BASE_NOW
        add -t 1m x
        EXTRA=(${case%|*})
        T_LANG=""
        NOW=$((BASE_NOW + 3600))
        run tick
        notify_args "$(count_notify)"
        eq "title for [${case%|*}]" "$want" "${ARGS[9]}"
        EXTRA=()
        rm -f -- "$S"/notify.*
    done
}

t_a_helper_left_by_notify_send_does_not_keep_the_lock() {
    : >"$S/notify-linger"
    add -t 1m first
    NOW=$((BASE_NOW + 3600))
    run tick
    eq "tick rc" 0 "$RC"
    local start=$SECONDS
    add -t 1h second
    eq "add rc" 0 "$RC"
    eq "no wait on the lock" 1 "$((SECONDS - start < 3))"
}

t_list_cuts_on_characters_without_a_locale() {
    T_LANG=""
    add -t 1h "$(longstr 80 é)"
    run list
    eq "rc" 0 "$RC"
    printf '%s\n' "$OUT" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1
    eq "valid UTF-8" 0 "$?"
    has "59 characters then the ellipsis" "$(longstr 59 é)…" "$OUT"
    hasnt "not 60" "$(longstr 60 é)" "$OUT"
}

t_list_boundaries() {
    add --at "2027-06-01 10:00" "$(longstr 60 a)"
    add --at "2027-06-02 10:00" "$(longstr 61 b)"
    add --at "2027-06-03 10:00" --body $'one\ntwo'
    add --at "2027-06-04 10:00" --body $'only\n'
    run list
    has "60 characters kept" "$(longstr 60 a)" "$OUT"
    hasnt "no ellipsis at 60" "$(longstr 60 a)…" "$OUT"
    has "61 cut" "$(longstr 59 b)…" "$OUT"
    has "two lines" "one  [+1 lines]" "$OUT"
    hasnt "a trailing newline is not a second line" "only  [+" "$OUT"
}

t_list_and_tick_skip_damaged_files() {
    mkdir -p "$S/state/tremind"
    printf 'due=garbage\nepoch=1\n\nx\n' >"$S/state/tremind/2704150830-aaa"
    printf '2027-04-15 08:30\nepoch=1\n\nx\n' >"$S/state/tremind/2704150830-bbb"
    : >"$S/state/tremind/2704150830-ccc"
    printf 'due=2027-04-15 08:30\n\nx\n' >"$S/state/tremind/2704150830-ddd"
    put_state 2704150830-eee "2027-04-15 08:30" "The good one"
    run list
    eq "list rc" 0 "$RC"
    has "the good one is listed" "The good one" "$OUT"
    has "warning for the empty file" "skipping 2704150830-ccc" "$ERR"
    has "warning for the old format" "skipping 2704150830-ddd" "$ERR"
    NOW=$((BASE_NOW + 3600))
    run tick
    eq "tick rc" 0 "$RC"
    eq "only the good one is shown" 1 "$(count_notify)"
    eq "four damaged files kept" 4 "$(count_files)"
}

t_invisible_characters() {
    local name text
    local -A refused=(
        [C1 control]=$'a\xc2\x85b' [arabic letter mark]=$'a\xd8\x9cb' [left-to-right mark]=$'a\xe2\x80\x8eb'
        [line separator]=$'a\xe2\x80\xa8b' [paragraph separator]=$'a\xe2\x80\xa9b' [word joiner]=$'a\xe2\x81\xa0b'
        [invisible times]=$'a\xe2\x81\xa2b'
    )
    for name in "${!refused[@]}"; do
        add -t 1h --body "${refused[$name]}"
        eq "refused: $name" 1 "$RC"
    done
    add -t 1h --body $'family \xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7 and \xd9\x85\xdb\x8c\xe2\x80\x8c\xd8\xae\xd9\x88\xd8\xa7\xd9\x87\xd9\x85'
    eq "zero-width joiner and non-joiner are kept" 0 "$RC"
}

t_presets_tomorrow_by_the_calendar() {
    [[ -e /usr/share/zoneinfo/Europe/Paris ]] || { echo "skip: no tzdata" >&2; return 0; }
    T_TZ=Europe/Paris
    NOW=$(TZ=UTC date -d '2026-10-24 21:30:00' +%s)   # 23:30 on the 24th, the clock goes back that night
    run presets
    eq "tomorrow is the 25th" "2026-10-25 09:00" "$(sed -n '/^2026/p' <<<"$OUT" | sed -n 1p)"
    NOW=$(TZ=UTC date -d '2027-03-27 22:30:00' +%s)   # 23:30 on the 27th, the clock goes forward that night
    run presets
    eq "tomorrow is the 28th" "2027-03-28 09:00" "$(sed -n '/^2027/p' <<<"$OUT" | sed -n 1p)"
}

t_umask_and_modes() {
    local old
    old=$(umask)
    umask 022
    add -t 1h x
    umask "$old"
    eq "state folder" 700 "$(stat -c %a "$S/state/tremind")"
    eq "lock file" 600 "$(stat -c %a "$S/state/tremind/.lock")"
    eq "reminder" 600 "$(stat -c %a "$(state_file "$ID")")"
}

t_failures_are_reported() {
    # No HOME and no XDG variable.
    env -i PATH="$S/bin:$BASEPATH" "$BASH" "$SCRIPT" list >"$S/out" 2>"$S/err"
    eq "no HOME" 1 "$?"
    has "message" "HOME is not set" "$(<"$S/err")"
    # A state folder that cannot be written (not as root).
    if [[ $(id -u) -ne 0 ]]; then
        mkdir -p "$S/state/tremind"
        chmod 500 "$S/state/tremind"
        add -t 1h x
        eq "read-only folder" 1 "$RC"
        eq "nothing printed on stdout" "" "$OUT"
        chmod 700 "$S/state/tremind"
    fi
}

# ---- Runner ----------------------------------------------------------------------------------

main() {
    local filter=${1:-} name total=0
    command -v flock >/dev/null || { echo "flock is required to run the tests" >&2; exit 1; }
    for name in $(declare -F | sed -n 's/^declare -f \(t_.*\)$/\1/p'); do
        [[ -z $filter || $name == *"$filter"* ]] || continue
        current=${name#t_}
        total=$((total + 1))
        new_sandbox
        "$name"
        wipe_sandbox
    done
    printf '%d tests, %d checks passed, %d failed\n' "$total" "$pass" "$fail"
    ((fail == 0))
}

main "$@"
