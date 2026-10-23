param([string]$Configuration = 'Release')
$ErrorActionPreference = 'Stop'
$repoDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$projectPath = Join-Path $repoDir 'win/src/AQB.App/AQB.App.csproj'
[xml]$project = Get-Content -LiteralPath $projectPath
$version = $project.Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1
$artifactDir = Join-Path $repoDir "win/artifacts/v$version"
$appDir = Join-Path $artifactDir 'AIQuotaBar'
$zipPath = Join-Path $artifactDir 'AIQuotaBar-win-x64.zip'
if (Test-Path -LiteralPath $artifactDir) { throw "Output already exists: $artifactDir. Choose a fresh version or preserve the existing output elsewhere." }
dotnet publish $projectPath -c $Configuration -r win-x64 --self-contained true -o $appDir --nologo
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }
Compress-Archive -LiteralPath $appDir -DestinationPath $zipPath -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $artifactDir 'SHA256SUMS.txt'), "$hash  AIQuotaBar-win-x64.zip`n", [Text.Encoding]::ASCII)
Write-Output "Package: $zipPath"
Write-Output "SHA-256: $hash"
