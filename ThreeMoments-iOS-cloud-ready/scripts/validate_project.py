"""Cross-platform project wiring checks. This does not compile Swift or run XCTest."""
from pathlib import Path
import json
import plistlib
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
TOKEN = re.compile(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+', re.S)


def openstep(text):
    tokens = [t for t in TOKEN.findall(text) if not t.startswith(('/*', '//'))]
    cursor = 0

    def take(expected=None):
        nonlocal cursor
        if cursor >= len(tokens):
            raise ValueError('Unexpected end of project file')
        token = tokens[cursor]
        cursor += 1
        if expected is not None and token != expected:
            raise ValueError(f'Expected {expected!r}, got {token!r}')
        return token

    def value():
        token = take()
        if token == '{':
            result = {}
            while tokens[cursor] != '}':
                key = take()
                key = json.loads(key) if key.startswith('"') else key
                take('=')
                if key in result:
                    raise ValueError(f'Duplicate project key {key}')
                result[key] = value()
                take(';')
            take('}')
            return result
        if token == '(':
            result = []
            while tokens[cursor] != ')':
                result.append(value())
                if tokens[cursor] == ',':
                    take(',')
                elif tokens[cursor] != ')':
                    raise ValueError('Missing list separator')
            take(')')
            return result
        return json.loads(token) if token.startswith('"') else token

    result = value()
    if cursor != len(tokens):
        raise ValueError('Trailing project tokens')
    return result


def main():
    project = openstep((ROOT / 'ThreeMoments.xcodeproj/project.pbxproj').read_text(encoding='utf-8-sig'))
    objects = project['objects']
    assert project['rootObject'] in objects
    file_paths = {}

    def walk(reference, directory):
        node = objects[reference]
        if node.get('sourceTree') == 'BUILT_PRODUCTS_DIR':
            return
        path = directory / node.get('path', '')
        if node['isa'] == 'PBXGroup':
            for child in node.get('children', []):
                walk(child, path)
        elif node['isa'] == 'PBXFileReference':
            assert path.exists(), f'Missing referenced file: {path}'
            file_paths[reference] = path.resolve()

    walk(objects[project['rootObject']]['mainGroup'], ROOT)
    sources = set()
    targets = {}
    for identifier, node in objects.items():
        if node.get('isa') != 'PBXNativeTarget':
            continue
        target_sources = set()
        for phase_id in node['buildPhases']:
            phase = objects[phase_id]
            if phase['isa'] == 'PBXSourcesBuildPhase':
                for build_id in phase['files']:
                    target_sources.add(file_paths[objects[build_id]['fileRef']])
        targets[node['name']] = (identifier, target_sources)
        sources |= target_sources
    actual_app = {p.resolve() for p in (ROOT / 'ThreeMoments').rglob('*.swift')}
    actual_tests = {p.resolve() for p in (ROOT / 'ThreeMomentsTests').rglob('*.swift')}
    assert targets['ThreeMoments'][1] == actual_app, 'App source membership does not match files'
    assert targets['ThreeMomentsTests'][1] == actual_tests and actual_tests, 'XCTest source membership is incomplete'

    scheme = ET.parse(ROOT / 'ThreeMoments.xcodeproj/xcshareddata/xcschemes/ThreeMoments.xcscheme')
    for reference in scheme.findall('.//BuildableReference'):
        assert reference.attrib['BlueprintIdentifier'] in objects
    assert scheme.find('.//TestableReference').attrib.get('skipped') == 'NO'
    ET.parse(ROOT / 'ThreeMoments.xcodeproj/project.xcworkspace/contents.xcworkspacedata')

    with (ROOT / 'ThreeMoments/Resources/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    for permission in ['NSMicrophoneUsageDescription', 'NSSpeechRecognitionUsageDescription']:
        assert info.get(permission), f'Missing permission description: {permission}'
    assert 'com.threemoments.diary.backup' in info['BGTaskSchedulerPermittedIdentifiers']
    assert 'fetch' in info['UIBackgroundModes']
    assert info['CFBundleIdentifier'] == '$(PRODUCT_BUNDLE_IDENTIFIER)'
    for path in (ROOT / 'ThreeMoments/Resources').rglob('*.json'):
        json.loads(path.read_text(encoding='utf-8-sig'))
    for node in objects.values():
        if node.get('isa') == 'XCBuildConfiguration':
            settings = node.get('buildSettings', {})
            if 'IPHONEOS_DEPLOYMENT_TARGET' in settings:
                assert float(settings['IPHONEOS_DEPLOYMENT_TARGET']) >= 17
    assert sum('@main' in p.read_text(encoding='utf-8') for p in actual_app) == 1
    print(f'PASS: project graph, {len(actual_app)} app sources, {len(actual_tests)} test sources, scheme, permissions, background registration, assets.')
    print('NOT RUN: Swift compilation, simulator, signing, microphone, Speech, notifications, Files/iCloud, device recovery.')


if __name__ == '__main__':
    main()
