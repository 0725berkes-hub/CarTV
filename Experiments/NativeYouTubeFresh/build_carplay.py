import pathlib,plistlib,shutil,struct,subprocess
root=pathlib.Path('/tmp/youtube-native-carplay')
shutil.copytree('/tmp/youtube-native-fresh-baseline/Payload',root/'Payload',dirs_exist_ok=True)
app=root/'Payload/YouTube.app';info_path=app/'Info.plist';info=plistlib.loads(info_path.read_bytes())
info['UIApplicationSceneManifest']={'UIApplicationSupportsMultipleScenes':True,'UISceneConfigurations':{
 'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'Native YouTube Phone','UISceneDelegateClassName':'YTSceneDelegate'}],
 'CPTemplateApplicationSceneSessionRoleApplication':[{'UISceneConfigurationName':'Native YouTube Templates','UISceneClassName':'CPTemplateApplicationScene','UISceneDelegateClassName':'NativeTemplateScene'}],
 'UIWindowSceneSessionRoleCarPlay':[{'UISceneConfigurationName':'Native YouTube Car Window','UISceneDelegateClassName':'NativeCarWindowScene'}],
 'UIWindowSceneSessionRoleExternalDisplayNonInteractive':[{'UISceneConfigurationName':'Native YouTube External Window','UISceneDelegateClassName':'NativeCarWindowScene'}]}}
info_path.write_bytes(plistlib.dumps(info))
source=pathlib.Path(__file__).with_name('NativeCarPlay.m');lib=app/'Frameworks/NativeCarPlay.dylib'
subprocess.run(['xcrun','--sdk','iphoneos','clang','-arch','arm64','-miphoneos-version-min=17.0','-fobjc-arc','-dynamiclib','-framework','UIKit','-framework','CarPlay','-framework','Foundation','-install_name','@executable_path/Frameworks/NativeCarPlay.dylib',str(source),'-o',str(lib)],check=True)
binary=app/info['CFBundleExecutable'];data=bytearray(binary.read_bytes());ncmds,sizeofcmds=struct.unpack_from('<II',data,16);off=32;first=len(data)
for _ in range(ncmds):
 cmd,size=struct.unpack_from('<II',data,off)
 if cmd==0x19:
  for i in range(struct.unpack_from('<I',data,off+64)[0]):
   start=struct.unpack_from('<I',data,off+72+i*80+48)[0]
   if start:first=min(first,start)
 off+=size
name=b'@executable_path/Frameworks/NativeCarPlay.dylib\0';size=(24+len(name)+7)&~7
assert off+size<=first and not any(data[off:off+size])
data[off:off+size]=(struct.pack('<IIIIII',0xc,size,24,0,0,0)+name).ljust(size,b'\0')
struct.pack_into('<II',data,16,ncmds+1,sizeofcmds+size);binary.write_bytes(data)
profile=pathlib.Path('/tmp/youtube-native-fresh-signing/build/Debug-iphoneos/SigningTest.app/embedded.mobileprovision')
p=plistlib.loads(subprocess.check_output(['security','cms','-D','-i',str(profile)]));e=p['Entitlements']
assert e['application-identifier'].endswith('.com.sedki.youtube.nativecarplay') and e.get('com.apple.developer.carplay-video')
shutil.copy2(profile,app/'embedded.mobileprovision')
allowed=('application-identifier','com.apple.developer.team-identifier','get-task-allow','keychain-access-groups','com.apple.developer.carplay-video')
ent=root/'signing.plist';ent.write_bytes(plistlib.dumps({k:v for k,v in e.items() if k in allowed}))
identity='28E532567BCEBE27D73684B8165D5A075BE1023F'
subprocess.run(['codesign','--force','--sign',identity,str(lib)],check=True)
subprocess.run(['codesign','--force','--sign',identity,'--entitlements',str(ent),str(app)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
print('CarPlay build ready:',app)
