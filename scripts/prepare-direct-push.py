#!/usr/bin/env python3
"""Prepare a Developer ID app for APNs before its final codesign pass."""
import argparse
import datetime
import pathlib
import plistlib
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('app', type=pathlib.Path)
parser.add_argument('profile', type=pathlib.Path)
parser.add_argument('base_entitlements', type=pathlib.Path)
parser.add_argument('output_entitlements', type=pathlib.Path)
args = parser.parse_args()
profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(args.profile)]))
allowed = profile['Entitlements']
expected = 'UD7WB2694V.com.slipreel.app'
if allowed.get('com.apple.application-identifier') != expected:
    raise SystemExit('Push profile does not match the Slipreel direct edition')
if allowed.get('com.apple.developer.aps-environment') != 'production':
    raise SystemExit('Developer ID push requires a production APNs profile')
if profile['ExpirationDate'] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
    raise SystemExit('Push provisioning profile has expired')
with (args.app / 'Contents/Info.plist').open('rb') as file:
    if plistlib.load(file)['CFBundleIdentifier'] != 'com.slipreel.app':
        raise SystemExit('Expected the direct edition app bundle')
with args.base_entitlements.open('rb') as file:
    entitlements = plistlib.load(file)
for key in ['com.apple.application-identifier', 'com.apple.developer.team-identifier', 'com.apple.developer.aps-environment']:
    entitlements[key] = allowed[key]
args.output_entitlements.write_bytes(plistlib.dumps(entitlements))
shutil.copyfile(args.profile, args.app / 'Contents/embedded.provisionprofile')
