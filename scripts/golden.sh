#!/bin/zsh
# The plugin against in-process MLXServeEngine: seeded songs composed on the signed bundle the way Gaea calls it
# (gaea-plugin-check: launch under the launch requirement, configure, prepare, run) and through ace-step-inproc with the
# lane configuration, requests and cut the worker uses. Each pair must be byte for byte the same WAV, of the length MES
# says.
#
#   scripts/golden.sh <out-dir>     (after scripts/build-plugin.sh)
#
# Cases (int8): a 10 s song; a 30 s song with bpm, key and time signature pinned; a 15 s instrumental; a Chinese song; a
# 10 s song with Tests/Fixtures/source.wav as its reference; and that 2 s source covered, repainted (0.5–1.5 s) and
# extended (1 s before, 1.5 s after: 4.5 s).
set -uo pipefail
ROOT=${0:A:h:h}
cd $ROOT
OUT=${1:?out dir}; mkdir -p $OUT
B=$ROOT/dist/ace-step.gaeaplugin
SRC=$ROOT/Tests/Fixtures/source.wav
MODELS=${CHECK_MODELS_ROOT:-$HOME/Library/Application Support/MLXEngine/Models}
SWIFTPM=(-c release --build-system swiftbuild)
xcrun swift build $SWIFTPM --product ace-step-inproc > /dev/null && xcrun swift build -c release --product gaea-plugin-check > /dev/null
INPROC=$(xcrun swift build $SWIFTPM --show-bin-path)/ace-step-inproc; CHECK=$(xcrun swift build -c release --show-bin-path)/gaea-plugin-check
LOG=$OUT/golden.log; : > $LOG
pass=0; fail=0
say() { print -r -- "$*" | tee -a $LOG }
say "# ACE-Step golden check $(date -u +%FT%TZ): $(python3 -c "import json; m=json.load(open('$B/Contents/Resources/manifest.json')); print(m['id'], m['version'])")"
same() { # name, gpp wav, inproc wav, frames ("" when the planner decides)
  local a=$(shasum -a 256 $2 2>/dev/null | cut -c1-16) b=$(shasum -a 256 $3 2>/dev/null | cut -c1-16)
  local n=$(python3 -c "import wave,sys; print(wave.open(sys.argv[1]).getnframes())" $2 2>/dev/null)
  if [[ -n $a && $a == $b && ( -z $4 || $n == $4 ) ]]; then pass=$((pass+1)); say "PASS  $1: byte-identical, $n frames, sha256 $a…"
  else fail=$((fail+1)); say "FAIL  $1: $a… / $b…, $n frames (want ${4:-any})"; fi
}
outputs() { grep -o '"path":"[^"]*"' $1 | sed 's/"path":"//; s/"$//; s/\\\//\//g' | awk '!seen[$0]++' }

CAPTION='Upbeat synth-pop with a bright female vocal and a driving beat.'
LYRICS=$'[verse]\nLights on the water\nWe follow the line\n[chorus]\nRun all night\n'

# song <name> <seed> <params json> <frames> <gpp extra args (array name)> -- <inproc args…>
song() {
  local name=$1 seed=$2 params=$3 frames=$4; shift 4
  local -a gpp=(); while [[ $# -gt 0 && $1 != -- ]]; do gpp+=("$1"); shift; done; shift
  $CHECK $B --operation audio.compose --model ace-step-1.5 --lane int8 --params $params --seed $seed "${gpp[@]}" \
    --models-root "$MODELS" --budget 64000000000 --timeout 1800 --session $OUT/$name.gpp > $OUT/$name-gpp.log 2>&1
  local file=$(outputs $OUT/$name-gpp.log | head -1); [[ -f $file ]] && cp $file $OUT/$name-gpp.wav
  $INPROC --seed $seed --models-root "$MODELS" --out $OUT/$name-inproc.wav "$@" 2>> $LOG | tail -1 > $OUT/$name-inproc.json
  say "      $name: over GPP $(grep -o 'ran in [0-9.]* s' $OUT/$name-gpp.log | head -1); in-process $(cat $OUT/$name-inproc.json)"
  same $name $OUT/$name-gpp.wav $OUT/$name-inproc.wav $frames
}

song song10 5 '{"duration_s":10,"language":"en"}' 480000 --text "caption=$CAPTION" --text "lyrics=$LYRICS" \
  -- --caption "$CAPTION" --lyrics "$LYRICS" --language en --duration 10
song anchored 9 '{"duration_s":30,"language":"en","anchors":{"bpm":96,"key":"F# minor","time_signature":"3/4"}}' 1440000 \
  --text "caption=A slow waltz, piano and cello, a tender male vocal." --text "lyrics=$LYRICS" \
  -- --caption "A slow waltz, piano and cello, a tender male vocal." --lyrics "$LYRICS" --language en --duration 30 \
     --anchors '{"bpm":96,"key":"F# minor","time_signature":"3/4"}'
song instrumental 3 '{"duration_s":15}' 720000 --text "caption=Lo-fi hip-hop instrumental, mellow keys, vinyl crackle." \
  -- --caption "Lo-fi hip-hop instrumental, mellow keys, vinyl crackle." --duration 15
ZH=$'[verse]\n夜色温柔\n我们一起走\n[chorus]\n不要回头\n'
song chinese 2 '{"duration_s":12,"language":"zh"}' 576000 --text "caption=Mandopop ballad, soft female vocal, strings." --text "lyrics=$ZH" \
  -- --caption "Mandopop ballad, soft female vocal, strings." --lyrics "$ZH" --language zh --duration 12
song reference 4 '{"duration_s":10,"language":"en"}' 480000 --text "caption=$CAPTION" --text "lyrics=$LYRICS" --input "reference=$SRC" \
  -- --caption "$CAPTION" --lyrics "$LYRICS" --language en --duration 10 --reference $SRC
song cover 6 '{"language":"en","edit":{"kind":"cover","strength":0.7}}' 96000 --text "caption=Acoustic folk, guitar and voice." --text "lyrics=$LYRICS" --input "source=$SRC" \
  -- --caption "Acoustic folk, guitar and voice." --lyrics "$LYRICS" --language en --edit '{"kind":"cover","strength":0.7}' --source $SRC
song repaint 7 '{"language":"en","edit":{"kind":"repaint","start_s":0.5,"end_s":1.5}}' 96000 --text "caption=$CAPTION" --text "lyrics=$LYRICS" --input "source=$SRC" \
  -- --caption "$CAPTION" --lyrics "$LYRICS" --language en --edit '{"kind":"repaint","start_s":0.5,"end_s":1.5}' --source $SRC
song extend 8 '{"language":"en","edit":{"kind":"extend","before_s":1,"after_s":1.5}}' 216000 --text "caption=$CAPTION" --text "lyrics=$LYRICS" --input "source=$SRC" \
  -- --caption "$CAPTION" --lyrics "$LYRICS" --language en --edit '{"kind":"extend","before_s":1,"after_s":1.5}' --source $SRC

check_anchors() {
  python3 -c "
import json, sys
for line in open(sys.argv[1]):
    if line.startswith('W ') and '\"type\":\"result\"' in line:
        a = json.loads(line[2:])['effective'].get('anchors', {})
        sys.exit(0 if (a.get('bpm'), a.get('key'), a.get('time_signature')) == (96, 'F# minor', '3/4') else 1)
sys.exit(1)" $OUT/anchored.gpp
}
if check_anchors; then pass=$((pass+1)); say "PASS  anchored reports the pinned anchors (96 bpm, F# minor, 3/4)"; else fail=$((fail+1)); say "FAIL  anchored's effective anchors"; fi

for s in $OUT/*.gpp; do
  if python3 ${GAEA_SPEC_ROOT:-$ROOT/../gaea-mes-media-server}/tools/validate.py --transcript $s >> $LOG 2>&1; then pass=$((pass+1)); say "PASS  ${s:t} passes validate.py"
  else fail=$((fail+1)); say "FAIL  ${s:t} fails validate.py"; fi
done
say "== $pass passed, $fail failed"
exit $(( fail > 0 ))
