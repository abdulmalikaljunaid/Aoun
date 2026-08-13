@echo off
echo.
echo === نشر صفحة الهبوط على Vercel ===
echo.
echo الخطوة 1: تسجيل الدخول
echo سيتم فتح المتصفح لتسجيل الدخول...
vercel login

echo.
echo الخطوة 2: النشر
vercel --yes

echo.
echo ✅ تم النشر بنجاح!
echo تحقق من الرابط أعلاه لصفحة الهبوط.
pause
