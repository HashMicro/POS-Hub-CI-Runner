$ErrorActionPreference = "Stop"

function Require-Env {
  param([string]$Name)
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "$Name is required"
  }
  return $value.Trim()
}

function Get-OptionalEnv {
  param([string]$Name, [string]$Fallback = "")
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    return $Fallback
  }
  return $value.Trim()
}

function Invoke-WithJavaHome {
  param(
    [string]$JavaHome,
    [string]$EnvironmentName,
    [string]$Purpose,
    [scriptblock]$Action
  )

  if ([string]::IsNullOrWhiteSpace($JavaHome)) {
    & $Action
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
      throw "$Purpose failed with exit code $exitCode"
    }
    return
  }

  $javaExe = if ($IsLinux -or $IsMacOS) { "bin/java" } else { "bin\java.exe" }
  $javaPath = Join-Path $JavaHome $javaExe
  if (!(Test-Path $javaPath)) {
    throw "$EnvironmentName must point to a JDK containing ${javaExe}: $JavaHome"
  }

  $previousJavaHome = $env:JAVA_HOME
  $previousPath = $env:PATH
  $pathSep = [System.IO.Path]::PathSeparator
  try {
    $env:JAVA_HOME = $JavaHome
    $env:PATH = (Join-Path $JavaHome "bin") + $pathSep + $previousPath
    & $Action
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
      throw "$Purpose failed with exit code $exitCode"
    }
  }
  finally {
    if ($null -eq $previousJavaHome) {
      Remove-Item Env:JAVA_HOME -ErrorAction SilentlyContinue
    }
    else {
      $env:JAVA_HOME = $previousJavaHome
    }
    $env:PATH = $previousPath
  }
}

function Invoke-FlutterCommand {
  param([string[]]$Arguments)

  $flutterJavaHome = Get-OptionalEnv 'POSHUB_FLUTTER_JAVA_HOME' ''
  Invoke-WithJavaHome `
    -JavaHome $flutterJavaHome `
    -EnvironmentName 'POSHUB_FLUTTER_JAVA_HOME' `
    -Purpose ("fvm " + ($Arguments -join ' ')) `
    -Action { & fvm @Arguments }
}

function Invoke-CapacitorGradleRelease {
  param([string]$AppDir)

  $capacitorJavaHome = Require-Env 'POSHUB_CAPACITOR_JAVA_HOME'
  $gradleWrapper = if ($IsLinux -or $IsMacOS) { "android/gradlew" } else { "android\gradlew.bat" }
  $gradlePath = Join-Path $AppDir $gradleWrapper
  if (($IsLinux -or $IsMacOS) -and (Test-Path $gradlePath)) {
    & chmod +x $gradlePath
  }
  $gradleWorkDir = Join-Path $AppDir "android"
  Invoke-WithJavaHome `
    -JavaHome $capacitorJavaHome `
    -EnvironmentName 'POSHUB_CAPACITOR_JAVA_HOME' `
    -Purpose 'Capacitor Android Gradle build' `
    -Action { & $gradlePath -p $gradleWorkDir assembleRelease }
}

$DefaultGitCloneTimeoutSeconds = 300

function Get-OptionalIntEnv {
  param([string]$Name, [int]$Fallback)
  $raw = Get-OptionalEnv $Name
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return $Fallback
  }
  $parsed = 0
  if (![int]::TryParse($raw, [ref]$parsed) -or $parsed -le 0) {
    throw "$Name must be a positive integer"
  }
  return $parsed
}

function Invoke-GitCommand {
  param(
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [string]$WorkingDirectory = "",
    [string]$FailureMessage
  )

  if (![string]::IsNullOrWhiteSpace($WorkingDirectory)) {
    Push-Location $WorkingDirectory
  }
  try {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
      & git @Arguments 2>&1 | ForEach-Object { Write-Host ($_.ToString()) }
      $exitCode = $LASTEXITCODE
    }
    finally {
      $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
      throw "$FailureMessage failed with exit code $exitCode"
    }
  }
  finally {
    if (![string]::IsNullOrWhiteSpace($WorkingDirectory)) {
      Pop-Location
    }
  }
}

function Invoke-GitClone {
  param(
    [string]$RepoURL,
    [string]$Branch,
    [string]$Destination,
    [int]$TimeoutSeconds
  )

  $env:GIT_TERMINAL_PROMPT = "0"
  $env:GCM_INTERACTIVE = "Never"
  $env:GIT_OPTIONAL_LOCKS = "0"

  $cloneToken = Get-OptionalEnv 'POSHUB_GIT_CLONE_TOKEN' ''
  if (![string]::IsNullOrWhiteSpace($cloneToken)) {
    $cloneUser = (Get-OptionalEnv 'POSHUB_GIT_CLONE_USERNAME' 'oauth2').Trim()
    if ([string]::IsNullOrWhiteSpace($cloneUser)) { $cloneUser = 'oauth2' }
    $clonePair = "$cloneUser`:$cloneToken"
    $cloneB64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($clonePair))
    # GIT_CONFIG_* env vars keep the credential out of the process argument
    # list and also authenticate the later "git fetch" for release commits.
    $env:GIT_CONFIG_COUNT = "1"
    $env:GIT_CONFIG_KEY_0 = "http.extraheader"
    $env:GIT_CONFIG_VALUE_0 = "Authorization: Basic $cloneB64"
  }

  Write-Host "Cloning $RepoURL branch $Branch into $Destination"
  Invoke-GitCommand `
    -Arguments @("-c", "core.longpaths=true", "clone", "--no-checkout", "--branch", $Branch, "--depth", "1", $RepoURL, $Destination) `
    -FailureMessage "git clone"

  Invoke-GitCommand `
    -Arguments @("config", "core.longpaths", "true") `
    -WorkingDirectory $Destination `
    -FailureMessage "git config core.longpaths"

  Invoke-GitCommand `
    -Arguments @("checkout", "--force", $Branch) `
    -WorkingDirectory $Destination `
    -FailureMessage "git checkout $Branch"
}

function Test-Truthy {
  param([string]$Value)
  return @("1", "true", "yes", "y", "on") -contains $Value.Trim().ToLowerInvariant()
}

function Test-SkipAppNamePatch {
  return Test-Truthy (Get-OptionalEnv "POSHUB_SKIP_APP_NAME_PATCH")
}

function Get-CoreConfigAppName {
  param([string]$Path)
  if (!(Test-Path $Path)) { return "" }
  $content = Get-Content -Path $Path -Raw
  $match = [regex]::Match($content, "appName\s*:\s*`"([^`"]+)`"")
  if ($match.Success) { return $match.Groups[1].Value }
  return ""
}

function Get-SemVerBase {
  param([string]$Value)
  $value = $Value.Trim()
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "version is required; set POSHUB_TARGET_VERSION or add version to apps/pos/pubspec.yaml"
  }
  if ($value -match '^(?<base>[^+]+)(?<meta>\+.+)?$') {
    return $Matches.base
  }
  return $value
}

function Read-PubspecVersion {
  param([string]$Path)
  if (!(Test-Path $Path)) {
    throw "File not found: $Path"
  }
  foreach ($line in Get-Content -Path $Path) {
    $trimmed = $line.Trim()
    if ($trimmed.StartsWith("version:")) {
      $version = $trimmed.Substring("version:".Length).Trim().Trim('"', "'")
      if (![string]::IsNullOrWhiteSpace($version)) {
        return $version
      }
    }
  }
  throw "version not found in apps/pos/pubspec.yaml"
}

function Normalize-BuildVersion {
  param([string]$Value)
  $version = $Value.Trim().Trim('"', "'")
  if ([string]::IsNullOrWhiteSpace($version)) {
    return ""
  }
  if ($version -match '^([0-9]+\.[0-9]+\.[0-9]+)(?:([+.])([0-9]+))?$') {
    if ([string]::IsNullOrWhiteSpace($Matches[3])) {
      return $Matches[1]
    }
    return "$($Matches[1])+$($Matches[3])"
  }
  throw "version $version must be MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH+BUILD"
}

function Get-NextBuildVersion {
  param([string]$Value)
  $version = Normalize-BuildVersion $Value
  if ($version -notmatch '^([0-9]+\.[0-9]+\.[0-9]+)(?:\+([0-9]+))?$') {
    throw "version $Value must be MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH+BUILD"
  }
  $build = 0
  if (![string]::IsNullOrWhiteSpace($Matches[2])) {
    $build = [int]$Matches[2]
  }
  return "$($Matches[1])+$($build + 1)"
}


function ConvertTo-SafeName {
  param([string]$Value, [string]$Fallback = "pos")
  $safe = ($Value -replace '[^a-zA-Z0-9._ -]', '-').Trim()
  $safe = ($safe -replace '\s+', ' ')
  if ([string]::IsNullOrWhiteSpace($safe)) {
    return $Fallback
  }
  return $safe
}

function ConvertTo-SafeFileName {
  param([string]$Value, [string]$Fallback = "pos")
  $safe = ($Value -replace '[^a-zA-Z0-9._-]', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($safe)) {
    return $Fallback
  }
  return $safe
}

function ConvertTo-StableAppId {
  param([string]$Value)
  $normalized = $Value.Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    throw "POSHUB_PACKAGE_NAME is required for stable Windows AppId"
  }
  $md5 = [System.Security.Cryptography.MD5]::Create()
  try {
    $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalized))
  }
  finally {
    $md5.Dispose()
  }
  $bytes[6] = (($bytes[6] -band 0x0f) -bor 0x30)
  $bytes[8] = (($bytes[8] -band 0x3f) -bor 0x80)
  $guid = ([Guid]::New($bytes)).ToString("D")
  return "{{" + $guid + "}"
}

function Set-FileContent {
  param([string]$Path, [string]$Content)
  Set-Content -Path $Path -Value $Content -NoNewline
}

function Update-FileByRegex {
  param(
    [string]$Path,
    [string]$Pattern,
    [string]$Replacement,
    [bool]$Required = $true
  )
  if (!(Test-Path $Path)) {
    if ($Required) { throw "File not found: $Path" }
    return $false
  }
  $content = Get-Content -Path $Path -Raw
  $regex = [regex]$Pattern
  if (!$regex.IsMatch($content)) {
    if ($Required) { throw "Marker not found in $Path" }
    return $false
  }
  $updated = $regex.Replace($content, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) return $Replacement })
  Set-FileContent -Path $Path -Content $updated
  return $true
}

function Set-InnoDefine {
  param([string]$Path, [string]$Name, [string]$Value)
  $content = Get-Content -Path $Path -Raw
  $line = "#define $Name `"$Value`""
  $pattern = "(?m)^#define\s+$([regex]::Escape($Name))\s+`"[^`"]*`"\s*$"
  $regex = [regex]$pattern
  if ($regex.IsMatch($content)) {
    $content = $regex.Replace($content, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) return $line })
  } else {
    $content = $line + "`r`n" + $content
  }
  Set-FileContent -Path $Path -Content $content
}

function Set-InnoSetupKey {
  param([string]$Path, [string]$Key, [string]$Value)
  $content = Get-Content -Path $Path -Raw
  $line = "$Key=$Value"
  $keyPattern = "(?m)^$([regex]::Escape($Key))\s*=.*$"
  $keyRegex = [regex]$keyPattern
  if ($keyRegex.IsMatch($content)) {
    $content = $keyRegex.Replace($content, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) return $line })
  } elseif ($content -match '(?m)^\[Setup\]\s*$') {
    $content = [regex]::Replace($content, '(?m)^\[Setup\]\s*$', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) return $m.Value + "`r`n" + $line }, 1)
  } else {
    $content = $content.TrimEnd() + "`r`n`r`n[Setup]`r`n" + $line + "`r`n"
  }
  Set-FileContent -Path $Path -Content $content
}

function ConvertTo-DartString {
  param([string]$Value)
  if ($null -eq $Value) { $Value = "" }
  return ($Value | ConvertTo-Json -Compress)
}

function ConvertTo-DartColor {
  param([string]$Value)
  $clean = $Value.Trim().TrimStart('#')
  if ($clean -match '^[0-9a-fA-F]{6}$') {
    return "0xFF$($clean.ToUpperInvariant())"
  }
  if ($clean -match '^[0-9a-fA-F]{8}$') {
    return "0x$($clean.ToUpperInvariant())"
  }
  return "0xFF000000"
}

function New-CoreConfigBlock {
  param([string]$AppName)
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("// POS_HUB_CONFIG_START")
  $lines.Add("CoreConfig(")
  $lines.Add("  appName: $(ConvertTo-DartString $AppName),")
  if (![string]::IsNullOrWhiteSpace((Get-OptionalEnv 'POSHUB_DATABASE'))) {
    $lines.Add("  database: $(ConvertTo-DartString (Get-OptionalEnv 'POSHUB_DATABASE')),")
  }
  if (![string]::IsNullOrWhiteSpace((Get-OptionalEnv 'POSHUB_BASE_URL'))) {
    $lines.Add("  baseUrl: $(ConvertTo-DartString (Get-OptionalEnv 'POSHUB_BASE_URL')),")
  }
  $lines.Add("  module: 'pos',")
  $lines.Add("  schemas: schemas,")
  $lines.Add("  posHubToken: $(ConvertTo-DartString (Get-OptionalEnv 'POSHUB_TOKEN')),")
  $lines.Add("  posHubClientName: $(ConvertTo-DartString (Get-OptionalEnv 'POSHUB_CLIENT_NAME')),")
  $lines.Add("  posHubClientId: $(ConvertTo-DartString (Get-OptionalEnv 'POSHUB_CLIENT_ID')),")
  $primary = Get-OptionalEnv 'POSHUB_PRIMARY_COLOR'
  $secondary = Get-OptionalEnv 'POSHUB_SECONDARY_COLOR'
  if (![string]::IsNullOrWhiteSpace($primary) -or ![string]::IsNullOrWhiteSpace($secondary)) {
    $lines.Add("  theme: ThemeData(")
    if (![string]::IsNullOrWhiteSpace($primary)) {
      $lines.Add("    primaryColor: Color($(ConvertTo-DartColor $primary)),")
    }
    if (![string]::IsNullOrWhiteSpace($secondary)) {
      $lines.Add("    colorScheme: ColorScheme.fromSeed(seedColor: Color($(ConvertTo-DartColor $secondary))),")
    }
    $lines.Add("  ),")
  }
  $lines.Add(")")
  $lines.Add("// POS_HUB_CONFIG_END")
  return [string]::Join("`n", $lines) + "`n"
}

function Find-BalancedCallRange {
  param([string]$Content, [string]$Name)
  $match = [regex]::Match($Content, "$([regex]::Escape($Name))\s*\(")
  if (!$match.Success) { return $null }
  $start = $match.Index
  $open = $match.Index + $match.Value.LastIndexOf('(')
  $depth = 0
  $quote = [char]0
  $escaped = $false
  for ($i = $open; $i -lt $Content.Length; $i++) {
    $ch = $Content[$i]
    if ($quote -ne [char]0) {
      if ($escaped) { $escaped = $false; continue }
      if ($ch -eq '\') { $escaped = $true; continue }
      if ($ch -eq $quote) { $quote = [char]0 }
      continue
    }
    if ($ch -eq '"' -or $ch -eq "'") { $quote = $ch; continue }
    if ($ch -eq '(') { $depth++ }
    elseif ($ch -eq ')') {
      $depth--
      if ($depth -eq 0) { return @{ Start = $start; End = $i + 1 } }
    }
  }
  return $null
}

function Set-CoreConfig {
  param([string]$MainPath)
  if (!(Test-Path $MainPath)) {
    throw "File not found: $MainPath"
  }
  $content = Get-Content -Path $MainPath -Raw
  $appNameForConfig = Get-OptionalEnv "POSHUB_APP_NAME"
  if (Test-SkipAppNamePatch) {
    $repoAppName = Get-CoreConfigAppName -Path $MainPath
    if (![string]::IsNullOrWhiteSpace($repoAppName)) {
      $appNameForConfig = $repoAppName
    }
  }
  $block = New-CoreConfigBlock -AppName $appNameForConfig
  $markerPattern = '(?s)// POS_HUB_CONFIG_START.*?// POS_HUB_CONFIG_END'
  if ([regex]::IsMatch($content, $markerPattern)) {
    $content = [regex]::Replace($content, $markerPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) return $block })
  } else {
    $range = Find-BalancedCallRange -Content $content -Name 'CoreConfig'
    if ($null -eq $range) {
      throw "CoreConfig block not found in $MainPath"
    }
    $content = $content.Substring(0, $range.Start) + $block + $content.Substring($range.End)
  }
  Set-FileContent -Path $MainPath -Content $content
}

function Patch-AndroidPackage {
  param([string]$GradlePath, [string]$PackageName, [string]$AppName = "")
  if (!(Test-Path $GradlePath)) { return }
  Update-FileByRegex -Path $GradlePath -Pattern 'namespace\s*=\s*"[^"]+"' -Replacement "namespace = `"$PackageName`"" -Required:$false | Out-Null
  Update-FileByRegex -Path $GradlePath -Pattern 'applicationId\s*=\s*"[^"]+"' -Replacement "applicationId = `"$PackageName`"" -Required:$false | Out-Null
  if (![string]::IsNullOrWhiteSpace($AppName)) {
    Update-FileByRegex -Path $GradlePath -Pattern 'resValue\s*\(\s*"string"\s*,\s*"app_name"\s*,\s*"[^"]*"\s*\)' -Replacement "resValue(`"string`", `"app_name`", `"$AppName`")" -Required:$false | Out-Null
  }
}

function Patch-AndroidGradleProperties {
  param([string]$AppDir)
  $propsPath = Join-Path $AppDir "android/gradle.properties"
  $androidDir = Join-Path $AppDir "android"
  if (!(Test-Path $androidDir)) { return }
  $values = [ordered]@{
    "org.gradle.daemon"         = "false"
    "org.gradle.workers.max"    = "2"
    "org.gradle.jvmargs"        = "-Xmx3072m -XX:MaxMetaspaceSize=1024m -Dfile.encoding=UTF-8"
    "kotlin.daemon.jvm.options" = "-Xmx1536m"
  }
  $lines = New-Object System.Collections.Generic.List[string]
  $seen = @{}
  if (Test-Path $propsPath) {
    foreach ($line in (Get-Content -Path $propsPath)) {
      $trimmed = $line.Trim()
      $matched = $false
      foreach ($key in $values.Keys) {
        if ($trimmed.StartsWith("$key=")) {
          $lines.Add("$key=$($values[$key])")
          $seen[$key] = $true
          $matched = $true
          break
        }
      }
      if (-not $matched) {
        $lines.Add($line)
      }
    }
  }
  foreach ($key in $values.Keys) {
    if (-not $seen.ContainsKey($key)) {
      $lines.Add("$key=$($values[$key])")
    }
  }
  Set-Content -Path $propsPath -Value ($lines -join "`n") -Encoding UTF8
}

function Get-WindowsBinaryName {
  param([string]$PackageName, [string]$AppName)
  $candidate = (($PackageName -split '\.') | Select-Object -Last 1)
  if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $AppName }
  $candidate = ($candidate.Trim().ToLowerInvariant() -replace '[^a-z0-9_-]+', '_').Trim('_-'.ToCharArray())
  if ([string]::IsNullOrWhiteSpace($candidate)) { return 'pos' }
  return $candidate
}

function Patch-WindowsCMake {
  param([string]$CMakePath, [string]$BinaryName)
  if (!(Test-Path $CMakePath)) { return }
  $content = Get-Content -Path $CMakePath -Raw
  $projectRegex = [regex]'(?m)^project\([^\s\)]+(?<rest>[^\r\n]*\))'
  $content = $projectRegex.Replace($content, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) return "project($BinaryName$($m.Groups['rest'].Value)" })
  $binaryRegex = [regex]'(?m)^(?<prefix>\s*set\(\s*BINARY_NAME\s+)[^\r\n\)]*\)'
  $content = $binaryRegex.Replace($content, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) return "$($m.Groups['prefix'].Value)`"$BinaryName`")" })
  if ($content -notmatch '_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS') {
    $content = "add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)`r`n" + $content
  }
  Set-FileContent -Path $CMakePath -Content $content
}

function Patch-WindowsMetadata {
  param([string]$ResourcePath, [string]$AppName, [string]$BinaryName)
  if (!(Test-Path $ResourcePath)) { return }
  Update-FileByRegex -Path $ResourcePath -Pattern 'VALUE\s+"FileDescription",\s+"[^"]*\\0"' -Replacement "VALUE `"FileDescription`", `"$AppName\\0`"" -Required:$false | Out-Null
  Update-FileByRegex -Path $ResourcePath -Pattern 'VALUE\s+"InternalName",\s+"[^"]*\\0"' -Replacement "VALUE `"InternalName`", `"$BinaryName\\0`"" -Required:$false | Out-Null
  Update-FileByRegex -Path $ResourcePath -Pattern 'VALUE\s+"OriginalFilename",\s+"[^"]*\\0"' -Replacement "VALUE `"OriginalFilename`", `"$BinaryName.exe\\0`"" -Required:$false | Out-Null
  Update-FileByRegex -Path $ResourcePath -Pattern 'VALUE\s+"ProductName",\s+"[^"]*\\0"' -Replacement "VALUE `"ProductName`", `"$BinaryName\\0`"" -Required:$false | Out-Null
  # pos_cache writes the value and its NUL terminator as two separate strings;
  # the Flutter template keeps them inside one string. Patch both styles.
  Update-FileByRegex -Path $ResourcePath -Pattern 'VALUE\s+"FileDescription",\s+"[^"]*"\s+"\\0"' -Replacement "VALUE `"FileDescription`", `"$AppName`" `"\0`"" -Required:$false | Out-Null
  Update-FileByRegex -Path $ResourcePath -Pattern 'VALUE\s+"InternalName",\s+"[^"]*"\s+"\\0"' -Replacement "VALUE `"InternalName`", `"$BinaryName`" `"\0`"" -Required:$false | Out-Null
  Update-FileByRegex -Path $ResourcePath -Pattern 'VALUE\s+"OriginalFilename",\s+"[^"]*"\s+"\\0"' -Replacement "VALUE `"OriginalFilename`", `"$BinaryName.exe`" `"\0`"" -Required:$false | Out-Null
  Update-FileByRegex -Path $ResourcePath -Pattern 'VALUE\s+"ProductName",\s+"[^"]*"\s+"\\0"' -Replacement "VALUE `"ProductName`", `"$BinaryName`" `"\0`"" -Required:$false | Out-Null
}

function Patch-WindowsWindowTitle {
  param([string]$MainCppPath, [string]$AppName)
  if (!(Test-Path $MainCppPath)) { return }
  Update-FileByRegex -Path $MainCppPath -Pattern 'window\.Create\(L"[^"]*"' -Replacement ('window.Create(L"' + $AppName + '"') -Required:$false | Out-Null
}

function Apply-IconAssets {
  param([string]$AppDir)
  if (!(Test-Truthy (Get-OptionalEnv 'POSHUB_ICON_AUTO_PATCH'))) {
    return
  }
  $iconZipURL = Get-OptionalEnv 'POSHUB_ICON_ZIP_URL'
  if ([string]::IsNullOrWhiteSpace($iconZipURL)) {
    throw "POSHUB_ICON_ZIP_URL is required when icon auto patch is enabled"
  }
  $headers = @{}
  $runnerToken = Get-OptionalEnv 'POSHUB_RUNNER_TOKEN'
  $machineID = Get-OptionalEnv 'POSHUB_RUNNER_MACHINE_ID'
  $callbackToken = Get-OptionalEnv 'POS_HUB_CALLBACK_TOKEN'
  if (![string]::IsNullOrWhiteSpace($runnerToken)) { $headers['X-Runner-Token'] = $runnerToken }
  if (![string]::IsNullOrWhiteSpace($machineID)) { $headers['X-Runner-Machine-ID'] = $machineID }
  if (![string]::IsNullOrWhiteSpace($callbackToken)) {
    $headers['Authorization'] = "Bearer $callbackToken"
    $headers['X-POS-Hub-Callback-Token'] = $callbackToken
  }
  $zipPath = Join-Path (Require-Env 'POSHUB_WORK_DIR') "client-icons.zip"
  Invoke-WebRequest -Uri $iconZipURL -Headers $headers -OutFile $zipPath
  Expand-Archive -Path $zipPath -DestinationPath $AppDir -Force
}

function Find-InnoCompiler {
  foreach ($candidate in @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "ISCC.exe"
  )) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    $command = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    if (Test-Path $candidate) { return $candidate }
  }
  throw "Inno Setup compiler not found"
}

function Get-InnoSetupValue {
  param([string]$Path, [string]$Key)
  if (!(Test-Path $Path)) {
    return ""
  }
  $keyPattern = [regex]::Escape($Key)
  foreach ($line in Get-Content -Path $Path) {
    if ($line -match "^\s*$keyPattern\s*=\s*(.+?)\s*$") {
      return $Matches[1].Trim().Trim('"')
    }
  }
  return ""
}

function Resolve-InnoRelativePath {
  param([string]$AppDir, [string]$Value)
  $value = $Value.Trim().Trim('"')
  if ([string]::IsNullOrWhiteSpace($value)) {
    return ""
  }
  if ($value.StartsWith("{")) {
    return ""
  }
  if ([System.IO.Path]::IsPathRooted($value)) {
    return $value
  }
  return Join-Path $AppDir $value
}

function Find-InnoInstaller {
  param(
    [string]$AppDir,
    [string]$InnoSetupPath,
    [object[]]$CompilerOutput
  )
  $candidates = @()
  foreach ($line in @($CompilerOutput)) {
    $candidate = $line.ToString().Trim().Trim('"')
    if ($candidate -match '^[a-zA-Z]:\\.*\.exe$' -and (Test-Path $candidate)) {
      $candidates += (Get-Item -Path $candidate)
    }
  }

  $configuredOutput = Resolve-InnoRelativePath -AppDir $AppDir -Value (Get-InnoSetupValue -Path $InnoSetupPath -Key 'OutputDir')
  $searchDirs = @(
    $configuredOutput,
    (Join-Path $AppDir "Output"),
    (Join-Path $AppDir "build\windows")
  ) | Where-Object { ![string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

  foreach ($dir in $searchDirs) {
    if (Test-Path $dir) {
      $candidates += Get-ChildItem -Path $dir -Filter *.exe -File | Sort-Object LastWriteTime -Descending
    }
  }

  $installer = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $installer) {
    throw "No installer EXE found after Inno Setup compile"
  }
  return $installer
}

$repoDir = Require-Env 'POSHUB_WORK_DIR'
$sourceDir = Join-Path $repoDir "source"
$appType = (Get-OptionalEnv 'POSHUB_APP_TYPE' 'hmx').Trim().ToLowerInvariant()
if ($appType -ne 'hmx' -and $appType -ne 'pos_logger' -and $appType -ne 'capacitor') {
  throw "unsupported POSHUB_APP_TYPE '$appType'"
}
$appDirDefault = 'apps/pos'
if ($appType -eq 'pos_logger') { $appDirDefault = 'pos_cache' }
if ($appType -eq 'capacitor') { $appDirDefault = '' }
$appDirRelative = (Get-OptionalEnv 'POSHUB_APP_DIR' $appDirDefault) -replace '\\', '/'
$appDir = $sourceDir
if (![string]::IsNullOrWhiteSpace($appDirRelative)) {
  $appDir = Join-Path $sourceDir $appDirRelative
}
$artifactDir = Require-Env 'POSHUB_ARTIFACT_DIR'
$repoURL = Require-Env 'POSHUB_REPO_URL'
$branch = Require-Env 'POSHUB_BUILD_BRANCH'
$versionFull = Get-OptionalEnv 'POSHUB_TARGET_VERSION'
$releaseToCommit = Get-OptionalEnv POSHUB_RELEASE_TO_COMMIT
$appName = Get-OptionalEnv 'POSHUB_APP_NAME' (Get-OptionalEnv 'POSHUB_CLIENT_NAME' 'POS')
$packageName = Get-OptionalEnv 'POSHUB_PACKAGE_NAME' ''
$pubspec = Join-Path $appDir "pubspec.yaml"
$innoSetup = Join-Path $appDir "inno_setup.iss"
$mainDart = Join-Path $appDir "lib/main.dart"
$androidGradle = Join-Path $appDir "android/app/build.gradle.kts"
$windowsCMake = Join-Path $appDir "windows/CMakeLists.txt"
$windowsResource = Join-Path $appDir "windows/runner/Runner.rc"
$windowsMainCpp = Join-Path $appDir "windows/runner/main.cpp"
$safeAppName = ConvertTo-SafeName $appName "POS"
$safeFileName = ConvertTo-SafeFileName $appName "pos"
$windowsBinaryName = Get-WindowsBinaryName -PackageName $packageName -AppName $appName
$skipAppNamePatch = Test-SkipAppNamePatch
$platform = (Get-OptionalEnv 'POSHUB_PLATFORM' 'windows').Trim().ToLowerInvariant()
$windowsAppId = if ($platform -eq 'windows' -or ![string]::IsNullOrWhiteSpace($packageName)) { ConvertTo-StableAppId $packageName } else { "" }

if (Test-Path $sourceDir) {
  Remove-Item -Recurse -Force $sourceDir
}
if (Test-Path $artifactDir) {
  Remove-Item -Recurse -Force $artifactDir
}
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null

$gitCloneTimeoutSeconds = Get-OptionalIntEnv "POSHUB_GIT_CLONE_TIMEOUT_SECONDS" $DefaultGitCloneTimeoutSeconds
Invoke-GitClone -RepoURL $repoURL -Branch $branch -Destination $sourceDir -TimeoutSeconds $gitCloneTimeoutSeconds
if (![string]::IsNullOrWhiteSpace($releaseToCommit)) {
  git -C $sourceDir fetch --depth 200 origin $branch
  git -C $sourceDir checkout --detach $releaseToCommit
}

if ([string]::IsNullOrWhiteSpace($versionFull)) {
  if ($appType -eq 'capacitor') {
    $packageJsonPath = Join-Path $appDir "package.json"
    if (!(Test-Path $packageJsonPath)) {
      throw "version is required; set POSHUB_TARGET_VERSION or add version to package.json"
    }
    $packageJson = Get-Content -Raw -Path $packageJsonPath | ConvertFrom-Json
    $versionFull = Normalize-BuildVersion $packageJson.version
    if ($versionFull -notmatch '\+[0-9]+$') {
      $capGradleInit = Join-Path $appDir "android/app/build.gradle"
      if (Test-Path $capGradleInit) {
        $gradleRaw = Get-Content -Raw -Path $capGradleInit
        if ($gradleRaw -match '(?m)versionCode\s*=?\s*(\d+)') {
          $rawVc = [int]$Matches[1]
          if ($rawVc -gt 1) {
            $versionFull = "$versionFull+$rawVc"
          }
        }
      }
    }
  }
  else {
    $versionFull = Normalize-BuildVersion (Read-PubspecVersion $pubspec)
  }
}
else {
  $versionFull = Normalize-BuildVersion $versionFull
}
if ([string]::IsNullOrWhiteSpace($versionFull)) {
  if ($appType -eq 'capacitor') {
    throw "version is required; set POSHUB_TARGET_VERSION or add version to package.json"
  }
  throw "version is required; set POSHUB_TARGET_VERSION or add version to apps/pos/pubspec.yaml"
}
$versionBase = Get-SemVerBase $versionFull
Write-Host "Building POS version $versionFull for platform $platform"

if ($appType -eq 'hmx') {
  Update-FileByRegex -Path $pubspec -Pattern '(?m)^version:\s*.*$' -Replacement "version: $versionFull" | Out-Null
  Set-CoreConfig -MainPath $mainDart
  $appNameForPlatformPatch = $appName
  if ($skipAppNamePatch) { $appNameForPlatformPatch = "" }
  Patch-AndroidPackage -GradlePath $androidGradle -PackageName $packageName -AppName $appNameForPlatformPatch
  if (!$skipAppNamePatch -and $platform -eq 'windows') {
    Patch-WindowsCMake -CMakePath $windowsCMake -BinaryName $windowsBinaryName
    Patch-WindowsMetadata -ResourcePath $windowsResource -AppName $appName -BinaryName $windowsBinaryName
    Patch-WindowsWindowTitle -MainCppPath $windowsMainCpp -AppName $appName
    Set-InnoDefine -Path $innoSetup -Name "MyAppName" -Value $appName
    Set-InnoDefine -Path $innoSetup -Name "MyAppExeName" -Value ($windowsBinaryName + ".exe")
    Set-InnoSetupKey -Path $innoSetup -Key "AppId" -Value $windowsAppId
    Set-InnoSetupKey -Path $innoSetup -Key "OutputBaseFilename" -Value ($windowsBinaryName + "_Setup")
  }
  Apply-IconAssets -AppDir $appDir

  if ($platform -eq 'windows') {
    if ((Test-Path $windowsCMake) -and ((Get-Content -Path $windowsCMake -Raw) -notmatch '_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS')) {
      $cmakeRaw = Get-Content -Path $windowsCMake -Raw
      Set-FileContent -Path $windowsCMake -Content ("add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)`r`n" + $cmakeRaw)
    }
    Set-InnoDefine -Path $innoSetup -Name "MyAppVersion" -Value $versionFull
  }
}
elseif ($appType -eq 'pos_logger') {
  if (Test-Path $pubspec) {
    Update-FileByRegex -Path $pubspec -Pattern '(?m)^version:\s*.*$' -Replacement "version: $versionFull" | Out-Null
  }
}

# pos_logger uses the Flutter icon layout (pos_cache) and capacitor gets its own
# repo-root layout served by the hub, so both can extract straight into $appDir.
if ($appType -ne 'hmx') {
  Apply-IconAssets -AppDir $appDir
}

if ($platform -eq 'windows') {
  $existingCL = [Environment]::GetEnvironmentVariable('CL')
  $coroutineFlag = '/D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS'
  if ([string]::IsNullOrWhiteSpace($existingCL)) {
    $env:CL = $coroutineFlag
  } elseif ($existingCL -notmatch '_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS') {
    $env:CL = "$existingCL $coroutineFlag"
  }
}

if ($platform -eq 'android') {
  Patch-AndroidGradleProperties -AppDir $appDir
  $env:GRADLE_OPTS = "-Dorg.gradle.daemon=false"
}

Push-Location $appDir
try {
  if ($appType -eq 'capacitor') {
    if ($platform -ne 'android') {
      throw "platform '$platform' is not supported for capacitor by this runner build script"
    }
    $capHubToken = Get-OptionalEnv 'POSHUB_TOKEN' ''
    $capBaseUrl = Get-OptionalEnv 'POSHUB_BASE_URL' ''
    $capConfigPath = Join-Path $appDir "capacitor.config.json"
    if (Test-Path $capConfigPath) {
      $capConfig = Get-Content -Path $capConfigPath -Raw
      $capConfig = [regex]::Replace($capConfig, '("appName"\s*:\s*")[^"]*(")', ('$1' + ($appName -replace '"', '\\"') + '$2'))
      if (![string]::IsNullOrWhiteSpace($packageName)) {
        $capConfig = [regex]::Replace($capConfig, '("appId"\s*:\s*")[^"]*(")', ('$1' + $packageName + '$2'))
      }
      if (![string]::IsNullOrWhiteSpace($capBaseUrl) -and $capConfig -match '"url"') {
        $capConfig = [regex]::Replace($capConfig, '("url"\s*:\s*")[^"]*(")', ('$1' + ($capBaseUrl -replace '"', '\\"') + '$2'))
      }
      Set-Content -Path $capConfigPath -Value $capConfig -NoNewline
    }
    $packageJsonPath = Join-Path $appDir "package.json"
    if (Test-Path $packageJsonPath) {
      try {
        $pkgObj = Get-Content -Raw -Path $packageJsonPath | ConvertFrom-Json
        $pkgObj.version = $versionFull
        $pkgObj | ConvertTo-Json -Depth 10 | Set-Content -Path $packageJsonPath
      } catch {
        Write-Warning "Could not update version in package.json: $_"
      }
    }
    $versionCode = 1
    if ($versionFull -match '\+([0-9]+)$') {
      $versionCode = [int]$Matches[1]
    } else {
      $vparts = $versionBase.Split('.')
      try { $versionCode = [int]$vparts[0] * 10000 + [int]$vparts[1] * 100 + [int]$vparts[2] } catch { $versionCode = 1 }
    }
    if ($versionCode -le 0) { $versionCode = 1 }

    $capGradle = Join-Path $appDir "android/app/build.gradle"
    if (Test-Path $capGradle) {
      $capGradleContent = Get-Content -Path $capGradle -Raw
      if (![string]::IsNullOrWhiteSpace($packageName)) {
        $capGradleContent = [regex]::Replace($capGradleContent, 'applicationId\s+"[^"]+"', 'applicationId "' + $packageName + '"')
        $capGradleContent = [regex]::Replace($capGradleContent, '(?m)(namespace\s*["''])[^"'']+(["''])', ('${1}' + $packageName + '${2}'))
      }
      $capGradleContent = [regex]::Replace($capGradleContent, '(?m)(versionCode\s*=?\s*)\d+', ('${1}' + $versionCode))
      $capGradleContent = [regex]::Replace($capGradleContent, '(?m)(versionName\s*=?\s*)["''][^"'']*["'']', ('${1}"' + $versionBase + '"'))
      Set-Content -Path $capGradle -Value $capGradleContent -NoNewline
    }
    if (![string]::IsNullOrWhiteSpace($packageName)) {
      $javaFiles = Get-ChildItem -Path (Join-Path $appDir "android/app/src/main/java") -Recurse -Filter "*.java" -ErrorAction SilentlyContinue
      foreach ($jf in $javaFiles) {
        $jc = Get-Content -Path $jf.FullName -Raw
        if ($jc -match '(?m)^\s*package\s+[^;]+;') {
          $jc = [regex]::Replace($jc, '(?m)^(\s*package\s+)[^;]+(\s*;)', ('${1}' + $packageName + '${2}'))
          Set-Content -Path $jf.FullName -Value $jc -NoNewline
        }
      }
    }
    $capStrings = Join-Path $appDir "android/app/src/main/res/values/strings.xml"
    if (Test-Path $capStrings) {
      $capStringsContent = Get-Content -Path $capStrings -Raw
      if (![string]::IsNullOrWhiteSpace($appName)) {
        $capStringsContent = [regex]::Replace($capStringsContent, '(<string name="app_name">)[^<]*(</string>)', ('$1' + $appName + '$2'))
        $capStringsContent = [regex]::Replace($capStringsContent, '(<string name="title_activity_main">)[^<]*(</string>)', ('$1' + $appName + '$2'))
      }
      if (![string]::IsNullOrWhiteSpace($packageName)) {
        $capStringsContent = [regex]::Replace($capStringsContent, '(<string name="package_name">)[^<]*(</string>)', ('$1' + $packageName + '$2'))
        $capStringsContent = [regex]::Replace($capStringsContent, '(<string name="custom_url_scheme">)[^<]*(</string>)', ('$1' + $packageName + '$2'))
      }
      Set-Content -Path $capStrings -Value $capStringsContent -NoNewline
    }
    $capPbx = Join-Path $appDir "ios/App/App.xcodeproj/project.pbxproj"
    if (Test-Path $capPbx) {
      $capPbxContent = Get-Content -Path $capPbx -Raw
      $capPbxContent = [regex]::Replace($capPbxContent, '(?m)(CURRENT_PROJECT_VERSION\s*=\s*)[^;]+;', ('${1}' + $versionCode + ';'))
      $capPbxContent = [regex]::Replace($capPbxContent, '(?m)(MARKETING_VERSION\s*=\s*)[^;]+;', ('${1}' + $versionBase + ';'))
      Set-Content -Path $capPbx -Value $capPbxContent -NoNewline
    }
    $poshubConfigPath = Join-Path $appDir "www/poshub-config.js"
    if (Test-Path $poshubConfigPath) {
      $poshubConfig = Get-Content -Path $poshubConfigPath -Raw
      foreach ($capEntry in @(
          @('webUrl', (Get-OptionalEnv 'POSHUB_BASE_URL' '')),
          @('database', (Get-OptionalEnv 'POSHUB_DATABASE' '')),
          @('posHubToken', $capHubToken),
          @('posHubClientName', (Get-OptionalEnv 'POSHUB_CLIENT_NAME' 'POS')),
          @('appVersion', $versionFull)
        )) {
        if ([string]::IsNullOrWhiteSpace([string]$capEntry[1])) { continue }
        $capKey = [regex]::Escape($capEntry[0])
        $capPattern = "(?m)(^\s*['""]?$capKey['""]?\s*:\s*)['""][^'""]*['""]"
        if (![regex]::IsMatch($poshubConfig, $capPattern)) { throw "$($capEntry[0]) field not found in www/poshub-config.js" }
        $sq = [string][char]39
        $safeVal = [string]$capEntry[1] -replace $sq, "\$sq"
        $poshubConfig = [regex]::Replace($poshubConfig, $capPattern, ('$1' + $sq + $safeVal + $sq))
      }
      Set-Content -Path $poshubConfigPath -Value $poshubConfig -NoNewline
    }
    npm install
    if ($LASTEXITCODE -ne 0) { throw "npm install failed with exit code $LASTEXITCODE" }
    npm run build
    if ($LASTEXITCODE -ne 0) { throw "npm run build failed with exit code $LASTEXITCODE" }
    npx cap sync android
    if ($LASTEXITCODE -ne 0) { throw "npx cap sync android failed with exit code $LASTEXITCODE" }
    Invoke-CapacitorGradleRelease -AppDir $appDir
    $apk = Get-ChildItem -Path (Join-Path $appDir "android/app/build/outputs") -Recurse -Filter "*.apk" |
      Where-Object { $_.Name -match "release" } |
      Select-Object -First 1
    if (!$apk) {
      throw "No release APK found after gradlew assembleRelease"
    }
    $targetName = "$safeFileName-android-$versionFull.apk"
    Copy-Item -Path $apk.FullName -Destination (Join-Path $artifactDir $targetName) -Force
  }
  elseif ($appType -eq 'pos_logger') {
    if ([string]::IsNullOrWhiteSpace($packageName)) { throw 'POSHUB_PACKAGE_NAME is required for pos_logger builds' }
    $hubToken = Get-OptionalEnv 'POSHUB_TOKEN' ''
    if ([string]::IsNullOrWhiteSpace($hubToken)) { throw 'POSHUB_TOKEN is required for pos_logger builds' }
    $appConfigPath = Join-Path $appDir "lib/constants/app_config.dart"
    $appConfig = Get-Content -Path $appConfigPath -Raw
    foreach ($entry in @(
        @('serverUrl', (Get-OptionalEnv 'POSHUB_BASE_URL' '')),
        @('database', (Get-OptionalEnv 'POSHUB_DATABASE' '')),
        @('posHubToken', $hubToken),
        @('posHubClientName', (Get-OptionalEnv 'POSHUB_CLIENT_NAME' 'POS'))
      )) {
      if ([string]::IsNullOrWhiteSpace($entry[1])) { continue }
      $appConfigPattern = "(static const String " + $entry[0] + "\s*=\s*)'[^']*'"
      if (![regex]::IsMatch($appConfig, $appConfigPattern)) { throw "$($entry[0]) field not found in app_config.dart" }
      $sq = [string][char]39
      $appConfig = [regex]::Replace($appConfig, $appConfigPattern, ('$1' + $sq + $entry[1] + $sq))
    }
    Set-Content -Path $appConfigPath -Value $appConfig -NoNewline
    $loggerGradle = Join-Path $appDir "android/app/build.gradle"
    $loggerGradleContent = Get-Content -Path $loggerGradle -Raw
    $loggerGradleContent = [regex]::Replace($loggerGradleContent, '(?m)(namespace\s*["''])[^"'']+([''"])', ('$1' + $packageName + '$2'))
    $loggerGradleContent = [regex]::Replace($loggerGradleContent, 'applicationId\s+"[^"]+"', 'applicationId "' + $packageName + '"')
    Set-Content -Path $loggerGradle -Value $loggerGradleContent -NoNewline
    $loggerAppNamesPath = Join-Path $appDir "lib/constants/app_names.dart"
    if ((Test-Path $loggerAppNamesPath) -and ![string]::IsNullOrWhiteSpace($appName)) {
      $loggerAppNames = Get-Content -Path $loggerAppNamesPath -Raw
      $sq = [string][char]39
      $safeAppName = $appName -replace $sq, "\$sq"
      $loggerAppNames = [regex]::Replace($loggerAppNames, "(static const (?:String )?applicationName\s*=\s*)'[^']*'", ('$1' + $sq + $safeAppName + $sq))
      Set-Content -Path $loggerAppNamesPath -Value $loggerAppNames -NoNewline
    }
    $loggerPubspecPath = Join-Path $appDir "pubspec.yaml"
    if (Test-Path $loggerPubspecPath) {
      $loggerPubspec = Get-Content -Path $loggerPubspecPath -Raw
      $loggerPubspec = [regex]::Replace($loggerPubspec, '(?m)^([ \t]*identity_name:[ \t]*)[^\r\n]+', ('$1' + $packageName))
      if (![string]::IsNullOrWhiteSpace($appName)) {
        $loggerPubspec = [regex]::Replace($loggerPubspec, '(?m)^([ \t]*display_name:[ \t]*)[^\r\n]+', ('$1' + $appName))
      }
      Set-Content -Path $loggerPubspecPath -Value $loggerPubspec -NoNewline
    }
    $loggerAndroidMainDir = Join-Path $appDir "android/app/src/main"
    if (Test-Path $loggerAndroidMainDir) {
      Get-ChildItem -Path $loggerAndroidMainDir -Recurse -File | Where-Object { $_.Name -in @('MainActivity.kt', 'MainActivity.java') } | ForEach-Object {
        $actContent = Get-Content -Path $_.FullName -Raw
        $actContent = [regex]::Replace($actContent, '(?m)^([ \t]*package[ \t]+)[A-Za-z0-9_.]+([ \t]*;?[ \t]*\r?)$', ('$1' + $packageName + '$2'))
        Set-Content -Path $_.FullName -Value $actContent -NoNewline
      }
    }
    $loggerManifest = Join-Path $appDir "android/app/src/main/AndroidManifest.xml"
    if (Test-Path $loggerManifest) {
      $loggerManifestContent = Get-Content -Path $loggerManifest -Raw
      $loggerManifestContent = [regex]::Replace($loggerManifestContent, '(<application[^>]*android:label=")[^"]*(")', ('$1' + $appName + '$2'))
      Set-Content -Path $loggerManifest -Value $loggerManifestContent -NoNewline
    }
    if ($platform -eq 'windows') {
      $loggerBinaryName = ($packageName.Split('.')[-1] -replace '[^a-z0-9_-]', '_').ToLower().Trim('-_')
      if ([string]::IsNullOrWhiteSpace($loggerBinaryName)) { $loggerBinaryName = 'pos' }
      Patch-WindowsCMake -CMakePath (Join-Path $appDir "windows/CMakeLists.txt") -BinaryName $loggerBinaryName
      Patch-WindowsMetadata -ResourcePath (Join-Path $appDir "windows/runner/Runner.rc") -AppName $appName -BinaryName $loggerBinaryName
      Patch-WindowsWindowTitle -MainCppPath (Join-Path $appDir "windows/runner/main.cpp") -AppName $appName
    }
    Invoke-FlutterCommand -Arguments @('install')
    Invoke-FlutterCommand -Arguments @('flutter', 'pub', 'get')
    if ($platform -eq 'android') {
      Invoke-FlutterCommand -Arguments @('flutter', 'build', 'apk', '--release')
      $apk = Join-Path $appDir "build/app/outputs/flutter-apk/app-release.apk"
      if (!(Test-Path $apk)) {
        throw "No APK found at $apk after flutter build apk"
      }
      $targetName = "$safeFileName-android-$versionFull.apk"
      Copy-Item -Path $apk -Destination (Join-Path $artifactDir $targetName) -Force
    }
    elseif ($platform -eq 'windows') {
      Invoke-FlutterCommand -Arguments @('flutter', 'build', 'windows', '--release')
      $releaseDir = Join-Path $appDir "build/windows/x64/runner/Release"
      if (!(Test-Path $releaseDir)) {
        throw "No Windows Release bundle found at $releaseDir after flutter build windows"
      }
      $targetName = "Release.zip"
      Compress-Archive -Path $releaseDir -DestinationPath (Join-Path $artifactDir $targetName) -Force
    }
    else {
      throw "platform '$platform' is not supported for pos_logger by this runner build script"
    }
  }
  else {
  Invoke-FlutterCommand -Arguments @('install')
  Invoke-FlutterCommand -Arguments @('flutter', 'pub', 'get')
  if ($platform -eq 'android') {
    Invoke-FlutterCommand -Arguments @('flutter', 'build', 'apk', '--release')
    $apk = Join-Path $appDir "build/app/outputs/flutter-apk/app-release.apk"
    if (!(Test-Path $apk)) {
      throw "No APK found at $apk after flutter build apk"
    }
    $targetName = "$safeFileName-android-$versionFull.apk"
    if ($skipAppNamePatch) {
      $targetName = "app-release.apk"
    }
    Copy-Item -Path $apk -Destination (Join-Path $artifactDir $targetName) -Force
  }
  elseif ($platform -eq 'windows') {
    Invoke-FlutterCommand -Arguments @('flutter', 'build', 'windows', '--release')

    $iscc = Find-InnoCompiler
    $isccOutput = & $iscc $innoSetup 2>&1
    $isccExitCode = $LASTEXITCODE
    $isccOutput | ForEach-Object { Write-Host $_ }
    if ($isccExitCode -ne 0) {
      throw "Inno Setup compilation failed with exit code $isccExitCode"
    }

    $installer = Find-InnoInstaller -AppDir $appDir -InnoSetupPath $innoSetup -CompilerOutput $isccOutput

    $targetName = "$safeFileName-windows-$versionFull.exe"
    if ($skipAppNamePatch) {
      $targetName = $installer.Name
    }
    Copy-Item -Path $installer.FullName -Destination (Join-Path $artifactDir $targetName) -Force
  }
  else {
    throw "platform '$platform' is not supported by this runner build script"
  }
  }
  Set-Content -Path (Join-Path $artifactDir "version.txt") -Value $versionFull -NoNewline
  Set-Content -Path (Join-Path $artifactDir "release_notes.md") -Value "# Release Notes`n`nGenerated by POS Hub Windows runner." -NoNewline
}
finally {
  Pop-Location
}
