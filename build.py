#!/usr/bin/env python3
from pathlib import Path
import os,sys,subprocess,plistlib,shutil,tempfile
root=Path(__file__).resolve().parent
app=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else root/'build/找鸭 1.1.6.app'
if app.exists():raise SystemExit(f'目标已存在：{app}')
env=os.environ.copy();env['DEVELOPER_DIR']='/Applications/Xcode.app/Contents/Developer'
subprocess.run(['xcrun','swift','build','-c','release','--product','SMBSearch','--package-path',str(root)],env=env,check=True)
binpath=Path(subprocess.check_output(['xcrun','swift','build','-c','release','--show-bin-path','--package-path',str(root)],env=env,text=True).strip())/'SMBSearch'
app.parent.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='.findduck-oil-build-',dir=app.parent) as temp:
 stage=Path(temp)/app.name;(stage/'Contents/MacOS').mkdir(parents=True);(stage/'Contents/Resources').mkdir()
 info=plistlib.loads((root/'Info.plist').read_bytes());info.update(CFBundleShortVersionString='1.1.6',CFBundleVersion='44',CFBundleName='找鸭',CFBundleDisplayName='找鸭',LSMinimumSystemVersion='14.0')
 (stage/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
 shutil.copy2(binpath,stage/'Contents/MacOS/SMBSearch')
 for f in (root/'Assets').iterdir():
  if f.is_file():shutil.copy2(f,stage/'Contents/Resources'/f.name)
 shutil.copy2(root/'Vendor/OilFind/LICENSE',stage/'Contents/Resources/OilFind-LICENSE.txt')
 (stage/'Contents/Resources/THIRD-PARTY-NOTICES.txt').write_text('FindDuck local scanning, search and filesystem event updates are based on Oil Find (https://github.com/oil-oil/oil-find). Copyright (c) 2026 Lin Zhihuang. MIT License: see OilFind-LICENSE.txt. No proprietary Pro module is included.\n')
 subprocess.run(['codesign','--force','--deep','--sign',env.get('FINDDUCK_SIGN_IDENTITY','-'),str(stage)],check=True)
 subprocess.run(['codesign','--verify','--deep','--strict',str(stage)],check=True)
 os.rename(stage,app)
print(app)
