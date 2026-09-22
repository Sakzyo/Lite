#!/usr/bin/env python3
import pathlib, plistlib, shutil, subprocess, sys
root = pathlib.Path(__file__).resolve().parents[1]
app = root/'dist/Lite.app'
contents = app/'Contents'
for part in ['MacOS', 'Frameworks', 'Resources']:
    (contents/part).mkdir(parents=True, exist_ok=True)
shutil.copy2(root/'.build/Lite', contents/'MacOS/Lite')
shutil.copy2(root/'resources/Info.plist', contents/'Info.plist')
framework = contents/'Frameworks/Chromium Embedded Framework.framework'
version = (root/'vendor/cef/include/cef_version.h').read_bytes()
marker = contents/'Resources/CEF-SDK.txt'
if framework.exists() and (not marker.exists() or marker.read_bytes() != version):
    shutil.rmtree(framework)
if not framework.exists():
    shutil.copytree(root/'vendor/cef/Release/Chromium Embedded Framework.framework', framework, symlinks=True)
marker.write_bytes(version)
for suffix, bundle in [('', ''), (' (Alerts)', '.alerts'), (' (GPU)', '.gpu'), (' (Plugin)', '.plugin'), (' (Renderer)', '.renderer')]:
    name = 'Lite Helper' + suffix
    helper = contents/'Frameworks'/f'{name}.app'/'Contents'
    (helper/'MacOS').mkdir(parents=True, exist_ok=True)
    shutil.copy2(root/'.build/LiteHelper', helper/'MacOS'/name)
    info = dict(CFBundleExecutable=name, CFBundleIdentifier='app.lite.browser.helper'+bundle, CFBundleName=name, CFBundlePackageType='APPL', CFBundleVersion='1', LSUIElement=True, LSMinimumSystemVersion='14.0')
    with (helper/'Info.plist').open('wb') as f:
        plistlib.dump(info, f)
    subprocess.run(['codesign', '--force', '--sign', '-', str(helper.parent)], check=True, capture_output=True)
for source in ['LICENSE.txt', 'CREDITS.html']:
    shutil.copy2(root/'vendor/cef'/source, contents/'Resources'/source)
shutil.copytree(root/'resources/ContentBlocking', contents/'Resources/ContentBlocking', dirs_exist_ok=True)
if (root/'resources/Lite.icns').exists():
    shutil.copy2(root/'resources/Lite.icns', contents/'Resources/Lite.icns')
subprocess.run([sys.executable, str(root/'script/test_package.py')], check=True)
subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True, capture_output=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print(app)
