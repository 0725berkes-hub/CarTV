"""Build a separate, development-signed experimental native YouTube CarPlay IPA."""
import argparse, pathlib, plistlib, shutil, struct, subprocess, tempfile, zipfile

p = argparse.ArgumentParser()
p.add_argument('ipa', type=pathlib.Path)
p.add_argument('--profile', required=True, type=pathlib.Path)
p.add_argument('--identity', required=True)
p.add_argument('--output', required=True, type=pathlib.Path)
a = p.parse_args()
def run(*args):
    return subprocess.check_output(args)
profile = plistlib.loads(run('security', 'cms', '-D', '-i', str(a.profile)))
ent = profile['Entitlements']
assert ent.get('com.apple.developer.carplay-video'), 'Profile lacks CarPlay video'
assert profile.get('ProvisionedDevices'), 'Use a device development/ad hoc profile'
bundle_id = ent['application-identifier'].split('.', 1)[1]
assert bundle_id != 'kurdsoft.CarTV', 'Use a separate test identity to preserve CarTV'
with tempfile.TemporaryDirectory(prefix='youtube-carplay-') as tmp:
    root = pathlib.Path(tmp)
    with zipfile.ZipFile(a.ipa) as z:
        for info in z.infolist():
            dest = (root / info.filename).resolve()
            assert dest.is_relative_to(root.resolve()), 'Unsafe archive path'
        z.extractall(root)
    app = next((root / 'Payload').glob('*.app'))
    info_path = app / 'Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    original_id = info['CFBundleIdentifier']
    info['CFBundleIdentifier'] = bundle_id
    info['CFBundleDisplayName'] = 'YouTube CarPlay Test'
    info['CFBundleName'] = 'YouTube CarPlay Test'
    for localized in app.glob('*.lproj/InfoPlist.strings'):
        try:
            values = plistlib.loads(localized.read_bytes())
        except Exception:
            continue
        values['CFBundleDisplayName'] = 'YouTube CarPlay Test'
        values['CFBundleName'] = 'YouTube CarPlay Test'
        localized.write_bytes(plistlib.dumps(values))
    info['UIApplicationSceneManifest'] = {
        'UIApplicationSupportsMultipleScenes': True,
        'UISceneConfigurations': {
            'UIWindowSceneSessionRoleApplication': [{
                'UISceneConfigurationName': 'YouTube Phone',
                'UISceneDelegateClassName': 'YTCPPhoneSceneDelegate',
            }],
            'CPTemplateApplicationSceneSessionRoleApplication': [{
                'UISceneConfigurationName': 'YouTube CarPlay Experiment',
                'UISceneClassName': 'CPTemplateApplicationScene',
                'UISceneDelegateClassName': 'YTCPSceneDelegate',
            }]
        }
    }
    info_path.write_bytes(plistlib.dumps(info))
    # Extensions have Google's signing identities and cannot use this app's profile.
    for name in ('PlugIns', 'Extensions', 'Watch', '_CodeSignature', 'SC_Info'):
        path = app / name
        if path.is_dir(): shutil.rmtree(path)
    frameworks = app / 'Frameworks'; frameworks.mkdir(exist_ok=True)
    lib = frameworks / 'YouTubeCarPlay.dylib'
    src = pathlib.Path(__file__).with_name('YouTubeCarPlay.m')
    run('xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64', '-miphoneos-version-min=17.0', '-fobjc-arc', '-dynamiclib', '-framework', 'UIKit', '-framework', 'CarPlay', '-framework', 'Foundation', '-install_name', '@executable_path/Frameworks/YouTubeCarPlay.dylib', str(src), '-o', str(lib))
    binary = app / info['CFBundleExecutable']
    data = bytearray(binary.read_bytes())
    assert data[:4] == b'\xcf\xfa\xed\xfe', 'Expected thin arm64 Mach-O'
    ncmds, sizeofcmds = struct.unpack_from('<II', data, 16)
    offset = 32; first_section = len(data)
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', data, offset)
        if cmd in (0x21, 0x2c):
            assert struct.unpack_from('<I', data, offset + 16)[0] == 0, 'Encrypted executable'
        if cmd == 0x19:  # LC_SEGMENT_64: locate file-backed sections
            count = struct.unpack_from('<I', data, offset + 64)[0]
            for index in range(count):
                section = offset + 72 + index * 80
                section_offset = struct.unpack_from('<I', data, section + 48)[0]
                if section_offset: first_section = min(first_section, section_offset)
        offset += size
    name = b'@executable_path/Frameworks/YouTubeCarPlay.dylib\0'
    size = (24 + len(name) + 7) & ~7
    assert offset == 32 + sizeofcmds
    assert offset + size <= first_section, 'No load-command padding; refusing unsafe patch'
    assert not any(data[offset:offset + size]), 'Load-command padding is not empty'
    command = struct.pack('<IIIIII', 0xc, size, 24, 0, 0, 0) + name
    data[offset:offset + size] = command.ljust(size, b'\0')
    struct.pack_into('<II', data, 16, ncmds + 1, sizeofcmds + size)
    binary.write_bytes(data); binary.chmod(0o755)
    shutil.copy2(a.profile, app / 'embedded.mobileprovision')
    sign_ent = {k: v for k, v in ent.items() if k in (
        'application-identifier', 'com.apple.developer.team-identifier',
        'get-task-allow', 'keychain-access-groups',
        'com.apple.developer.carplay-video', 'com.apple.developer.carplay-audio')}
    ent_file = root / 'signing.plist'; ent_file.write_bytes(plistlib.dumps(sign_ent))
    for path in sorted(frameworks.rglob('*'), key=lambda f: len(f.parts), reverse=True):
        if path.suffix == '.dylib' or (path.is_dir() and path.suffix == '.framework'):
            run('codesign', '--force', '--sign', a.identity, str(path))
    run('codesign', '--force', '--sign', a.identity, '--entitlements', str(ent_file), str(app))
    run('codesign', '--verify', '--deep', '--strict', str(app))
    a.output.parent.mkdir(parents=True, exist_ok=True)
    # ditto preserves executable permissions and framework symlinks.
    run('ditto', '-c', '-k', '--keepParent', str(root / 'Payload'), str(a.output))
    print('Created:', a.output)
    print('Original identity:', original_id, 'Test identity:', bundle_id)
    print('Devices in profile:', len(profile['ProvisionedDevices']))
