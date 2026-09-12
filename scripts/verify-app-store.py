#!/usr/bin/env python3
"""Fail a store artifact that contains a direct updater or lacks sandbox signing."""
import argparse, pathlib, plistlib, subprocess
parser=argparse.ArgumentParser()
parser.add_argument("app")
parser.add_argument("--local-test",action="store_true",help="Allow ad-hoc signing for local structural inspection only")
args=parser.parse_args()
app=pathlib.Path(args.app).resolve()
def require(test,message):
    if not test: raise SystemExit(message)
def entitlements(path):
    result=subprocess.run(['codesign','-d','--entitlements',':-',str(path)],capture_output=True,check=True)
    return plistlib.loads(result.stdout)
require(app.is_dir(),'Missing app bundle')
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
require(info['CFBundleIdentifier']=='com.slipreel.store','Wrong bundle identifier')
require(not any(k.startswith('SU') for k in info),'Sparkle plist keys remain')
require('CFBundleURLTypes' not in info,'Direct checkout callback remains')
for path in app.rglob('*'):
    require(path.name.lower() != 'sparkle.framework' and 'auto_updater' not in path.name.lower(),'Updater code remains: '+str(path))
ent=entitlements(app)
require(ent.get('com.apple.security.app-sandbox') is True,'Sandbox is not enabled')
require(ent.get('com.apple.security.network.client') is True,'Network entitlement missing')
if not args.local_test:
    require((app/'Contents/embedded.provisionprofile').is_file(),'Missing App Store provisioning profile')
    require(ent.get('com.apple.developer.applesignin') == ['Default'],'Sign in with Apple entitlement missing')
    require(bool(ent.get('keychain-access-groups')),'Keychain access group missing')
    details=subprocess.run(['codesign','-dvv',str(app)],capture_output=True,check=True).stderr.decode()
    require('TeamIdentifier=UD7WB2694V' in details,'Wrong signing team')
    require('Authority=Apple Distribution:' in details or 'Authority=3rd Party Mac Developer Application:' in details,'App Store distribution signature required')
for helper in ('ffmpeg','ffprobe','whisper-cli'):
    path=app/'Contents/Helpers'/helper
    require(path.exists(),'Missing bundled helper '+helper)
    e=entitlements(path)
    require(e.get('com.apple.security.app-sandbox') is True and e.get('com.apple.security.inherit') is True,'Helper does not inherit sandbox: '+helper)
frameworks=list(app.glob('Contents/Frameworks/screen_recorder_macos.framework/Versions/A/screen_recorder_macos'))
require(bool(frameworks),'Native capture framework missing')
for framework in frameworks:
    output=subprocess.check_output(['strings','-a',str(framework)])
    for symbol in (b'CGSCopyCurrentCursorImage',b'CGSMainConnectionID',b'PrivateFrameworks/SkyLight',b'_windowResizeNorth'):
        require(symbol not in output,'Private cursor API remains: '+symbol.decode())
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
print('Store artifact structural checks passed. App Review, StoreKit sandbox and device acceptance are separate gates.')
