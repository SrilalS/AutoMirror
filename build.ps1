<#
Builds automirror.apk with the plain SDK tools (no Gradle, no bash). PowerShell 7+.
  ./build.ps1            build the APK
  ./build.ps1 install    build, then adb install -r onto the attached phone and open it
                         ($env:ANDROID_SERIAL picks the device when several are attached)
  ./build.ps1 verify     build, then print the manifest and signing details
  ./build.ps1 clean      remove build/ (libs/ stays)

A plain adb install is enough for the phone side (the preview) and for the DHU. A real car only
shows the app when it is installed as if from Google Play: install the APK with UnknownAuto.

Stages: deps (tools/fetch-deps.py) -> manifest merge (Google's manifest merger) ->
aapt2 compile (app + each AAR) -> aapt2 link (R classes) -> aidl -> javac -> d8 ->
zip + zipalign + apksigner -> manifest / dex checks.

Needs: JDK 17+ (java, javac, keytool on PATH or in $env:JAVA_HOME), Python 3, and the Android SDK
in $env:ANDROID_HOME with build-tools 35.0.0 and platforms/android-35.
#>
param([ValidateSet('build', 'install', 'verify', 'clean')][string]$Task = 'build')

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

if ($env:JAVA_HOME) { $env:PATH = "$env:JAVA_HOME\bin;$env:PATH" }
$Sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "$env:LOCALAPPDATA\Android\Sdk" }
$Bt = "$Sdk\build-tools\35.0.0"
$CompileSdk = 35
$Jar = "$Sdk\platforms\android-$CompileSdk\android.jar"

$AppId = 'com.srilals.automirror'
$PkgDir = $AppId.Replace('.', '/')
$TargetSdk = 35
$VersionCode = 5
$VersionName = '0.5'
$Apk = 'automirror.apk'
$Keystore = 'keys/automirror.keystore'
$Sep = [IO.Path]::PathSeparator

# Runs a native tool and stops the build when it fails.
# A plain function on purpose: $args keeps tool flags such as -I or -o from being read as
# PowerShell common parameters.
function Run {
    $Exe = $args[0]
    $flat = @($args | Select-Object -Skip 1 | ForEach-Object { $_ })
    & $Exe @flat
    if ($LASTEXITCODE -ne 0) { throw "failed ($LASTEXITCODE): $Exe $($flat -join ' ')" }
}

function Fail([string]$Msg) { Write-Error $Msg; exit 1 }

# deps.env (KEY="value" lines written by fetch-deps.py) as a hashtable
function Read-Env([string]$Path) {
    $h = @{}
    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*([A-Z_]+)=(.*)$') { $h[$Matches[1]] = $Matches[2].Trim('"') }
    }
    $h
}

function Split-List([string]$s) { @($s -split ' ' | Where-Object { $_ }) }

# Adds every file under $Dir to the zip at $ZipPath, with forward-slash entry names.
function Add-ToZip([string]$ZipPath, [string]$Dir, [string]$Filter = '*') {
    $root = (Resolve-Path $Dir).Path.TrimEnd('\', '/')
    $zip = [IO.Compression.ZipFile]::Open((Resolve-Path $ZipPath).Path, 'Update')
    try {
        foreach ($f in Get-ChildItem $root -Recurse -File -Filter $Filter) {
            $name = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $name)
        }
    } finally { $zip.Dispose() }
}

if ($Task -eq 'clean') {
    Remove-Item -Recurse -Force build, $Apk -ErrorAction SilentlyContinue
    'removed build/'
    exit 0
}

foreach ($t in "$Bt\aapt2.exe", $Jar) { if (-not (Test-Path $t)) { Fail "missing: $t" } }

# ---- 1. libraries: resolve/download only when tools/deps.txt changed or files are missing
Run python -I tools/fetch-deps.py --roots tools/deps.txt --out libs --ensure
Run python -I tools/fetch-deps.py --roots tools/merger-deps.txt --out tools/merger --env jvm --ensure
$lib = Read-Env libs/deps.env
$merger = Read-Env tools/merger/deps.env
$LibJars = Split-List $lib.LIB_JARS
$MergerCp = (Split-List $merger.LIB_JARS) -join $Sep
$LibCp = $LibJars -join $Sep
if ([int]$lib.LIB_MIN_COMPILE_SDK -gt $CompileSdk) {
    Fail "a library needs compileSdk $($lib.LIB_MIN_COMPILE_SDK), only android-$CompileSdk is used"
}
# 29 (Android 10): per-display focus, ActivityOptions.setLaunchDisplayId for other apps' activities
$MinSdk = [Math]::Max([int]$lib.LIB_MIN_SDK, 29)

# build/libres keeps the compiled library resources between builds; the rest is rebuilt
New-Item -ItemType Directory -Force build | Out-Null
Get-ChildItem build | Where-Object Name -ne 'libres' | Remove-Item -Recurse -Force
foreach ($d in 'gen', 'classes', 'dex', 'libres', 'javares') { New-Item -ItemType Directory -Force "build/$d" | Out-Null }

# ---- 2. manifest: app manifest + every library manifest -> build/AndroidManifest.xml
Run java -cp $MergerCp com.android.manifmerger.Merger `
    --main AndroidManifest.xml `
    --libs ((Split-List $lib.LIB_MANIFESTS) -join $Sep) `
    --property PACKAGE=$AppId `
    --property MIN_SDK_VERSION=$MinSdk --property TARGET_SDK_VERSION=$TargetSdk `
    --property VERSION_CODE=$VersionCode --property VERSION_NAME=$VersionName `
    --remove-tools-declarations --log WARNING `
    --out build/AndroidManifest.xml

# ---- 3. resources: compile each AAR's res once (cached), the app's res every time
$linkRes = @()
foreach ($d in Split-List $lib.LIB_RES_DIRS) {
    $flat = "build/libres/$(Split-Path (Split-Path $d -Parent) -Leaf).zip"
    if (-not (Test-Path $flat)) {
        Run "$Bt\aapt2.exe" compile --dir $d -o "$flat.tmp"
        Move-Item "$flat.tmp" $flat
    }
    $linkRes += '-R', $flat
}
Run "$Bt\aapt2.exe" compile --dir res -o build/res.zip
$assets = @(); foreach ($a in Split-List $lib.LIB_ASSETS) { $assets += '-A', $a }
Run "$Bt\aapt2.exe" link -o build/base.apk -I $Jar --manifest build/AndroidManifest.xml `
    --java build/gen --extra-packages $lib.LIB_R_PACKAGES `
    --auto-add-overlay $linkRes -R build/res.zip $assets

# ---- 4. AIDL (the Shizuku user-service interface), then compile app + R classes
# aidl on Windows matches the file against the import path textually: both need backslashes
Run "$Bt\aidl.exe" -p "$Sdk\platforms\android-$CompileSdk\framework.aidl" -I 'src\' -o build/gen `
    ("src/$PkgDir/IDisplayService.aidl".Replace('/', '\'))
# an argument file: the source list is longer than a Windows command line allows
$sources = Get-ChildItem src, build/gen -Recurse -Filter *.java | ForEach-Object { '"' + $_.FullName.Replace('\', '/') + '"' }
Set-Content build/javac-sources.txt $sources
Run javac --release 17 -nowarn '-Xlint:-deprecation' '-Xlint:-options' -encoding UTF-8 `
    -classpath "$Jar$Sep$LibCp" -d build/classes '@build/javac-sources.txt'
[IO.Compression.ZipFile]::CreateFromDirectory((Resolve-Path build/classes).Path, "$PWD/build/classes.jar")

# ---- 5. dex: app classes + every library jar (argument file: d8.bat runs through cmd.exe)
Set-Content build/d8-args.txt (@('--release', '--min-api', $MinSdk, '--lib', $Jar, '--output', 'build/dex', 'build/classes.jar') + $LibJars)
Run "$Bt\d8.bat" '@build/d8-args.txt'

# ---- 6. package, align, sign
Run python -I tools/javares.py build/javares $LibJars
Copy-Item build/base.apk build/unsigned.apk
Add-ToZip build/unsigned.apk build/dex 'classes*.dex'
if (Get-ChildItem build/javares -Recurse -File) { Add-ToZip build/unsigned.apk build/javares }
Run "$Bt\zipalign.exe" -f 4 build/unsigned.apk build/aligned.apk
if (-not (Test-Path $Keystore)) {
    New-Item -ItemType Directory -Force keys | Out-Null
    Run keytool -genkeypair -keystore $Keystore -storepass android -keypass android -alias automirror `
        -keyalg RSA -keysize 2048 -validity 10000 -dname 'CN=AutoMirror' 2>$null
}
Run "$Bt\apksigner.bat" sign --ks $Keystore --ks-pass pass:android --ks-key-alias automirror `
    --out $Apk build/aligned.apk
Remove-Item "$Apk.idsig" -ErrorAction SilentlyContinue

# ---- 7. sanity checks: the car service, its permissions and the key classes
$manifest = (& "$Bt\aapt2.exe" dump xmltree --file AndroidManifest.xml $Apk) -join "`n"
Set-Content build/manifest.txt $manifest
$must = 'androidx.car.app.CarAppService', 'androidx.car.app.category.NAVIGATION',
    'androidx.car.app.NAVIGATION_TEMPLATES', 'androidx.car.app.ACCESS_SURFACE', 'androidx.car.app.minCarApiLevel',
    'com.google.android.gms.car.application', 'rikka.shizuku.ShizukuProvider',
    'moe.shizuku.manager.permission.API_V23', "$AppId.PreviewActivity", "$AppId.shizuku"
# no routing: "navigate to" requests stay with Google Maps
$mustNot = 'androidx.car.app.action.NAVIGATE', 'androidx.car.app.category.FEATURE_CLUSTER', 'android.permission.INTERNET'
foreach ($m in $must) { if (-not $manifest.Contains($m)) { Fail "missing from the merged manifest: $m" } }
foreach ($m in $mustNot) { if ($manifest.Contains($m)) { Fail "must not be in the merged manifest: $m" } }

$classes = foreach ($f in Get-ChildItem build/dex -Filter 'classes*.dex') {
    & "$Bt\dexdump.exe" $f.FullName | Select-String '^  Class descriptor  : .(L[^;]*;)' | ForEach-Object { $_.Matches[0].Groups[1].Value }
}
$classes | Set-Content build/dex-classes.txt
$wantClasses = 'Landroidx/car/app/CarAppService;', 'Landroidx/car/app/navigation/model/NavigationTemplate;',
    'Lrikka/shizuku/Shizuku;', 'Lrikka/shizuku/ShizukuProvider;', "L$PkgDir/R;",
    "L$PkgDir/DisplayService;", "L$PkgDir/IDisplayService`$Stub;",
    "L$PkgDir/car/AnyAutoService;", "L$PkgDir/Touch;", 'Lkotlin/Unit;'
foreach ($c in $wantClasses) { if ($classes -notcontains $c) { Fail "missing from dex: $c" } }
# the Car App Library reads this jar resource at start-up; without it the host shows a black screen
$z = [IO.Compression.ZipFile]::OpenRead((Resolve-Path $Apk).Path)
try { $hasLevel = [bool]($z.Entries | Where-Object FullName -eq 'car-app-api.level') } finally { $z.Dispose() }
if (-not $hasLevel) { Fail 'car-app-api.level is missing from the APK' }

if ($Task -eq 'verify') {
    Run "$Bt\apksigner.bat" verify --print-certs $Apk
    Run "$Bt\aapt2.exe" dump badging $Apk
    $manifest
}
"built $PWD\$Apk ($([int]((Get-Item $Apk).Length / 1KB)) KB, minSdk $MinSdk, targetSdk $TargetSdk)"

if ($Task -eq 'install') {
    $adb = (Get-Command adb -ErrorAction SilentlyContinue)?.Source
    if (-not $adb) { $adb = "$Sdk\platform-tools\adb.exe" }
    Run $adb install -r $Apk
    Run $adb shell am start -n "$AppId/.MainActivity" | Out-Null
    'opened AutoMirror on the phone'
}
