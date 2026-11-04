import plistlib
import sys

with open(sys.argv[1], 'wb') as output:
    plistlib.dump({
        'CFBundleIdentifier': 'com.murphy.TranslateBar',
        'CFBundleName': 'TranslateBar',
        'CFBundleDisplayName': 'TranslateBar',
        'CFBundleExecutable': 'TranslateBar',
        'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '0.4.12',
        'CFBundleVersion': '29',
        'CFBundleIconFile': 'AppIcon',
        'LSMinimumSystemVersion': '14.4',
        'LSUIElement': True,
        'NSHighResolutionCapable': True,
        'NSAudioCaptureUsageDescription': '捕获你选择的浏览器或应用声音，发送给 OpenAI 并播放翻译语音。',
        'NSAccessibilityUsageDescription': '读取选中文本与当前输入框，在你触发翻译后显示或回填译文。',
        'NSInputMonitoringUsageDescription': '识别你选择的连续空格次数和全局翻译快捷键。',
        'NSHumanReadableCopyright': 'TranslateBar · 2026',
    }, output)
