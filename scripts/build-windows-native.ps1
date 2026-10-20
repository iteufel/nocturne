param([ValidateSet('x64', 'arm64')][string]$Architecture = 'x64', [switch]$SkipTests)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Build native Windows media and remote transport on Windows with Visual Studio C++ and Rust installed.' }
$root = Split-Path $PSScriptRoot -Parent
$build = Join-Path $root ".build/WindowsNative-build-$Architecture"
$output = Join-Path $root ".build/WindowsNative/$Architecture"
$platform = if ($Architecture -eq 'arm64') { 'ARM64' } else { 'x64' }
& cmake -S (Join-Path $root 'Windows/Nocturne.Native') -B $build -A $platform
if ($LASTEXITCODE -ne 0) { throw 'Native Windows media configuration failed.' }
& cmake --build $build --config Release --parallel 2
if ($LASTEXITCODE -ne 0) { throw 'Native Windows media compilation failed.' }
if (-not $SkipTests) {
    & ctest --test-dir $build -C Release --output-on-failure
    if ($LASTEXITCODE -ne 0) { throw 'Native Windows media tests failed.' }
}
$target = if ($Architecture -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
& rustup target add $target
if ($LASTEXITCODE -ne 0) { throw 'The Windows Rust target could not be installed.' }
$previousRustFlags = $env:RUSTFLAGS
try {
    $env:RUSTFLAGS = '-C target-feature=+crt-static'
    & cargo rustc --manifest-path (Join-Path $root 'remote/Cargo.toml') --locked --release -p nocturne-remote --lib --target $target --crate-type cdylib
    if ($LASTEXITCODE -ne 0) { throw 'The Windows QUIC transport could not be built.' }
} finally { $env:RUSTFLAGS = $previousRustFlags }
New-Item -ItemType Directory -Force $output | Out-Null
Copy-Item (Join-Path $build 'Release/nocturne_host.dll') $output -Force
if (-not $SkipTests) { Copy-Item (Join-Path $build 'native-h264-frame.bin') $output -Force }
Copy-Item (Join-Path $root "remote/target/$target/release/nocturne_remote.dll") $output -Force
Write-Host "Native Windows libraries: $output"
