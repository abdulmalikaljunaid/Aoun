# رفع APK إلى GitHub Releases
# الاستخدام: .\upload-apk-to-github.ps1 -Token "YOUR_GITHUB_TOKEN"
# المستودع: https://github.com/abdulmalikaljunaid/Aoun

param(
    [string]$Owner = "abdulmalikaljunaid",
    [string]$Repo = "Aoun",
    [string]$Token
)

if (-not $Token) {
    $Token = $env:GITHUB_TOKEN
}
if (-not $Token -and (Test-Path "$PSScriptRoot\.github-token")) {
    $Token = (Get-Content "$PSScriptRoot\.github-token" -Raw).Trim()
}
if (-not $Token -or $Token -match "PASTE_YOUR|YOUR_GITHUB|PUT_YOUR") {
    Write-Host "Error: Put your real GitHub token in .github-token (one line, ghp_...) or use -Token / GITHUB_TOKEN" -ForegroundColor Red
    exit 1
}

$apkPath = "C:\Aoun\quran_connect\aoun_v1.2.0_release.apk"
if (-not (Test-Path $apkPath)) {
    $apkPath = "C:\Aoun\quran_connect\build\app\outputs\flutter-apk\app-release.apk"
}
$tagName = "v1.2.0"
$releaseName = "Aoun v1.2.0"
$apkFileName = "aoun_v1.2.0.apk"

if (-not (Test-Path $apkPath)) {
    Write-Host "Error: APK file not found at: $apkPath" -ForegroundColor Red
    exit 1
}

$headers = @{
    "Authorization" = "Bearer $Token"
    "Accept" = "application/vnd.github.v3+json"
}

# التحقق من وجود الإصدار
$releasesUrl = "https://api.github.com/repos/$Owner/$Repo/releases"
$releases = Invoke-RestMethod -Uri $releasesUrl -Headers $headers -Method Get

$release = $releases | Where-Object { $_.tag_name -eq $tagName } | Select-Object -First 1

# إنشاء إصدار جديد إذا لم يكن موجوداً
if (-not $release) {
    Write-Host "Creating release $tagName..." -ForegroundColor Cyan
    $body = @{
        tag_name = $tagName
        name = $releaseName
        body = "Aoun - Quran Connect App`n`nVersion 1.1.0"
    } | ConvertTo-Json

    $release = Invoke-RestMethod -Uri $releasesUrl -Headers $headers -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -ContentType "application/json; charset=utf-8"
}

# حذف الملف القديم إن وُجد (لتجنب تعارض الأسماء)
$assetsUrl = "https://api.github.com/repos/$Owner/$Repo/releases/$($release.id)/assets"
$assets = Invoke-RestMethod -Uri $assetsUrl -Headers $headers -Method Get
$oldAsset = $assets | Where-Object { $_.name -eq $apkFileName } | Select-Object -First 1
if ($oldAsset) {
    Write-Host "Deleting old asset: $($oldAsset.name) (ID: $($oldAsset.id))..." -ForegroundColor Yellow
    Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/releases/assets/$($oldAsset.id)" -Headers $headers -Method Delete
    Write-Host "Deleted." -ForegroundColor Green
}

# رفع ملف APK المباشر إلى GitHub Releases
$uploadUrl = "https://uploads.github.com/repos/$Owner/$Repo/releases/$($release.id)/assets?name=$apkFileName"
Write-Host "Uploading APK ($apkFileName) to $uploadUrl ..." -ForegroundColor Cyan
$apkPathResolved = (Resolve-Path $apkPath).Path

try {
    $uploadHeaders = @{
        "Authorization" = "Bearer $Token"
        "Content-Type"  = "application/vnd.android.package-archive"
    }
    $response = Invoke-RestMethod -Uri $uploadUrl -Headers $uploadHeaders -Method Post -InFile $apkPathResolved -TimeoutSec 900
    Write-Host "✅ Upload complete!" -ForegroundColor Green
    Write-Host "Direct Download Link: $($response.browser_download_url)" -ForegroundColor Green
} catch {
    Write-Host "Invoke-RestMethod error: $_" -ForegroundColor Red
    Write-Host "Retrying with curl..." -ForegroundColor Yellow
    $curlUrl = "`"$uploadUrl`""
    $resp = & curl.exe -s -S -L -X POST `
        -H "Authorization: Bearer $Token" `
        -H "Accept: application/vnd.github.v3+json" `
        -H "Content-Type: application/vnd.android.package-archive" `
        --data-binary "@$apkPathResolved" `
        --retry 5 --retry-delay 5 `
        $uploadUrl 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Upload failed: $resp" -ForegroundColor Red
        exit 1
    }
    $response = $resp | ConvertFrom-Json
    Write-Host "✅ Upload complete via curl!" -ForegroundColor Green
    Write-Host "Direct Download Link: $($response.browser_download_url)" -ForegroundColor Green
}