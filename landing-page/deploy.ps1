# Script لنشر صفحة الهبوط على Vercel
Write-Host "`n=== نشر صفحة الهبوط على Vercel ===" -ForegroundColor Green
Write-Host "`nالخطوة 1: تسجيل الدخول" -ForegroundColor Yellow
Write-Host "سيتم فتح المتصفح لتسجيل الدخول..." -ForegroundColor Cyan
vercel login

Write-Host "`nالخطوة 2: النشر" -ForegroundColor Yellow
vercel --yes

Write-Host "`n✅ تم النشر بنجاح!" -ForegroundColor Green
Write-Host "تحقق من الرابط أعلاه لصفحة الهبوط." -ForegroundColor Cyan
