# Membangun PerekamRapat.exe (single file, tanpa perlu .NET terpasang di komputer tujuan).
# Butuh: .NET 8 SDK (https://dotnet.microsoft.com/download/dotnet/8.0)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
dotnet publish PerekamRapat.csproj -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o publish
Write-Host "Selesai: $PSScriptRoot\publish\PerekamRapat.exe"
