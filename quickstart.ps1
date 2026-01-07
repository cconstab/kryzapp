# Quick Start Script for KRYZ
# PowerShell script to quickly set up and run the project

param(
    [Parameter(Mandatory=$false)]
    [string]$Component = "help"
)

function Show-Help {
    Write-Host "KRYZ Transmitter Monitoring System - Quick Start" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  .\quickstart.ps1 [component]" -ForegroundColor White
    Write-Host ""
    Write-Host "Components:" -ForegroundColor Yellow
    Write-Host "  setup         - Install all dependencies" -ForegroundColor White
    Write-Host "  collector     - Run SNMP collector" -ForegroundColor White
    Write-Host "  mobile        - Run mobile app" -ForegroundColor White
    Write-Host "  test          - Run tests" -ForegroundColor White
    Write-Host "  clean         - Clean build artifacts" -ForegroundColor White
    Write-Host "  help          - Show this help" -ForegroundColor White
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Yellow
    Write-Host "  .\quickstart.ps1 setup" -ForegroundColor Gray
    Write-Host "  .\quickstart.ps1 collector" -ForegroundColor Gray
    Write-Host "  .\quickstart.ps1 mobile" -ForegroundColor Gray
}

function Install-Dependencies {
    Write-Host "Installing dependencies..." -ForegroundColor Green
    
    # Check Dart
    Write-Host "`nChecking Dart SDK..." -ForegroundColor Cyan
    try {
        $dartVersion = dart --version 2>&1
        Write-Host "✓ Dart: $dartVersion" -ForegroundColor Green
    } catch {
        Write-Host "✗ Dart SDK not found. Please install from https://dart.dev" -ForegroundColor Red
        exit 1
    }
    
    # Check Flutter
    Write-Host "`nChecking Flutter SDK..." -ForegroundColor Cyan
    try {
        $flutterVersion = flutter --version 2>&1 | Select-Object -First 1
        Write-Host "✓ Flutter: $flutterVersion" -ForegroundColor Green
    } catch {
        Write-Host "✗ Flutter SDK not found. Please install from https://flutter.dev" -ForegroundColor Red
        exit 1
    }
    
    # Install shared dependencies
    Write-Host "`nInstalling shared package dependencies..." -ForegroundColor Cyan
    Push-Location shared
    dart pub get
    Pop-Location
    
    # Install collector dependencies
    Write-Host "`nInstalling collector dependencies..." -ForegroundColor Cyan
    Push-Location snmp_collector
    dart pub get
    Pop-Location
    
    # Install mobile app dependencies
    Write-Host "`nInstalling mobile app dependencies..." -ForegroundColor Cyan
    Push-Location mobile_app
    flutter pub get
    Pop-Location
    
    Write-Host "`n✓ All dependencies installed successfully!" -ForegroundColor Green
    Write-Host "`nNext steps:" -ForegroundColor Yellow
    Write-Host "  1. Get your @signs from https://atsign.com" -ForegroundColor White
    Write-Host "  2. Save .atKeys files to snmp_collector/.atsign/" -ForegroundColor White
    Write-Host "  3. Run collector: .\quickstart.ps1 collector" -ForegroundColor White
    Write-Host "  4. Run mobile app: .\quickstart.ps1 mobile" -ForegroundColor White
}

function Start-Collector {
    Write-Host "Starting SNMP Collector..." -ForegroundColor Green
    
    # Check if .atKeys file exists
    $keysPath = "snmp_collector\.atsign"
    if (-not (Test-Path $keysPath)) {
        Write-Host "Creating .atsign directory..." -ForegroundColor Yellow
        New-Item -ItemType Directory -Force -Path $keysPath | Out-Null
    }
    
    $keysFiles = Get-ChildItem -Path $keysPath -Filter "*.atKeys"
    if ($keysFiles.Count -eq 0) {
        Write-Host "`n⚠ No .atKeys file found in $keysPath" -ForegroundColor Yellow
        Write-Host "`nPlease:" -ForegroundColor White
        Write-Host "  1. Get an @sign from https://atsign.com" -ForegroundColor White
        Write-Host "  2. Download the .atKeys file" -ForegroundColor White
        Write-Host "  3. Copy it to: $keysPath" -ForegroundColor White
        Write-Host "`nFor testing, you can run with simulated data (but notifications won't work)" -ForegroundColor Yellow
        return
    }
    
    $keysFile = $keysFiles[0].FullName
    Write-Host "Using keys file: $keysFile" -ForegroundColor Cyan
    
    # Extract @sign from filename
    $atSign = $keysFiles[0].Name -replace '_key\.atKeys$', '' -replace '^@', ''
    $atSign = "@$atSign"
    
    Write-Host "atSign: $atSign" -ForegroundColor Cyan
    Write-Host "`nStarting collector (Ctrl+C to stop)..." -ForegroundColor Green
    Write-Host "----------------------------------------" -ForegroundColor Gray
    
    Push-Location snmp_collector
    dart run bin\snmp_collector.dart --atsign $atSign --keys $keysFile
    Pop-Location
}

function Start-Mobile {
    Write-Host "Starting Mobile App..." -ForegroundColor Green
    
    # Check for available devices
    Write-Host "`nChecking for devices..." -ForegroundColor Cyan
    Push-Location mobile_app
    $devices = flutter devices 2>&1
    Write-Host $devices
    
    Write-Host "`nStarting app..." -ForegroundColor Green
    Write-Host "----------------------------------------" -ForegroundColor Gray
    flutter run
    Pop-Location
}

function Run-Tests {
    Write-Host "Running tests..." -ForegroundColor Green
    
    Write-Host "`nTesting shared package..." -ForegroundColor Cyan
    Push-Location shared
    dart test
    Pop-Location
    
    Write-Host "`nTesting collector..." -ForegroundColor Cyan
    Push-Location snmp_collector
    dart test
    Pop-Location
    
    Write-Host "`nTesting mobile app..." -ForegroundColor Cyan
    Push-Location mobile_app
    flutter test
    Pop-Location
    
    Write-Host "`n✓ All tests complete!" -ForegroundColor Green
}

function Clean-Build {
    Write-Host "Cleaning build artifacts..." -ForegroundColor Green
    
    # Clean shared
    if (Test-Path "shared\.dart_tool") {
        Remove-Item -Recurse -Force "shared\.dart_tool"
    }
    if (Test-Path "shared\build") {
        Remove-Item -Recurse -Force "shared\build"
    }
    
    # Clean collector
    if (Test-Path "snmp_collector\.dart_tool") {
        Remove-Item -Recurse -Force "snmp_collector\.dart_tool"
    }
    if (Test-Path "snmp_collector\build") {
        Remove-Item -Recurse -Force "snmp_collector\build"
    }
    
    # Clean mobile app
    Push-Location mobile_app
    flutter clean
    Pop-Location
    
    Write-Host "✓ Clean complete!" -ForegroundColor Green
}

# Main script execution
switch ($Component.ToLower()) {
    "setup" { Install-Dependencies }
    "collector" { Start-Collector }
    "mobile" { Start-Mobile }
    "test" { Run-Tests }
    "clean" { Clean-Build }
    "help" { Show-Help }
    default { 
        Write-Host "Unknown component: $Component" -ForegroundColor Red
        Write-Host ""
        Show-Help 
    }
}
