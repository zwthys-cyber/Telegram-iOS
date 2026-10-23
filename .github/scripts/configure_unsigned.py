"""Require personal Telegram API credentials for an installable client build."""
import json
import os
from pathlib import Path

config = json.loads(Path('build-system/appstore-configuration.json').read_text())
api_id, api_hash = os.getenv('TELEGRAM_API_ID'), os.getenv('TELEGRAM_API_HASH')
if not api_id or not api_hash:
    raise SystemExit('Set both TELEGRAM_API_ID and TELEGRAM_API_HASH in repository Actions secrets. Obtain them for your own app at https://my.telegram.org/apps. Upstream example credentials are not used for personal builds.')
if not api_id.isdecimal() or int(api_id) <= 0 or len(api_hash) != 32 or any(c not in '0123456789abcdefABCDEF' for c in api_hash):
    raise SystemExit('Invalid Telegram API credentials.')
if api_id in {'1', '8'}:
    raise SystemExit('Use the API credentials issued to your own application, rather than the official/example app IDs.')
config.update(api_id=api_id, api_hash=api_hash)
print('Using personal Telegram API configuration.')
config.update(sg_config='', is_appstore_build='false', enable_siri=False, enable_icloud=False)
Path('build').mkdir(exist_ok=True)
Path('build/unsigned-configuration.json').write_text(json.dumps(config))
