#!/usr/bin/env python3
"""외부 도구 없이 동일 소스 목록에서 동일 Xcode 프로젝트를 생성한다.

새 Swift/Metal 파일을 추가한 뒤 실행한다. 테스트/빌드는 실행하지 않는다.
Bundle ID는 개발 후보이며 실제 Team, App Group, iCloud 등록을 대신하지 않는다.
"""
from pathlib import Path
import hashlib
import json
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
OBJECTS = {}
CONFIGURATIONS = ('Debug', 'Release')
MODULES = ('MirrorDomain', 'MirrorData', 'MirrorSystem', 'MirrorDesign')
UNIT_TESTS = ('MirrorDomainTests', 'MirrorDataTests', 'MirrorSystemTests')
LIBRARY_DEPENDENCIES = {
    'MirrorDomain': [], 'MirrorData': ['MirrorDomain'],
    'MirrorSystem': ['MirrorDomain', 'MirrorData'], 'MirrorDesign': [],
}
TARGETS = {
    **{name: {'kind': 'framework', 'path': f'Sources/{name}', 'deps': LIBRARY_DEPENDENCIES[name]}
       for name in MODULES},
    **{name: {'kind': 'unit-test', 'path': f'Tests/{name}', 'deps': list(MODULES[:index + 1])}
       for index, name in enumerate(UNIT_TESTS)},
    'MirrorIOS': {'kind': 'application', 'path': 'App', 'platform': 'ios', 'deps': list(MODULES),
                  'embedded': ['MirrorWidgetsIOS', 'MirrorShareIOS'], 'bundle': 'com.baserize.mirror'},
    'MirrorMac': {'kind': 'application', 'path': 'App', 'platform': 'macos', 'deps': list(MODULES),
                  'embedded': ['MirrorWidgetsMac', 'MirrorShareMac'], 'bundle': 'com.baserize.mirror.mac'},
    'MirrorWidgetsIOS': {'kind': 'app-extension', 'path': 'Extensions/Widgets', 'platform': 'ios',
                        'deps': ['MirrorDomain', 'MirrorData', 'MirrorSystem'],
                        'bundle': 'com.baserize.mirror.widgets', 'info': 'Widgets'},
    'MirrorWidgetsMac': {'kind': 'app-extension', 'path': 'Extensions/Widgets', 'platform': 'macos',
                        'deps': ['MirrorDomain', 'MirrorData', 'MirrorSystem'],
                        'bundle': 'com.baserize.mirror.mac.widgets', 'info': 'Widgets'},
    'MirrorShareIOS': {'kind': 'app-extension', 'path': 'Extensions/Share', 'platform': 'ios',
                      'deps': ['MirrorDomain', 'MirrorData', 'MirrorSystem'],
                      'bundle': 'com.baserize.mirror.share', 'info': 'Share'},
    'MirrorShareMac': {'kind': 'app-extension', 'path': 'Extensions/Share', 'platform': 'macos',
                      'deps': ['MirrorDomain', 'MirrorData', 'MirrorSystem'],
                      'bundle': 'com.baserize.mirror.mac.share', 'info': 'Share'},
    'MirrorIOSUITests': {'kind': 'ui-testing', 'path': 'Tests/MirrorUITests', 'platform': 'ios',
                         'deps': [], 'host': 'MirrorIOS'},
    'MirrorMacUITests': {'kind': 'ui-testing', 'path': 'Tests/MirrorUITests', 'platform': 'macos',
                         'deps': [], 'host': 'MirrorMac'},
}
TYPES = {'swift': 'sourcecode.swift', 'metal': 'sourcecode.metal', 'plist': 'text.plist.xml',
         'entitlements': 'text.plist.entitlements', 'xcprivacy': 'text.xml', 'json': 'text.json',
         'md': 'net.daringfireball.markdown', 'swiftpieces': 'text'}
PRODUCT_TYPES = {
    'framework': ('framework', 'wrapper.framework'), 'application': ('app', 'wrapper.application'),
    'app-extension': ('appex', 'wrapper.app-extension'),
    'unit-test': ('xctest', 'wrapper.cfbundle'), 'ui-testing': ('xctest', 'wrapper.cfbundle'),
}


def ref(label):
    return hashlib.sha1(label.encode()).hexdigest()[:24].upper()


def add(label, **values):
    identifier = ref(label)
    if identifier in OBJECTS:
        raise ValueError(f'중복 object label: {label}')
    OBJECTS[identifier] = values
    return identifier


def serialize(value, depth=0):
    indent = '\t' * depth
    child_indent = '\t' * (depth + 1)
    if isinstance(value, dict):
        lines = [f'{child_indent}{serialize(str(key))} = {serialize(item, depth + 1)};'
                 for key, item in value.items()]
        return '{\n' + '\n'.join(lines) + '\n' + indent + '}'
    if isinstance(value, list):
        return '(\n' + '\n'.join(child_indent + serialize(item, depth + 1) + ',' for item in value) + '\n' + indent + ')'
    if isinstance(value, int):
        return str(value)
    if re.fullmatch(r'[A-Za-z0-9_./]+', value):
        return value
    return json.dumps(value, ensure_ascii=False)


def file_reference(path):
    label = f'file:{path}'
    if ref(label) not in OBJECTS:
        add(label, isa='PBXFileReference', lastKnownFileType=TYPES.get(Path(path).suffix[1:], 'text'),
            name=Path(path).name, path=path, sourceTree='SOURCE_ROOT')
    return ref(label)


def discovered_sources(directory):
    return sorted(str(path.relative_to(ROOT)) for path in (ROOT / directory).rglob('*')
                  if path.is_file() and path.suffix in ('.swift', '.metal'))


def product_name(target):
    spec = TARGETS[target]
    name = 'Mirror' if spec['kind'] == 'application' else target
    suffix, _ = PRODUCT_TYPES[spec['kind']]
    return f'{name}.{suffix}'


source_directories = dict.fromkeys(spec['path'] for spec in TARGETS.values())
for path in source_directories:
    files = discovered_sources(path)
    add(f'group:{path}', isa='PBXGroup', children=[file_reference(file) for file in files],
        name=path, sourceTree='<group>')
configuration_files = sorted(str(path.relative_to(ROOT)) for path in (ROOT / 'Configuration').iterdir() if path.is_file())
add('group:configuration', isa='PBXGroup', children=[file_reference(path) for path in configuration_files],
    name='Configuration', sourceTree='<group>')
resource_files = ['Resources/PrivacyInfo.xcprivacy', 'Sources/MirrorDesign/SwiftPieces/LICENSE.swiftpieces',
                  'Sources/MirrorDesign/SwiftPieces/PROVENANCE.md', 'postpone-app-docs/fixtures/domain-cases.json']
add('group:resources', isa='PBXGroup', children=[file_reference(path) for path in resource_files],
    name='Resources / Fixture', sourceTree='<group>')
for target, spec in TARGETS.items():
    _, file_type = PRODUCT_TYPES[spec['kind']]
    add(f'{target}:product', isa='PBXFileReference', explicitFileType=file_type, includeInIndex=0,
        path=product_name(target), sourceTree='BUILT_PRODUCTS_DIR')
add('products:group', isa='PBXGroup', children=[ref(f'{name}:product') for name in TARGETS],
    name='Products', sourceTree='<group>')
add('main:group', isa='PBXGroup', children=[ref(f'group:{path}') for path in source_directories] +
    [ref('group:configuration'), ref('group:resources'), ref('products:group')], sourceTree='<group>')

common = {
    'ALWAYS_SEARCH_USER_PATHS': 'NO', 'CLANG_ENABLE_MODULES': 'YES', 'CLANG_ENABLE_OBJC_ARC': 'YES',
    'CLANG_WARN_DOCUMENTATION_COMMENTS': 'YES', 'ENABLE_USER_SCRIPT_SANDBOXING': 'YES',
    'GCC_C_LANGUAGE_STANDARD': 'gnu17', 'GCC_NO_COMMON_BLOCKS': 'YES',
    'SWIFT_VERSION': '6.0', 'SWIFT_STRICT_CONCURRENCY': 'complete',
    'SWIFT_DEFAULT_ACTOR_ISOLATION': 'nonisolated',
    'IPHONEOS_DEPLOYMENT_TARGET': '27.0', 'MACOSX_DEPLOYMENT_TARGET': '27.0',
}
for configuration in CONFIGURATIONS:
    debug = configuration == 'Debug'
    settings = dict(common, DEBUG_INFORMATION_FORMAT='dwarf' if debug else 'dwarf-with-dsym',
                    ENABLE_TESTABILITY='YES' if debug else 'NO', GCC_OPTIMIZATION_LEVEL='0' if debug else 's',
                    SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG $(inherited)' if debug else '$(inherited)',
                    SWIFT_COMPILATION_MODE='incremental' if debug else 'wholemodule',
                    SWIFT_OPTIMIZATION_LEVEL='-Onone' if debug else '-O')
    add(f'project:config:{configuration}', isa='XCBuildConfiguration', buildSettings=settings, name=configuration)
add('project:configs', isa='XCConfigurationList', buildConfigurations=[ref(f'project:config:{name}') for name in CONFIGURATIONS],
    defaultConfigurationIsVisible=0, defaultConfigurationName='Release')


def target_dependency(target, dependency):
    proxy = add(f'{target}:proxy:{dependency}', isa='PBXContainerItemProxy', containerPortal=ref('project'),
                proxyType=1, remoteGlobalIDString=ref(f'{dependency}:target'), remoteInfo=dependency)
    return add(f'{target}:dependency:{dependency}', isa='PBXTargetDependency',
               target=ref(f'{dependency}:target'), targetProxy=proxy)


for target, spec in TARGETS.items():
    kind = spec['kind']
    files = discovered_sources(spec['path'])
    sources = [add(f'{target}:source:{path}', isa='PBXBuildFile', fileRef=file_reference(path)) for path in files]
    add(f'{target}:sources', isa='PBXSourcesBuildPhase', buildActionMask=2147483647, files=sources,
        runOnlyForDeploymentPostprocessing=0)
    frameworks = [add(f'{target}:link:{dependency}', isa='PBXBuildFile', fileRef=ref(f'{dependency}:product'))
                  for dependency in spec['deps']]
    add(f'{target}:frameworks', isa='PBXFrameworksBuildPhase', buildActionMask=2147483647, files=frameworks,
        runOnlyForDeploymentPostprocessing=0)
    resources = []
    if kind in ('application', 'app-extension'):
        resources.append('Resources/PrivacyInfo.xcprivacy')
    if kind == 'application':
        resources.extend(['Sources/MirrorDesign/SwiftPieces/LICENSE.swiftpieces', 'Sources/MirrorDesign/SwiftPieces/PROVENANCE.md'])
    if target == 'MirrorDomainTests':
        resources.append('postpone-app-docs/fixtures/domain-cases.json')
    resource_builds = [add(f'{target}:resource:{path}', isa='PBXBuildFile', fileRef=file_reference(path)) for path in resources]
    add(f'{target}:resources', isa='PBXResourcesBuildPhase', buildActionMask=2147483647, files=resource_builds,
        runOnlyForDeploymentPostprocessing=0)
    dependencies = [target_dependency(target, dependency) for dependency in spec['deps']]
    phases = [ref(f'{target}:sources'), ref(f'{target}:frameworks'), ref(f'{target}:resources')]
    if embedded := spec.get('embedded'):
        copies = [add(f'{target}:embed:{extension}', isa='PBXBuildFile', fileRef=ref(f'{extension}:product'),
                      settings={'ATTRIBUTES': ['RemoveHeadersOnCopy']}) for extension in embedded]
        # Xcode가 플랫폼별 PlugIns 경로를 해석한다. unsigned CI에서 CodeSignOnCopy는 사용하지 않는다.
        phases.append(add(f'{target}:extensions', isa='PBXCopyFilesBuildPhase', buildActionMask=2147483647,
                          dstPath='', dstSubfolderSpec=13, files=copies, name='Embed App Extensions',
                          runOnlyForDeploymentPostprocessing=0))
        dependencies.extend(target_dependency(target, extension) for extension in embedded)
    if host := spec.get('host'):
        dependencies.append(target_dependency(target, host))
    settings = {
        'GENERATE_INFOPLIST_FILE': 'YES', 'PRODUCT_NAME': 'Mirror' if kind == 'application' else '$(TARGET_NAME)',
        'CURRENT_PROJECT_VERSION': '1', 'MARKETING_VERSION': '0.1.0',
        'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks'],
    }
    platform = spec.get('platform')
    if platform == 'ios':
        settings.update(SDKROOT='iphoneos', SUPPORTED_PLATFORMS='iphoneos iphonesimulator', TARGETED_DEVICE_FAMILY='1,2',
                        SUPPORTS_MACCATALYST='NO', SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD='NO')
    elif platform == 'macos':
        settings.update(SDKROOT='macosx', SUPPORTED_PLATFORMS='macosx', ENABLE_HARDENED_RUNTIME='YES')
    else:
        settings.update(SDKROOT='auto', SUPPORTED_PLATFORMS='iphoneos iphonesimulator macosx', TARGETED_DEVICE_FAMILY='1,2')
    if kind == 'application':
        settings.update(GENERATE_INFOPLIST_FILE='NO', INFOPLIST_FILE=f'Configuration/{target}-Info.plist',
                        CODE_SIGN_ENTITLEMENTS=f'Configuration/{target}.entitlements', PRODUCT_BUNDLE_IDENTIFIER=spec['bundle'])
    elif kind == 'app-extension':
        settings.update(GENERATE_INFOPLIST_FILE='NO', INFOPLIST_FILE=f'Configuration/{spec["info"]}-Info.plist',
                        CODE_SIGN_ENTITLEMENTS=f'Configuration/Extension{"IOS" if platform == "ios" else "Mac"}.entitlements',
                        PRODUCT_BUNDLE_IDENTIFIER=spec['bundle'], SKIP_INSTALL='YES', APPLICATION_EXTENSION_API_ONLY='YES')
        # App Intents/Widget extensions are Swift executables rather than dylibs.
        if spec['info'] == 'Widgets':
            settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
    elif kind == 'framework':
        settings.update(PRODUCT_BUNDLE_IDENTIFIER='com.baserize.mirror.' + target.removeprefix('Mirror').lower(),
                        SKIP_INSTALL='YES', MACH_O_TYPE='staticlib', DEFINES_MODULE='YES',
                        SWIFT_INSTALL_OBJC_HEADER='NO', APPLICATION_EXTENSION_API_ONLY='YES')
    else:
        settings.update(PRODUCT_BUNDLE_IDENTIFIER='com.baserize.mirror.tests.' + target.lower(), SKIP_INSTALL='YES')
        if kind == 'unit-test':
            settings.update(TEST_HOST='', BUNDLE_LOADER='')
        else:
            settings['TEST_TARGET_NAME'] = spec['host']
    for configuration in CONFIGURATIONS:
        add(f'{target}:config:{configuration}', isa='XCBuildConfiguration', buildSettings=dict(settings), name=configuration)
    add(f'{target}:configs', isa='XCConfigurationList', buildConfigurations=[ref(f'{target}:config:{name}') for name in CONFIGURATIONS],
        defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
    apple_kind = 'ui-testing' if kind == 'ui-testing' else 'unit-test' if kind == 'unit-test' else kind
    add(f'{target}:target', isa='PBXNativeTarget', buildConfigurationList=ref(f'{target}:configs'), buildPhases=phases,
        buildRules=[], dependencies=dependencies, name=target,
        productName='Mirror' if kind == 'application' else target,
        productReference=ref(f'{target}:product'), productType=f'com.apple.product-type.{"bundle." if "test" in apple_kind else ""}{apple_kind}')

attributes = {ref(f'{name}:target'): {'CreatedOnToolsVersion': '27.0', **(
    {'TestTargetID': ref(f'{spec["host"]}:target')} if spec.get('host') else {})} for name, spec in TARGETS.items()}
add('project', isa='PBXProject', attributes={'BuildIndependentTargetsInParallel': 'YES', 'LastSwiftUpdateCheck': '2700',
    'LastUpgradeCheck': '2700', 'TargetAttributes': attributes}, buildConfigurationList=ref('project:configs'),
    compatibilityVersion='Xcode 14.0', developmentRegion='ko', hasScannedForEncodings=0,
    knownRegions=['ko', 'en', 'Base'], mainGroup=ref('main:group'), productRefGroup=ref('products:group'),
    projectDirPath='', projectRoot='', targets=[ref(f'{name}:target') for name in TARGETS])

project_dir = ROOT / 'Mirror.xcodeproj'
project_dir.mkdir(exist_ok=True)
(project_dir / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + serialize({
    'archiveVersion': 1, 'classes': {}, 'objectVersion': 56, 'objects': OBJECTS, 'rootObject': ref('project')}) + '\n')
schemes = project_dir / 'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)


def buildable(parent, target):
    ET.SubElement(parent, 'BuildableReference', BuildableIdentifier='primary', BlueprintIdentifier=ref(f'{target}:target'),
                  BuildableName=product_name(target), BlueprintName=target, ReferencedContainer='container:Mirror.xcodeproj')


for target in ('MirrorIOS', 'MirrorMac'):
    for ui in (False, True):
        test_targets = [target + 'UITests'] if ui else list(UNIT_TESTS)
        scheme = ET.Element('Scheme', LastUpgradeVersion='2700', version='1.3')
        action = ET.SubElement(scheme, 'BuildAction', parallelizeBuildables='YES', buildImplicitDependencies='YES')
        entries = ET.SubElement(action, 'BuildActionEntries')
        for name in [target] + test_targets:
            is_app = name == target
            entry = ET.SubElement(entries, 'BuildActionEntry', buildForTesting='YES',
                                  buildForRunning='YES' if is_app else 'NO', buildForProfiling='YES' if is_app else 'NO',
                                  buildForArchiving='YES' if is_app else 'NO', buildForAnalyzing='YES')
            buildable(entry, name)
        test = ET.SubElement(scheme, 'TestAction', buildConfiguration='Debug',
                            selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB',
                            selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB',
                            shouldUseLaunchSchemeArgsEnv='YES', codeCoverageEnabled='YES')
        testables = ET.SubElement(test, 'Testables')
        for name in test_targets:
            testable = ET.SubElement(testables, 'TestableReference', skipped='NO', parallelizable='NO')
            buildable(testable, name)
        buildable(ET.SubElement(test, 'MacroExpansion'), target)
        launch = ET.SubElement(scheme, 'LaunchAction', buildConfiguration='Debug',
                              selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB',
                              selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', launchStyle='0',
                              useCustomWorkingDirectory='NO', ignoresPersistentStateOnLaunch='NO',
                              debugDocumentVersioning='YES', debugServiceExtension='internal', allowLocationSimulation='YES')
        buildable(ET.SubElement(launch, 'BuildableProductRunnable', runnableDebuggingMode='0'), target)
        profile = ET.SubElement(scheme, 'ProfileAction', buildConfiguration='Release', shouldUseLaunchSchemeArgsEnv='YES',
                               savedToolIdentifier='', useCustomWorkingDirectory='NO', debugDocumentVersioning='YES')
        buildable(ET.SubElement(profile, 'BuildableProductRunnable', runnableDebuggingMode='0'), target)
        ET.SubElement(scheme, 'AnalyzeAction', buildConfiguration='Debug')
        ET.SubElement(scheme, 'ArchiveAction', buildConfiguration='Release', revealArchiveInOrganizer='YES')
        ET.indent(scheme, space='   ')
        ET.ElementTree(scheme).write(schemes / f'{target}{"UI" if ui else ""}.xcscheme', encoding='UTF-8', xml_declaration=True)
print(f'Xcode 프로젝트 생성: {len(TARGETS)} targets, {len(OBJECTS)} objects, 4 schemes')
