"""Re-sign the original IPA without injecting code or adding scene support."""
import pathlib, plistlib, shutil, subprocess, zipfile
src=pathlib.Path('/Users/sehindhemzani/Downloads/com.google.ios.youtube_21.39.4_und3fined.ipa')
root=pathlib.Path('/tmp/youtube-native-fresh-baseline')
root.mkdir(exist_ok=True)
with zipfile.ZipFile(src) as z:
    for entry in z.infolist():
        assert (root/entry.filename).resolve().is_relative_to(root.resolve())
    z.extractall(root)
app=root/'Payload/YouTube.app'
profile=pathlib.Path('/tmp/youtube-native-fresh-signing/build/Debug-iphoneos/SigningTest.app/embedded.mobileprovision')
d=plistlib.loads(subprocess.check_output(['security','cms','-D','-i',str(profile)]))
e=dict(d['Entitlements']); bundle='com.sedki.youtube.nativecarplay'
assert e['application-identifier'].endswith('.*') or e['application-identifier'].endswith('.'+bundle)
e['application-identifier']=d['ApplicationIdentifierPrefix'][0]+'.'+bundle
e['keychain-access-groups']=[e['application-identifier']]
info=plistlib.loads((app/'Info.plist').read_bytes())
assert 'UIApplicationSceneManifest' not in info
info['CFBundleIdentifier']=bundle
info['CFBundleDisplayName']='YouTube Fresh'
info['CFBundleName']='YouTube Fresh'
(app/'Info.plist').write_bytes(plistlib.dumps(info))
for path in app.glob('*.lproj/InfoPlist.strings'):
    try: localized=plistlib.loads(path.read_bytes())
    except Exception: continue
    localized['CFBundleDisplayName']='YouTube Fresh'
    localized['CFBundleName']='YouTube Fresh'
    path.write_bytes(plistlib.dumps(localized))
for name in ('PlugIns','Extensions','Watch','_CodeSignature','SC_Info'):
    shutil.rmtree(app/name,ignore_errors=True)
(app/info['CFBundleExecutable']).chmod(0o755)
shutil.copy2(profile,app/'embedded.mobileprovision')
allowed=('application-identifier','com.apple.developer.team-identifier','get-task-allow','keychain-access-groups')
ent=root/'signing.plist';ent.write_bytes(plistlib.dumps({k:v for k,v in e.items() if k in allowed}))
identity='28E532567BCEBE27D73684B8165D5A075BE1023F'
for path in sorted((app/'Frameworks').rglob('*'),key=lambda p:len(p.parts),reverse=True):
    if path.suffix=='.dylib' or (path.is_dir() and path.suffix=='.framework'):
        subprocess.run(['codesign','--force','--sign',identity,str(path)],check=True)
subprocess.run(['codesign','--force','--sign',identity,'--entitlements',str(ent),str(app)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
print('Baseline app:',app)
print('CarPlay video authorized:',bool(e.get('com.apple.developer.carplay-video')))
