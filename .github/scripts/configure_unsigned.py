"""Use the upstream CI configuration; optional repository secrets replace API credentials."""
import json
import os
from pathlib import Path

config = json.loads(Path('build-system/appstore-configuration.json').read_text())
api_id, api_hash = os.getenv('TELEGRAM_API_ID'), os.getenv('TELEGRAM_API_HASH')
if bool(api_id) != bool(api_hash):
    raise SystemExit('Set TELEGRAM_API_ID and TELEGRAM_API_HASH together.')
if api_id:
    if not api_id.isdecimal() or len(api_hash) != 32 or any(c not in '0123456789abcdefABCDEF' for c in api_hash):
        raise SystemExit('Invalid Telegram API credentials.')
    config.update(api_id=api_id, api_hash=api_hash)
else:
    print('Using upstream public CI API configuration. Set your own TELEGRAM_API_ID and TELEGRAM_API_HASH for personal use.')
config.update(sg_config='', is_appstore_build='false', enable_siri=False, enable_icloud=False)
Path('build').mkdir(exist_ok=True)
Path('build/unsigned-configuration.json').write_text(json.dumps(config))
