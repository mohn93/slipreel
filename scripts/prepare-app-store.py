#!/usr/bin/env python3
"""Stage an isolated store source tree; never mutate the direct build in place."""
import argparse, pathlib, plistlib, subprocess, re
parser=argparse.ArgumentParser()
parser.add_argument('destination',type=pathlib.Path)
parser.add_argument('--profile',help='Installed Mac App Store distribution profile name or UUID')
args=parser.parse_args()
root=pathlib.Path(__file__).resolve().parents[1]
dest=args.destination.resolve()
if dest.exists(): raise SystemExit('Destination must be a new directory')
if root in dest.parents: raise SystemExit('Stage outside the source tree')
dest.mkdir(parents=True)
subprocess.run(['rsync','-a',*[f'--exclude={p}' for p in ['.git','.dart_tool','build','dist','node_modules','Pods','.symlinks','ephemeral','pubspec_overrides.yaml','.env*']],str(root)+'/',str(dest)+'/'],check=True)
app=dest/'packages/screen_recorder'
p=app/'pubspec.yaml'
p.write_text(re.sub(r'^  auto_updater:.*\n','',p.read_text(),flags=re.M))
p=app/'macos/Runner/Configs/AppInfo.xcconfig'
s=p.read_text().replace('PRODUCT_BUNDLE_IDENTIFIER = com.slipreel.app','PRODUCT_BUNDLE_IDENTIFIER = com.slipreel.store').replace('PRODUCT_NAME = Slipreel','PRODUCT_NAME = SlipreelStore')
p.write_text(s)
p=app/'macos/Runner/Info.plist'
with p.open('rb') as f: info=plistlib.load(f)
for key in list(info):
    if key.startswith('SU') or key=='CFBundleURLTypes': del info[key]
info['LSApplicationCategoryType']='public.app-category.video'
with p.open('wb') as f: plistlib.dump(info,f)
# All configurations use sandbox entitlements and a native compile-time flag.
p=app/'macos/Runner.xcodeproj/project.pbxproj'
s=p.read_text().replace('Runner/DebugProfile.entitlements','Runner/Store/AppStore.entitlements').replace('Runner/Release.entitlements','Runner/Store/AppStore.entitlements')
s=s.replace('SWIFT_VERSION = 5.0;', 'SWIFT_VERSION = 5.0;\n\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) APP_STORE";\n\t\t\t\tSLIPREEL_APP_STORE = 1;')
s=s.replace('CODE_SIGN_IDENTITY = "Developer ID Application";', 'CODE_SIGN_IDENTITY = "Apple Distribution";')
if args.profile:
    if not re.fullmatch(r'[A-Za-z0-9 _.-]+',args.profile): raise SystemExit('Invalid profile name')
    s=s.replace('PROVISIONING_PROFILE_SPECIFIER = "";', 'PROVISIONING_PROFILE_SPECIFIER = "'+args.profile+'";')
p.write_text(s)
p=app/'macos/Podfile'
s=p.read_text().replace('    flutter_additional_macos_build_settings(target)', '''    flutter_additional_macos_build_settings(target)
    target.build_configurations.each do |config|
      config.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '$(inherited) APP_STORE'
    end''')
p.write_text(s)
print(dest)
