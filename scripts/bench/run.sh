#!/bin/bash
# Test bench: measures the app during scripted calls, without the provider and at no cost.
#
# A copy of the Dev build with its own identifier ("SIP Anywhere Bench": own settings,
# log and folders, no password stored) registers with a stand-in registrar on this Mac,
# then PJSIP's test phone (pjsua, also on this Mac) calls it and plays recorded speech.
# The bench copy answers by itself and plays the script in Sources/SIPAnywhere/Bench.swift
# (panel, keypad, recording, window); calls are silent (volume 0, no ringtone).
# Each phase is sampled; the report gives CPU per thread, memory and leaks.
#
#   scripts/bench/run.sh [calls]      (default 1 call of about 60 s)
#   scripts/bench/run.sh voicemail    (Do Not Disturb: the answering machine answers after
#                                      3 s, the test phone talks, the message must be saved)
#
# Needs a build (./build_app.sh). The first run asks for microphone access for the
# bench copy. Close the real Dev first for clean figures (both would use the audio).
set -euo pipefail
cd "$(dirname "$0")/../.."
CALLS=${1:-1}
SCENARIO=calls
if [ "$CALLS" = voicemail ]; then SCENARIO=voicemail; CALLS=1; fi
OUT=.build/bench
mkdir -p "$OUT"
rm -f "$OUT"/*.sample "$OUT"/heap-*.txt "$OUT"/vmmap-*.txt "$OUT"/report.txt

# The build to measure: the Dev build on develop, the stable one on main.
DEV="build/SIP Anywhere Dev.app"
[ -d "$DEV" ] || DEV="build/SIP Anywhere.app"
APP="build/SIP Anywhere Bench.app"
[ -d "$DEV" ] || { echo "Build the app first: ./build_app.sh" >&2; exit 1; }
if pgrep -f "SIP Anywhere Bench.app/Contents/MacOS" >/dev/null; then
    echo "The bench copy is already running." >&2; exit 1
fi
rm -rf "$APP"
cp -R "$DEV" "$APP"
PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleName SIP Anywhere Bench" \
    -c "Set :CFBundleDisplayName SIP Anywhere Bench" \
    -c "Set :CFBundleIdentifier io.github.andrea79.SIPAnywhere.bench" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" 2>/dev/null

PJSUA=$(ls vendor/build-arm64/pjsip-apps/bin/pjsua-* | head -1)
WAV="$OUT/voice.wav"
if [ ! -f "$WAV" ]; then
    say -o "$WAV" --file-format=WAVE --data-format=LEI16@8000 \
        "Hello, this is a test call to measure how much the phone uses. \
         The text is repeated for the whole call, like a person talking. \
         One, two, three, four, five, six, seven, eight, nine, ten."
fi
LOG="$HOME/Library/Logs/SIP Anywhere Bench/sip.log"

REG=""; PEER=""
cleanup() {
    osascript -e 'quit app "SIP Anywhere Bench"' >/dev/null 2>&1 || true
    [ -n "$PEER" ] && kill "$PEER" 2>/dev/null || true
    [ -n "$REG" ] && kill "$REG" 2>/dev/null || true
}
trap cleanup EXIT

python3 scripts/bench/registrar.py 5070 &
REG=$!

log_lines() { [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0; }
# Waits (up to $2 s) for a log line matching $1 written after line $3.
wait_log() {
    local pattern=$1 timeout=$2 from=$3
    for _ in $(seq 1 "$timeout"); do
        [ -f "$LOG" ] && tail -n +"$((from + 1))" "$LOG" | grep -q "$pattern" && return 0
        sleep 1
    done
    echo "Timed out waiting for: $pattern" >&2
    return 1
}
# Samples the app for $2 s into $OUT/$1.sample.
probe() { sample "$PID" "$2" -file "$OUT/$1.sample" >/dev/null 2>&1; }

footprint_now() {
    vmmap --summary "$PID" 2>/dev/null | awk -F': *' '/^Physical footprint:/ {now=$2} /^Physical footprint \(peak\):/ {print now " (peak so far " $2 ")"; exit}'
}
MEM=()

start=$(log_lines)
if [ "$SCENARIO" = voicemail ]; then
    defaults write io.github.andrea79.SIPAnywhere.bench doNotDisturb -bool YES
    rm -rf "$HOME/Music/SIP Anywhere Bench/Voicemail"
else
    defaults write io.github.andrea79.SIPAnywhere.bench doNotDisturb -bool NO
fi
open --env BENCH_SCENARIO="$SCENARIO" "$APP"
echo "Waiting for the bench copy to register…"
wait_log "registration success" 90 "$start"
PID=$(pgrep -f "SIP Anywhere Bench.app/Contents/MacOS")
sleep 5

echo "Idle (registered, no call)…"
MEM+=("idle before calls: $(footprint_now)")
probe idle 10

if [ "$SCENARIO" = voicemail ]; then
    echo "Answering machine: a call of 20 s, the machine answers after 3 s…"
    from=$(log_lines)
    # Speech starts once the machine has answered (3 s) and goes on through the
    # greeting and the message.
    ( sleep 4; printf 'cc\n1\n4\n'; sleep 40; printf 'q\n' ) | "$PJSUA" \
        --local-port=5072 --no-tcp --null-audio --no-vad --play-file="$WAV" --duration=20 \
        --dis-codec=G722 --dis-codec=speex --dis-codec=iLBC --dis-codec=GSM --dis-codec=PCMU \
        --dis-codec=opus --log-level=3 --app-log-level=0 \
        sip:bench@127.0.0.1:5080 > "$OUT/peer.log" 2>&1 &
    PEER=$!
    wait_log "DISCONNECTED" 60 "$from" || true
    sleep 5
    kill "$PEER" 2>/dev/null || true; PEER=""
    {
        echo "Bench $(date '+%Y-%m-%d %H:%M'), answering machine, $(git log --oneline -1)"
        tail -n +"$((from + 1))" "$LOG" | grep -E "answering machine|Answering machine" | sed 's/^/   /'
        echo "== Voicemail folder:"
        for f in "$HOME/Music/SIP Anywhere Bench/Voicemail"/*.wav; do
            [ -f "$f" ] && echo "   $(basename "$f"): $(afinfo "$f" | awk '/estimated duration/ {print $3 " s"}')"
        done
        ls "$HOME/Music/SIP Anywhere Bench/Voicemail"/*.wav >/dev/null 2>&1 \
            && echo "== PASS: the message was saved" || echo "== FAIL: no message saved"
    } | tee "$OUT/report.txt"
    exit 0
fi

for n in $(seq 1 "$CALLS"); do
    echo "Call $n of $CALLS (about 60 s)…"
    from=$(log_lines)
    # The test phone calls the bench copy; 5 s later (after the answer) it starts
    # playing the recorded speech into the call. Its conference ports, with no sound
    # device: 0 master, 1 the file, 2 ringback, 3 ring, 4 the call.
    ( sleep 5; printf 'cc\n1\n4\n'; sleep 75; printf 'q\n' ) | "$PJSUA" \
        --local-port=5072 --no-tcp --null-audio --no-vad --play-file="$WAV" --duration=62 \
        --dis-codec=G722 --dis-codec=speex --dis-codec=iLBC --dis-codec=GSM --dis-codec=PCMU \
        --dis-codec=opus --log-level=3 --app-log-level=0 \
        sip:bench@127.0.0.1:5080 > "$OUT/peer.log" 2>&1 &
    PEER=$!
    wait_log "BENCH step answer" 20 "$from"
    t0=$SECONDS                       # = 2 s after the call rang (see Bench.swift)
    at() { local due=$(( $1 - 2 )); while (( SECONDS - t0 < due )); do sleep 0.2; done; }
    if [ "$n" = 1 ]; then
        at 5;  probe call-panel 13; MEM+=("call-panel: $(footprint_now)")            # steady call, panel shown
        at 20; probe call-keypad 10; MEM+=("call-keypad: $(footprint_now)")           # keypad opened and closed 6 times
        at 32; probe call-recording 7; MEM+=("call-recording: $(footprint_now)")         # recording to a file
        at 43; probe call-window 8; MEM+=("call-window: $(footprint_now)")            # steady call, window open
        at 53; probe call-after 6; MEM+=("call-after: $(footprint_now)")             # window closed again
    fi
    wait_log "DISCONNECTED\|Call ended\|state.*DISCONN" 90 "$from" || true
    kill "$PEER" 2>/dev/null || true; PEER=""
    sleep 5
    MEM+=("after call $n: $(footprint_now)")
    heap "$PID" > "$OUT/heap-$n.txt" 2>/dev/null || true      # objects by class, to compare
    vmmap --summary "$PID" > "$OUT/vmmap-$n.txt" 2>/dev/null || true   # memory by region
done

echo "Idle again, then leaks…"
probe idle-after 10
leaks "$PID" > "$OUT/leaks.txt" 2>&1 || true

{
    echo "Bench $(date '+%Y-%m-%d %H:%M'), $CALLS call(s), $(git log --oneline -1)"
    python3 scripts/bench/analyze.py "$OUT"/idle.sample "$OUT"/call-*.sample "$OUT"/idle-after.sample
    printf '== memory: %s\n' "${MEM[@]}"
    echo "== leaks: $(grep -m1 -E 'leaks? for' "$OUT/leaks.txt" || echo 'see leaks.txt')"
    echo "== audio: $(tail -n +"$((start + 1))" "$LOG" | grep -c 'Underflow' || true) buffer underflows in the bench log"
} | tee "$OUT/report.txt"
