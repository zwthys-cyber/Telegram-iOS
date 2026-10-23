"""Strip signatures, check device platform/architecture, and package for later signing."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import zipfile


def output(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def version(value):
    parts = [int(p) for p in value.split('.')]
    return tuple((parts + [0, 0, 0])[:3])


source = Path('bazel-bin/Telegram/Swiftgram.ipa').resolve(strict=True)
artifacts = Path('build/artifacts').resolve()
artifacts.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    subprocess.run(['ditto', '-x', '-k', str(source), str(root)], check=True)
    apps = list((root / 'Payload').glob('*.app'))
    if len(apps) != 1:
        raise SystemExit('Expected exactly one main application.')
    app = apps[0]
    plist = plistlib.loads((app / 'Info.plist').read_bytes())
    if plist.get('SGLocalProFeaturesEnabled') is not True:
        raise SystemExit('Local Pro feature build flag is missing from the application.')
    if version(plist['MinimumOSVersion']) > version('26.6'):
        raise SystemExit('Minimum OS exceeds requested iOS 26.6.')
    if 'iPhoneOS' not in plist.get('CFBundleSupportedPlatforms', []):
        raise SystemExit('Not an iPhone device build.')
    alternate_icons = plist.get('CFBundleIcons', {}).get('CFBundleAlternateIcons', {})
    required_icons = {'SGDefault', 'SGBlack', 'SGLegacy', 'SGInverted', 'SGWhite', 'SGNight', 'SGSky', 'SGTitanium', 'SGNeon', 'SGNeonBlue', 'SGGlass', 'SGSparkling', 'SGBeta', 'SGPro', 'SGGold', 'SGDucky', 'SGDay'}
    if not required_icons.issubset(alternate_icons):
        raise SystemExit(f'Missing bundled alternate icons: {required_icons - alternate_icons.keys()}')
    if not (app / plist['CFBundleExecutable']).is_file():
        raise SystemExit('Missing main executable.')
    # Removing signatures from every Mach-O also handles nested extensions/frameworks.
    machos = []
    magics = {bytes.fromhex(h) for h in ['feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca']}
    for path in app.rglob('*'):
        if not path.is_file() or path.is_symlink():
            continue
        if path.name == 'embedded.mobileprovision':
            path.unlink()
            continue
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic not in magics:
            continue
        loads = output('otool', '-l', str(path))
        if 'LC_CODE_SIGNATURE' in loads:
            subprocess.run(['codesign', '--remove-signature', str(path)], check=True, capture_output=True)
            loads = output('otool', '-l', str(path))
        if 'LC_CODE_SIGNATURE' in loads:
            raise SystemExit(f'Signature remains in {path}')
        archs = output('lipo', '-archs', str(path)).split()
        if 'arm64' not in archs:
            raise SystemExit(f'Missing arm64: {path}')
        platforms = re.findall(r'^\s*platform\s+(\S+)', loads, re.M)
        legacy_ios = 'LC_VERSION_MIN_IPHONEOS' in loads and 'LC_VERSION_MIN_MACOSX' not in loads
        if (not platforms and not legacy_ios) or any(p not in ('2', 'IOS') for p in platforms):
            raise SystemExit(f'Expected iOS device platform: {path}: {platforms}')
        machos.append({'path': str(path.relative_to(root)), 'architectures': archs})
    import shutil
    for path in sorted(app.rglob('_CodeSignature'), reverse=True):
        if path.is_dir():
            shutil.rmtree(path)
    if not machos:
        raise SystemExit('No Mach-O binaries found.')
    destination = artifacts / 'Swiftgram-unsigned.ipa'
    subprocess.run(['ditto', '-c', '-k', '--keepParent', str(root / 'Payload'), str(destination)], check=True)
    with zipfile.ZipFile(destination) as archive:
        if archive.testzip() is not None:
            raise SystemExit('IPA ZIP CRC verification failed.')
    with destination.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    report = dict(bundle_id=plist['CFBundleIdentifier'], minimum_ios=plist['MinimumOSVersion'],
                  target_ios='26.6', signed=False, local_pro_features=plist['SGLocalProFeaturesEnabled'], sha256=digest, binaries=machos,
                  commit=os.getenv('GITHUB_SHA'), runtime_tested=False,
                  alternate_icons=alternate_icons)
    (artifacts / 'verification.json').write_text(json.dumps(report, indent=2))
    (artifacts / 'SHA256SUMS.txt').write_text(f'{digest}  {destination.name}\n')
    print(f'Verified {len(machos)} unsigned device binaries. SHA256: {digest}')
