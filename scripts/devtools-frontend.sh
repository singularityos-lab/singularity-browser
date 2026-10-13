#!/bin/sh
set -eu

REVISION=00c8c49be80f6af049378d9e1e8979d896e2f733

work=$(realpath -m "${1:?usage: devtools-frontend.sh WORK_DIR DEST_DIR}")
dest=$(realpath -m "${2:?usage: devtools-frontend.sh WORK_DIR DEST_DIR}")

mkdir -p "$work"
cd "$work"
[ -d depot_tools ] || git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
PATH="$work/depot_tools:$PATH"
DEPOT_TOOLS_METRICS=0
export PATH DEPOT_TOOLS_METRICS
(cd depot_tools && ./ensure_bootstrap)

[ -f .gclient ] || fetch --nohooks devtools-frontend
cd devtools-frontend
git fetch origin "$REVISION"
git checkout --detach "$REVISION"
gclient sync
gn gen out/Release --args='is_debug=false'
autoninja -C out/Release

rm -rf "$dest"
mkdir -p "$dest"
python3 - out/Release/gen "$dest" <<'PY'
import json, os, shutil, sys
gen, dest = sys.argv[1], sys.argv[2]
for name in json.load(open(os.path.join(gen, 'expected_grd_files.json'))):
    target = os.path.join(dest, os.path.relpath(name, 'front_end'))
    os.makedirs(os.path.dirname(target), exist_ok=True)
    shutil.copy2(os.path.join(gen, name), target)
PY
