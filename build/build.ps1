# Compile "PC Doctor.exe" (script + logo intégrés) avec le compilateur C# fourni avec Windows.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:windir 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'make-icon.ps1') | Out-Null

$final = Join-Path $root 'PC Doctor.exe'
$out = Join-Path $root 'PC Doctor.new.exe'
# Moteur PowerShell de Windows (Windows PowerShell 5.1), intégré dans le processus de l'exe
$sma = [System.Management.Automation.PSObject].Assembly.Location
& $csc /nologo /target:winexe /optimize+ /platform:anycpu `
    "/reference:$sma" `
    "/out:$out" `
    "/win32icon:$(Join-Path $PSScriptRoot 'PCDoctor.ico')" `
    "/resource:$(Join-Path $root 'PCDoctor.ps1'),PCDoctor.ps1" `
    "/resource:$(Join-Path $PSScriptRoot 'PCDoctor.png'),PCDoctor.png" `
    /reference:System.Windows.Forms.dll `
    (Join-Path $PSScriptRoot 'Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw "Échec de la compilation ($LASTEXITCODE)" }
# Si l'ancien exe est en cours d'utilisation, on le renomme (Windows l'autorise) avant de mettre le nouveau
if (Test-Path -LiteralPath $final) {
    Remove-Item -LiteralPath "$final.old" -Force -ErrorAction SilentlyContinue
    try { Remove-Item -LiteralPath $final -Force -ErrorAction Stop } catch { Move-Item -LiteralPath $final -Destination "$final.old" -Force }
}
Move-Item -LiteralPath $out -Destination $final
"Exécutable créé : $final ($([math]::Round((Get-Item $final).Length / 1KB)) Ko)"
