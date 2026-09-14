"""Copy the reachable Godot map assets into an isolated, namespaced workbench.

Run once against an external export. Refuses to overwrite an existing map.
Import settings are preserved; generated caches and source Git history are not.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil

TEXT = {'.tscn', '.tres', '.gd', '.gdshader', '.gdshaderinc', '.import'}
PREFIX = 'res://maps/construction/'
REF = re.compile(r'res:///?([^"\s)]+)')


def collect(source, extra_roots=()):
    pending = ['Construction-Site.tscn', *extra_roots]
    found = set()
    while pending:
        name = pending.pop()
        if name in found:
            continue
        path = source / name
        if not path.is_file() or not path.resolve().is_relative_to(source.resolve()):
            raise ValueError(f'Missing or invalid dependency: {name}')
        found.add(name)
        if path.suffix in TEXT:
            pending.extend(REF.findall(path.read_text(encoding='utf-8-sig')))
    return sorted(found)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--copy', action='store_true')
    parser.add_argument('--extra-root', action='append', default=[])
    parser.add_argument('--extend', action='store_true', help='Copy missing dependencies only; preserve edited destination files')
    args = parser.parse_args()
    files = collect(args.source, args.extra_root)
    print(json.dumps({'files': len(files), 'bytes': sum((args.source / f).stat().st_size for f in files)}))
    if not args.copy:
        return
    workbench = Path(__file__).resolve().parents[1] / 'godot/worldbuilding/construction'
    target = workbench / 'maps/construction'
    if target.exists() and not args.extend:
        raise SystemExit(f'Refusing to overwrite {target}')
    manifest_path = workbench / 'source_manifest.json'
    records = json.loads(manifest_path.read_text(encoding='utf-8'))['files'] if args.extend else []
    recorded = {record['path'] for record in records}
    for name in files:
        src = args.source / name
        dst = target / name
        if dst.exists() and name in recorded:
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        if src.suffix in TEXT:
            text = src.read_text(encoding='utf-8-sig')
            text = REF.sub(lambda m: PREFIX + m[1], text)
            # Copies get independent resource identities, resolved by stable paths.
            text = re.sub(r' uid="uid://[^"]+"', '', text)
            dst.write_text(text, encoding='utf-8', newline='\n')
        else:
            shutil.copy2(src, dst)
        metadata = Path(str(src) + '.import')
        if metadata.exists():
            text = metadata.read_text(encoding='utf-8-sig')
            text = text.replace('res:///' + name, PREFIX + name).replace('res://' + name, PREFIX + name)
            # Godot rebuilds cache destination paths on its first import.
            Path(str(dst) + '.import').write_text(text, encoding='utf-8', newline='\n')
        if name not in recorded:
            with src.open('rb') as stream:
                source_hash = hashlib.file_digest(stream, 'sha256').hexdigest()
            records.append({'path': name, 'bytes': src.stat().st_size,
                            'source_sha256': source_hash})
    (workbench / 'source_manifest.json').write_text(json.dumps({
        'source': str(args.source), 'namespace': PREFIX,
        'license': 'User-provided assets; upstream asset license not supplied in export.',
        'files': records}, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
