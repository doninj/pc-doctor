# Compile "PC Doctor.exe" (script + logo intégrés) avec le compilateur C# fourni avec Windows.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:windir 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'make-icon.ps1') | Out-Null

$out = Join-Path $root 'PC Doctor.exe'
& $csc /nologo /target:winexe /optimize+ /platform:anycpu `
    "/out:$out" `
    "/win32icon:$(Join-Path $PSScriptRoot 'PCDoctor.ico')" `
    "/resource:$(Join-Path $root 'PCDoctor.ps1'),PCDoctor.ps1" `
    "/resource:$(Join-Path $PSScriptRoot 'PCDoctor.png'),PCDoctor.png" `
    /reference:System.Windows.Forms.dll `
    (Join-Path $PSScriptRoot 'Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw "Échec de la compilation ($LASTEXITCODE)" }
"Exécutable créé : $out ($([math]::Round((Get-Item $out).Length / 1KB)) Ko)"
