#!/usr/bin/env python3
"""Generate a Redfish route inventory from literal bmcweb route declarations."""
import argparse
import re
import sys
import tempfile
import time
from pathlib import Path

import yaml

# Keep adjacent C++ string literals, which are common in long route names.
ROUTE = re.compile(r'\bBMCWEB_ROUTE\s*\(\s*\w+\s*,\s*((?:"[^"]*"\s*)+)\)([^;]*)', re.S)
COMMENT_OR_STRING = re.compile(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*.*?\*/', re.S)


def generate(files):
    paths = {}
    for file in files:
        source = COMMENT_OR_STRING.sub(
            lambda m: m[0] if m[0].startswith('"') else ' ', file.read_text())
        for literals, chain in ROUTE.findall(source):
            uri = ''.join(re.findall(r'"([^"]*)"', literals))
            if not uri.startswith('/redfish/v1'):
                continue
            parameters = []

            def parameter(match):
                name = f'param{len(parameters) + 1}'
                kind = {'int': 'integer', 'uint': 'integer', 'double': 'number'}
                parameters.append(dict(name=name, required=True,
                                       schema={'type': kind.get(match[1], 'string')},
                                       **{'in': 'path'}))
                return '{' + name + '}'

            path = re.sub(r'<(\w+)>', parameter, uri.rstrip('/'))
            methods = re.search(r'\.methods\s*\(([^)]*)\)', chain)
            verbs = re.findall(r'verb::(\w+)', methods[1]) if methods else ['get']
            item = paths.setdefault(path, {})
            if parameters:
                item['parameters'] = parameters
            for verb in verbs:
                item[verb.rstrip('_')] = {'responses': {'default': {'description': 'Service response'}}}
    if not paths:
        raise ValueError('No literal Redfish v1 routes found')
    return {'openapi': '3.0.3', 'info': {'title': 'bmcweb Redfish routes', 'version': 'working-tree'},
            'paths': paths}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path('bmcweb'), help='bmcweb checkout')
    parser.add_argument('-o', '--output', type=Path, default=Path('openapi.yaml'))
    parser.add_argument('--watch', action='store_true', help='refresh after source edits')
    args = parser.parse_args()
    previous = None
    while True:
        files = sorted(p for tree in ('redfish-core', 'features')
                       for p in (args.source / tree).rglob('*') if p.suffix in ('.hpp', '.cpp'))
        snapshot = [(p, p.stat().st_mtime_ns) for p in files]
        if snapshot != previous:
            document = generate(files)
            with tempfile.NamedTemporaryFile('w', dir=args.output.parent, delete=False) as out:
                yaml.safe_dump(document, out, sort_keys=False)
            Path(out.name).replace(args.output)
            print(f"Wrote {len(document['paths'])} paths to {args.output}", flush=True)
            previous = snapshot
        if not args.watch:
            return
        time.sleep(1)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        pass
    except (ValueError, OSError) as error:
        sys.exit(str(error))
