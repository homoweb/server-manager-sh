<div align="center">

# 🚀 Pushit

**مدیر سرور اوبونتو در یک اسکریپت Shell تعاملی**

نصب استک، استقرار سایت با ایزوله‌سازی کامل، امن‌سازی و نگهداری سرورهای خام Ubuntu — طراحی‌شده برای میزبانی PHP و Laravel.

![shell](https://img.shields.io/badge/shell-bash-4EAA25)
![os](https://img.shields.io/badge/ubuntu-20.04%20%7C%2022.04%20%7C%2024.04-E95420)
![php](https://img.shields.io/badge/PHP-8.4-777BB4)
![stack](https://img.shields.io/badge/stack-Nginx%20%C2%B7%20MySQL%20%C2%B7%20Redis%20%C2%B7%20Node%2020-009639)

</div>

## ⚡ شروع سریع

در سرور اوبونتو فقط همین یک دستور را اجرا کنید:

```bash
bash <(curl -s https://raw.githubusercontent.com/homoweb/server-manager-sh/main/server_manager.sh)
```

اسکریپت دانلود و اجرا می‌شود و در پایان به‌صورت خودکار در مسیر `/usr/local/bin/pushit` نصب می‌شود. از این به بعد در هر مسیری از سرور کافی است بنویسید:

```bash
sudo pushit
```

> 💡 **به‌روزرسانی:** کافی است دوباره گزینه‌ی `1) Install to /usr/local/bin (pushit)` را از منو اجرا کنید تا آخرین نسخه جایگزین نسخه‌ی فعلی شود.

## 🧭 منوی اصلی

| # | گزینه | کاری که انجام می‌دهد |
|:-:|-------|----------------------|
| 1 | 📥 Install to /usr/local/bin | نصب/به‌روزرسانی اسکریپت به‌صورت دستور سراسری `pushit` |
| 2 | 🔁 Change Mirror | سوئیچ مخازن APT به میرور داخلی `repo.abrha.net` (با پشتیبانی از فرمت deb822 در Ubuntu 24.04) |
| 3 | 🧱 Install Full Stack | نصب کامل: Nginx، MySQL، PHP 8.4، Node.js 20، Composer، Redis، Supervisor، UFW، Fail2ban و Certbot |
| 4 | 🌐 Deploy Site | استقرار سایت با کاربر ایزوله، PHP-FPM Pool اختصاصی و Vhost آماده‌ی Laravel — از Git یا ZIP |
| 5 | 🔐 Install SSL | صدور گواهینامه‌ی رایگان Let's Encrypt با یک ورودی ساده؛ تمدید خودکار (certbot timer) |
| 6 | 🛡️ Manage Firewall | فعال‌سازی UFW با قوانین پیش‌فرض و باز/بستن هر پورت |
| 7 | 🔒 Harden Server | بستن لاگین مستقیم root و غیرفعال‌کردن ورود با رمز عبور در SSH (به‌همراه گارد ضد قفل‌شدگی) |
| 8 | 🗄️ Manage DB | ساخت/لیست/حذف دیتابیس، ساخت یوزر، تغییر رمز و بکاپ/ریستور (دانلود و آپلود دامپ) |
| 9 | ⏰ Manage Cron | مدیریت کران‌جاب هر کاربر: لیست، افزودن، حذف |
| 10 | ⚙️ Manage Supervisor | مدیریت ورکرها و پردازش‌ها: لیست، افزودن (با numprocs)، حذف |

## 🌐 استقرار سایت — گزینه ۴ (قلب اسکریپت)

```
sudo pushit  →  4
Domain  : example.com
Username: ali
SSH     : 1) Password    2) Public Key
Deploy  : 1) Git Repo    2) ZIP Upload
✅ Site live at /home/ali/example.com/public
```

**۱) کاربر ایزوله** — برای هر سایت یک کاربر سیستمی جداگانه با پیکربندی SSH (رمز عبور یا کلید عمومی با پرمیژن‌های استاندارد `700`/`600`). اگر سایت یکی از کاربران به خطر بیفتد، بقیه‌ی سایت‌ها دست‌نخورده می‌مانند.

**۲) دیپلوی خودکار از Git** — کلون از برنچ دلخواه و سپس در صورت وجود:
`composer install --no-dev --optimize-autoloader`، `npm install && npm run build` و برای Laravel ساخت `.env` از روی `.env.example` و اجرای `php artisan key:generate`.

**۳) دیپلوی با ZIP** — نمایش دستور آماده‌ی `scp` برای آپلود، اکسترکت خودکار به `/home/<user>/<domain>` و پاک‌کردن آرشیو بعد از اتمام.

**۴) پرمیژن‌های امن** — پوشه‌ها `755`، فایل‌ها `644` و `storage` + `bootstrap/cache` روی `775`.

**۵) PHP-FPM Pool اختصاصی** — سوکت یونیکس جداگانه برای هر کاربر (`/run/php/php8.4-fpm-<user>.sock`)؛ اشباع منابع یک سایت، سایت‌های دیگر را درگیر نمی‌کند.

**۶) Vhost آماده‌ی Laravel** — روت روی `public`، هدرهای امنیتی (`X-Frame-Options`، `nosniff` و…) و مسدودسازی فایل‌های مخفی به‌جز `.well-known`.

## 🧱 استک نصب‌شده (گزینه ۳)

| کامپوننت | منبع |
|----------|------|
| Nginx / MySQL | مخازن رسمی اوبونتو |
| PHP 8.4 — FPM، CLI و اکستنشن‌های mysql، redis، xml، mbstring، curl، zip، gd، bcmath | PPA ondrej |
| Node.js 20.x | NodeSource |
| Composer | آخرین نسخه‌ی پایدار |
| Redis، Supervisor، UFW، Fail2ban، Certbot | مخازن رسمی |

در پایان، DNS سرور روی `8.8.8.8` / `1.1.1.1` تنظیم و مشکل resolve هاست‌نیم در `sudo` نیز برطرف می‌شود.

## 🗄️ بکاپ و ریستور دیتابیس (گزینه ۸)

**دانلود (بکاپ):** از دیتابیس انتخاب‌شده یک دامپ فشرده‌ی `.sql.gz` ساخته می‌شود — با `mysqldump --single-transaction` بدون قفل‌کردن جداول InnoDB و به‌همراه triggers، routines و events — در مسیر `/root/db-backups/` ذخیره می‌شود و سپس دستور آماده‌ی `scp` برای دانلود به سیستم شما نمایش داده می‌شود.

**آپلود (ریستور):** فایل بکاپ را روی سرور آپلود کنید و مسیر آن را وارد کنید؛ فرمت‌های `.sql` و `.sql.gz` پشتیبانی می‌شوند و اگر دیتابیس مقصد وجود نداشته باشد، خودکار با charset `utf8mb4` ساخته می‌شود. پس از ایمپورت، تعداد جداول دیتابیس نمایش داده می‌شود.

```bash
# آپلود فایل بکاپ از سیستم خودتان به سرور:
scp ./backup.sql.gz root@SERVER_IP:/root/
```

## 🔒 امنیت

- **گارد ضد قفل‌شدگی:** گزینه ۷ قبل از هر تغییری بررسی می‌کند حداقل یک کاربر کلید SSH داشته باشد؛ در غیر این صورت بدون هیچ تغییری متوقف می‌شود.
- **بکاپ خودکار:** قبل از اعمال تغییرات از `sshd_config` با timestamp نسخه‌ی پشتیبان گرفته می‌شود (`/etc/ssh/sshd_config.bak.*`).
- **اعتبارسنجی قبل از اعمال:** کانفیگ با `sshd -t` تست می‌شود و در صورت خطا، تغییرات خودکار revert می‌شوند.
- 💡 توصیه: در گزینه ۴ روش **SSH Public Key** را انتخاب کنید تا پس از Hardening دسترسی SSH شما حفظ بماند.

## 🆘 عیب‌یابی

| مشکل | راه‌حل |
|------|--------|
| بعد از Harden وارد SSH نمی‌شوم | از یک session باز استفاده کنید: `sudo cp /etc/ssh/sshd_config.bak.<زمان> /etc/ssh/sshd_config && sudo systemctl reload ssh` |
| گواهینامه SSL صادر نمی‌شود | رکورد A دامنه باید به IP سرور اشاره کند و پورت ۸۰ باز باشد (گزینه ۶) |
| پیام `codename is not supported` هنگام نصب PHP | PPA ondrej فقط focal/jammy/noble را پشتیبانی می‌کند؛ PHP را دستی نصب و گزینه ۳ را دوباره اجرا کنید |
| Composer نصب نشد | ابتدا گزینه ۳ را کامل اجرا کنید تا PHP CLI موجود باشد |
| خطا در دانلود پکیج‌ها | با گزینه ۲ مخازن را دوباره تنظیم کنید |
| مطمئن نیستم تمدید خودکار SSL فعال است | با `certbot renew --dry-run` تست کنید و `systemctl list-timers \| grep certbot` را بررسی کنید |

## 📋 پیش‌نیازها

- Ubuntu 20.04 / 22.04 / 24.04 (سرور خام)
- دسترسی root یا sudo
- اتصال اینترنت

---

<div align="center">

ساخته‌شده با ❤️ توسط تیم **Pushit**

</div>
