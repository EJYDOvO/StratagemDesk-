#!/usr/bin/env python3
"""Generate a dependency-free, reviewable Xcode project; run after adding Swift files."""
import pathlib, hashlib, json
root = pathlib.Path(__file__).resolve().parents[1]
project = root / 'StratagemDesk.xcodeproj'
project.mkdir(exist_ok=True)
def uid(key): return hashlib.sha1(key.encode()).hexdigest()[:24].upper()
def q(value): return json.dumps(value)
objects = []
def obj(key, value): objects.append(f'{uid(key)} = {{ {value} }};'); return uid(key)
appfiles = sorted((root/'Sources/StratagemDesk').glob('*.swift'))
testfiles = sorted((root/'Tests/StratagemCoreTests').glob('*.swift'))
for kind, files in [('app', appfiles), ('tests', testfiles)]:
    for file in files:
        path = str(file.relative_to(root))
        obj(path, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(path)}; sourceTree = SOURCE_ROOT;')
        obj('build'+path, f'isa = PBXBuildFile; fileRef = {uid(path)};')
    obj(kind+'sources', 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ('+','.join(uid('build'+str(f.relative_to(root))) for f in files)+'); runOnlyForDeploymentPostprocessing = 0;')
    obj(kind+'lib', 'isa = XCSwiftPackageProductDependency; productName = StratagemCore;')
    obj(kind+'libbuild', f'isa = PBXBuildFile; productRef = {uid(kind+"lib")};')
    obj(kind+'frameworks', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({uid(kind+"libbuild")}); runOnlyForDeploymentPostprocessing = 0;')
    for mode in ['Debug','Release']:
        settings = {'ONLY_ACTIVE_ARCH':'YES' if mode=='Debug' else 'NO','PRODUCT_NAME':'StratagemDeskPublic' if kind=='app' else '$(TARGET_NAME)','MACOSX_DEPLOYMENT_TARGET':'14.0','SWIFT_VERSION':'5.0','SDKROOT':'macosx','CODE_SIGN_IDENTITY':'-','CODE_SIGN_STYLE':'Manual','ENABLE_APP_SANDBOX':'NO','ENABLE_HARDENED_RUNTIME':'YES','SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O','DEBUG_INFORMATION_FORMAT':'dwarf','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if mode=='Debug' else ''}
        settings.update({'PRODUCT_BUNDLE_IDENTIFIER':'io.github.EJYDOvO.StratagemDeskPublic','INFOPLIST_FILE':'Info.plist','GENERATE_INFOPLIST_FILE':'NO','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/../Frameworks'} if kind=='app' else {'PRODUCT_BUNDLE_IDENTIFIER':'io.github.EJYDOvO.StratagemDeskPublic.Tests','GENERATE_INFOPLIST_FILE':'YES'})
        obj(kind+mode, 'isa = XCBuildConfiguration; name = '+mode+'; buildSettings = {'+''.join(k+' = '+q(v)+';' for k,v in settings.items())+'};')
    obj(kind+'config', f'isa = XCConfigurationList; buildConfigurations = ({uid(kind+"Debug")},{uid(kind+"Release")}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('appProduct', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = StratagemDeskPublic.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj('testsProduct', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = StratagemCoreTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
for kind, name, product in [('app','StratagemDesk','com.apple.product-type.application'),('tests','StratagemCoreTests','com.apple.product-type.bundle.unit-test')]:
    obj(kind, f'isa = PBXNativeTarget; buildConfigurationList = {uid(kind+"config")}; buildPhases = ({uid(kind+"sources")},{uid(kind+"frameworks")}); buildRules = (); dependencies = (); name = {name}; packageProductDependencies = ({uid(kind+"lib")}); productName = {name}; productReference = {uid(kind+"Product")}; productType = {q(product)};')
obj('products', f'isa = PBXGroup; children = ({uid("appProduct")},{uid("testsProduct")}); name = Products; sourceTree = "<group>";')
obj('group', 'isa = PBXGroup; children = ('+','.join(uid(str(f.relative_to(root))) for f in appfiles+testfiles)+','+uid('products')+'); sourceTree = "<group>";')
obj('package', 'isa = XCLocalSwiftPackageReference; relativePath = .;')
for mode in ['Debug','Release']: obj('project'+mode, f'isa = XCBuildConfiguration; name = {mode}; buildSettings = {{ CLANG_ENABLE_MODULES = YES; }};')
obj('projectConfig', f'isa = XCConfigurationList; buildConfigurations = ({uid("projectDebug")},{uid("projectRelease")}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {uid("projectConfig")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, Base); mainGroup = {uid("group")}; packageReferences = ({uid("package")}); productRefGroup = {uid("products")}; projectDirPath = ""; projectRoot = ""; targets = ({uid("app")},{uid("tests")});')
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+'\n}; rootObject = '+uid('project')+'; }\n')
scheme = project/'xcshareddata/xcschemes'; scheme.mkdir(parents=True, exist_ok=True)
def ref(kind,name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(kind)}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:StratagemDesk.xcodeproj"/>'
(scheme/'StratagemDesk.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref('app','StratagemDeskPublic.app')}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref('tests','StratagemCoreTests.xctest')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{ref('app','StratagemDeskPublic.app')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('app','StratagemDeskPublic.app')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(project)
