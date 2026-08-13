# تعليمات نشر صفحة الهبوط على Vercel

## ✅ تم إعداد المشروع
- ✅ تم إنشاء `vercel.json` مع إعدادات الأمان والأداء
- ✅ تم إنشاء `package.json`
- ✅ تم التحقق من جميع المسارات
- ✅ تم إنشاء Git repository محلي

## الطريقة 1: استخدام Vercel CLI (الأسهل)

### الخطوة 1: تسجيل الدخول
```bash
cd C:\Aoun\quran_connect\landing-page
vercel login
```
سيتم فتح المتصفح لتسجيل الدخول تلقائياً.

### الخطوة 2: النشر
```bash
vercel --yes
```

سيتم نشر المشروع تلقائياً وستحصل على رابط مباشر مثل:
- `https://aoun-landing-page.vercel.app` أو
- `https://aoun-landing-page-[your-username].vercel.app`

## الطريقة 2: استخدام Vercel Dashboard

1. اذهب إلى [vercel.com](https://vercel.com)
2. اضغط على "Add New Project"
3. اختر "Upload" أو اربط مستودع Git
4. حدد مجلد `landing-page` كمجلد الجذر
5. اضغط "Deploy"

## الملفات المطلوبة (جاهزة)

- ✅ `vercel.json` - ملف التكوين مع إعدادات الأمان والأداء
- ✅ `package.json` - ملف تعريف المشروع
- ✅ جميع الملفات والمسارات جاهزة

## بعد النشر

بعد النشر الناجح، ستحصل على:
- رابط مباشر لصفحة الهبوط (مثل: `https://aoun-landing.vercel.app`)
- إمكانية ربط نطاق مخصص (Custom Domain)
- تحديثات تلقائية عند رفع تغييرات جديدة

## ملاحظات

- ملف APK موجود في `assets/aoun_v1.1.0.apk` وسيعمل التحميل تلقائياً
- جميع المسارات النسبية جاهزة وتعمل بشكل صحيح
- إعدادات الأمان والأداء موجودة في `vercel.json`
