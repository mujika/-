#!/usr/bin/env python3
"""Hugging Face から RAVE の encoder / decoder の .pte を Models/ に取得する。

モデルとエクスポートスクリプトは CC BY-NC 4.0(非商用)。検証用途に限り、リポジトリにはコミットしない。

使い方:
    python3 scripts/fetch_models.py --list             # リポジトリのファイル一覧だけ表示
    python3 scripts/fetch_models.py                    # XNNPACK 版を取得
    python3 scripts/fetch_models.py --backend coreml   # Core ML 版を取得(比較用)
    python3 scripts/fetch_models.py --encoder path/in/repo.pte --decoder path/in/repo.pte

このスクリプトは作成時に Hugging Face へ接続できない環境で書かれたため、リポジトリ内の
実際のファイル名を確認できていない。そのため名前を決め打ちせず、ファイル一覧から
「.pte で、encoder / decoder とバックエンド名を含むもの」を探す。1つに絞れないときは
候補を表示して止まるので、--encoder / --decoder で指定すること。
"""
import argparse
import json
import pathlib
import shutil
import sys
import urllib.parse
import urllib.request

REPO = "anira-project/rave-magnetic-resonator-piano"
ROOT = pathlib.Path(__file__).resolve().parent.parent
MODELS = ROOT / "Models"
# 仕様確認用に一緒に取ってくるテキスト(export/ と tools/ のスクリプトなど)
REFERENCE_DIRS = ("export/", "tools/")
REFERENCE_SUFFIXES = (".py", ".md", ".txt", ".json", ".yaml", ".yml", ".sh")


def api(path):
    with urllib.request.urlopen(f"https://huggingface.co/api/models/{REPO}/{path}") as r:
        return json.load(r)


def download(repo_path, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    url = f"https://huggingface.co/{REPO}/resolve/main/{urllib.parse.quote(repo_path)}"
    print(f"  {repo_path} -> {dest.relative_to(ROOT)}")
    tmp = dest.with_suffix(dest.suffix + ".part")
    with urllib.request.urlopen(url) as r, open(tmp, "wb") as f:
        shutil.copyfileobj(r, f)
    tmp.replace(dest)


def pick(files, role, backend):
    candidates = [p for p in files
                  if p.lower().endswith(".pte") and role in p.lower() and backend in p.lower()]
    if len(candidates) == 1:
        return candidates[0]
    print(f"\n{role} の {backend} 版 .pte を1つに絞れません。候補: {candidates or 'なし'}", file=sys.stderr)
    print("--list でファイル一覧を確認し、--encoder / --decoder で指定してください。", file=sys.stderr)
    sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--list", action="store_true", help="ファイル一覧を表示して終了")
    parser.add_argument("--backend", default="xnnpack", help="ファイル名に含まれるバックエンド名(既定: xnnpack)")
    parser.add_argument("--encoder", help="encoder の .pte のリポジトリ内パス")
    parser.add_argument("--decoder", help="decoder の .pte のリポジトリ内パス")
    args = parser.parse_args()

    entries = api("tree/main?recursive=true")
    files = [e["path"] for e in entries if e.get("type") == "file"]
    sizes = {e["path"]: e.get("size", 0) for e in entries}

    print(f"{REPO} のファイル:")
    for p in files:
        print(f"  {sizes[p]:>12,}  {p}")
    if args.list:
        return

    backend = args.backend.lower()
    encoder = args.encoder or pick(files, "encoder", backend)
    decoder = args.decoder or pick(files, "decoder", backend)

    print("\nモデルを取得:")
    download(encoder, MODELS / f"rave_encoder_{backend}.pte")
    download(decoder, MODELS / f"rave_decoder_{backend}.pte")

    print("\n参照用スクリプトを取得:")
    for p in files:
        if p.startswith(REFERENCE_DIRS) and p.endswith(REFERENCE_SUFFIXES) or p == "README.md":
            download(p, MODELS / "reference" / p)

    print("\n完了。次は: cd MorphCore && swift test")


if __name__ == "__main__":
    main()
