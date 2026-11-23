#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:?usage: package-release.sh OUTPUT_DIRECTORY}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
name="$(racket -e '(require setup/getinfo) (display ((get-info/full (vector-ref (current-command-line-arguments) 0)) (quote name)))' "$root")"
version="$(racket -e '(require setup/getinfo) (display ((get-info/full (vector-ref (current-command-line-arguments) 0)) (quote version)))' "$root")"
mkdir "$stage/$name"
# Release content comes from the committed tree, never a developer's caches.
git -C "$root" archive HEAD | tar -x -C "$stage/$name"
raco pkg create --source --format zip --dest "$out" "$stage/$name"
mv "$out/$name.zip" "$out/$name-$version.zip"
mv "$out/$name.zip.CHECKSUM" "$out/$name-$version.zip.CHECKSUM"
python3 - "$root" "$out" "$name" "$version" <<'PY'
import hashlib, json, pathlib, subprocess, sys
root, output, name, version = sys.argv[1:]
out = pathlib.Path(output)
metadata = {"package": name, "version": version,
            "source_commit": subprocess.check_output(["git", "-C", root, "rev-parse", "HEAD"], text=True).strip(),
            "racket": subprocess.check_output(["racket", "--version"], text=True).strip(),
            "installation": "raco pkg install --copy --name " + name + " <verified-release-archive>"}
(out / "release.json").write_text(json.dumps(metadata, indent=2) + "\n")
paths = [out / (name + "-" + version + ".zip"), out / (name + "-" + version + ".zip.CHECKSUM"), out / "release.json"]
(out / "SHA256SUMS").write_text("".join(hashlib.sha256(p.read_bytes()).hexdigest() + "  " + p.name + "\n" for p in paths))
PY
