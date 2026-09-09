#!/usr/bin/env python3
"""Inventory missing public DMGs and optionally stage original signed releases.

No upload or deletion. Run from the repository root with authenticated gh.
The app's checked-in Sparkle public key verifies each downloaded artifact.
"""
import argparse
import json
import pathlib
import plistlib
import re
import subprocess
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET


def run(args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', help='Only this MAJOR.MINOR.PATCH release')
    parser.add_argument('--download', action='store_true', help='Stage missing originals after signature verification')
    parser.add_argument('--output', required=True, type=pathlib.Path, help='Local staging/report directory')
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent.parent
    if args.version and not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
        parser.error('invalid version')
    args.output.mkdir(parents=True, exist_ok=True)
    feed = run(['curl', '--fail', '--silent', '--show-error', '--max-time', '30', 'https://slipreel.app/appcast.xml'])
    ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
    with (root / 'packages/screen_recorder/macos/Runner/Info.plist').open('rb') as f:
        key = plistlib.load(f)['SUPublicEDKey']
    report = []
    for item in ET.fromstring(feed).findall('./channel/item'):
        version = item.findtext(ns + 'shortVersionString')
        enclosure = item.find('enclosure')
        if not version or not re.fullmatch(r'\d+\.\d+\.\d+', version) or enclosure is None:
            continue
        if args.version and version != args.version:
            continue
        url = enclosure.attrib['url']
        parsed = urllib.parse.urlparse(url)
        filename = f'Slipreel-{version}.dmg'
        if parsed.scheme != 'https' or parsed.netloc != 'slipreel.app' or parsed.path != f'/download/{filename}' or parsed.query:
            raise ValueError('Unexpected archive URL')
        status = run(['curl', '--silent', '--show-error', '--head', '--max-time', '20', '--output', '/dev/null', '--write-out', '%{http_code}', url])
        row = {'version': version, 'url': url, 'http_status': status, 'verified_local_file': None}
        if status == '404' and args.download:
            # A temporary directory prevents unverified bytes looking publishable.
            with tempfile.TemporaryDirectory(prefix='.verify-', dir=args.output) as staging:
                subprocess.run(['gh', 'release', 'download', f'v{version}', '--pattern', filename, '--dir', staging], cwd=root, check=True)
                artifact = pathlib.Path(staging) / filename
                if artifact.stat().st_size != int(enclosure.attrib['length']):
                    raise ValueError(f'{version}: length differs from published appcast')
                verifier = """const fs=require('node:fs'),c=require('node:crypto');
const [file,key,sig]=process.argv.slice(1);
const pub=c.createPublicKey({key:Buffer.concat([Buffer.from('302a300506032b6570032100','hex'),Buffer.from(key,'base64')]),format:'der',type:'spki'});
if(!c.verify(null,fs.readFileSync(file),pub,Buffer.from(sig,'base64')))process.exit(1);"""
                subprocess.run(['node', '-e', verifier, str(artifact), key, enclosure.attrib[ns + 'edSignature']], check=True)
                destination = args.output / filename
                if destination.exists():
                    raise FileExistsError(f'Refusing to replace {destination}')
                artifact.rename(destination)
                row['verified_local_file'] = str(destination.resolve())
        report.append(row)
        print(json.dumps(row))
    (args.output / 'archive-inventory.json').write_text(json.dumps(report, indent=2) + '\n')
    if args.version and not report:
        raise ValueError('Version is absent from the public feed')


if __name__ == '__main__':
    main()
