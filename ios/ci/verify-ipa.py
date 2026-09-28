import plistlib
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    prefix = 'Payload/StudentHelper.app/'
    info = plistlib.loads(archive.read(prefix + 'Info.plist'))
    assert info['CFBundleIdentifier'] == 'com.studenthelper.yibu'
    assert info['CFBundleSupportedPlatforms'] == ['iPhoneOS']
    assert float(info['MinimumOSVersion']) >= 17.0
    binary = archive.read(prefix + info['CFBundleExecutable'])
    assert binary[:4] in [b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'], 'Missing Mach-O executable'
    assert prefix + 'Assets.car' in archive.namelist()
    assert prefix + 'WebMath/index.html' in archive.namelist()
    assert prefix + 'WebMath/katex/katex.min.js' in archive.namelist()
    assert prefix + '_CodeSignature/CodeResources' not in archive.namelist(), 'Expected unsigned package'
    assert archive.testzip() is None
    print('VERIFIED physical iPhone IPA:', info['CFBundleDisplayName'], info['MinimumOSVersion'], 'unsigned')
