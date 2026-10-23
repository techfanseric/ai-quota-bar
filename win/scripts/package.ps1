param([string]$Configuration = 'Release', [string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$repoDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$projectPath = Join-Path $repoDir 'win/src/AQB.App/AQB.App.csproj'
[xml]$project = Get-Content -LiteralPath $projectPath
$version = $project.Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1
$artifactDir = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $repoDir "win/artifacts/v$version" }
$appDir = Join-Path $artifactDir 'AIQuotaBar'
$zipPath = Join-Path $artifactDir 'AIQuotaBar-win-x64.zip'
if (Test-Path -LiteralPath $artifactDir) { throw "Output already exists: $artifactDir. Choose a fresh version or preserve the existing output elsewhere." }
dotnet publish $projectPath -c $Configuration -r win-x64 --self-contained true -o $appDir --nologo
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in Get-ChildItem -LiteralPath $appDir -Recurse -File) {
        $relative = $file.FullName.Substring($appDir.Length + 1).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName,
            "AIQuotaBar/$relative", [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally { $archive.Dispose() }
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $artifactDir 'SHA256SUMS.txt'), "$hash  AIQuotaBar-win-x64.zip`n", [Text.Encoding]::ASCII)
Write-Output "Package: $zipPath"
Write-Output "SHA-256: $hash"
