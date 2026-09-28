"""Syntax/resources verification only; Xcode compilation is still required."""
from pathlib import Path
import json
import plistlib
import sys

root = Path(__file__).resolve().parent
sys.path.insert(0, str(root.parent / '.validation' / 'python'))
from tree_sitter import Language, Parser
import tree_sitter_swift
import yaml
from PIL import Image

parser = Parser(Language(tree_sitter_swift.language()))
failed = False
for source in sorted(list((root / 'StudentHelper').glob('*.swift')) + list((root / 'Tests').glob('*.swift'))):
    tree = parser.parse(source.read_bytes())
    errors = []
    def visit(node):
        if node.type == 'ERROR' or node.is_missing:
            errors.append((node.start_point, node.end_point, node.type))
        for child in node.children:
            visit(child)
    visit(tree.root_node)
    if errors:
        failed = True
        print(source.name, errors[:12])
    else:
        print('SYNTAX OK:', source.name)

project = yaml.safe_load((root / 'project.yml').read_text(encoding='utf-8-sig'))
assert project['targets']['StudentHelper']['platform'] == 'iOS'
assert project['options']['deploymentTarget']['iOS'] == '17.0'
with (root / 'StudentHelper' / 'Info.plist').open('rb') as file:
    info = plistlib.load(file)
assert info['NSAppTransportSecurity']['NSAllowsLocalNetworking'] is True
assert 'NSAllowsArbitraryLoads' not in info['NSAppTransportSecurity']
assets = root / 'StudentHelper' / 'Assets.xcassets' / 'AppIcon.appiconset'
manifest = json.loads((assets / 'Contents.json').read_text())
for item in manifest['images']:
    with Image.open(assets / item['filename']) as image:
        assert image.size == (1024, 1024)
print('RESOURCE OK: XcodeGen specification, Info.plist, local network exceptions, AppIcon')
print('NOT VERIFIED: Swift type checking, Xcode build, simulator or physical iPhone')
if failed:
    raise SystemExit(1)
