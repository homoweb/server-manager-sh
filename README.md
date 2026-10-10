<div align="center">

# 🚀 Pushit

**مدیر سرور اوبونتو در یک اسکریپت Shell تعاملی**

نصب استک، استقرار سایت با ایزوله‌سازی کامل، امن‌سازی و نگهداری سرورهای خام Ubuntu — طراحی‌شده برای میزبانی PHP و Laravel.

![shell](https://img.shields.io/badge/shell-bash-4EAA25)
![os](https://img.shields.io/badge/ubuntu-20.04%20%7C%2022.04%20%7C%2024.04-E95420)
![php](https://img.shields.io/badge/PHP-8.4-777BB4)
![stack](https://img.shields.io/badge/stack-Nginx%20%C2%B7%20MySQL%20%C2%B7%20PostgreSQL%20%C2%B7%20Redis%20%C2%B7%20Node%2022-009639)

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

> 💡 **به‌روزرسانی:** کافی است دوباره گزینه‌ی `12) Update Script` را از منو اجرا کنید تا آخرین نسخه جایگزین نسخه‌ی فعلی شود.

## 🧭 منوی اصلی

| # | گزینه | کاری که انجام می‌دهد |
|:-:|-------|----------------------|
| 0 | Exit | خروج |
| 1 | 🔁 Manage Mirrors | مدیریت میرورهای APT |
| 2 | 🧱 Install Full Stack | نصب Nginx، MySQL، PostgreSQL، PHP 8.4، Node.js 22، Composer، Redis، Supervisor، UFW، Fail2ban و Certbot |
| 3 | 🌐 Manage Sites | استقرار سایت جدید یا حذف سایت موجود |
| 4 | 🔐 Install SSL | صدور گواهینامه Let's Encrypt |
| 5 | 🛡️ Manage Firewall | مدیریت UFW و پورت‌ها |
| 6 | 🔒 Harden Server | امن‌سازی SSH با گارد ضد قفل‌شدگی |
| 7 | 🗄️ Manage DB | مدیریت MySQL و PostgreSQL؛ ساخت، لیست، حذف، تغییر رمز و بکاپ/ریستور |
| 8 | ⏰ Manage Cron | مدیریت کران‌جاب‌ها |
| 9 | ⚙️ Manage Supervisor | مدیریت ورکرها و پردازش‌ها |
| 10 | Manage DNS | مدیریت DNS سرور |
| 11 | Change Access Mode | انتخاب IP و پورت یا دامنه |
| 12 | Update Script | به‌روزرسانی اسکریپت از GitHub |
| 13 | Uninstall Pushit | حذف اسکریپت و کش |
| 14 | Manage Server AI Agent | مدیریت عامل AI سرور |

## 🌐 استقرار سایت — گزینه ۳ (قلب اسکریپت)

```
sudo pushit  →  3
--- Site Management ---
1) Create Site (Deploy)
2) Delete Site

Domain  : example.com
Username: ali
SSH     : 1) Password    2) Public Key
Deploy  : 1) Git Repo    2) ZIP Upload
Access  : 1) Public    2) PAT (HTTPS)    3) Deploy Key (SSH)
✅ Site live at /home/ali/example.com/public
```

**۱) کاربر ایزوله** — برای هر سایت یک کاربر سیستمی جداگانه با پیکربندی SSH (رمز عبور یا کلید عمومی با پرمیژن‌های استاندارد `700`/`600`). اگر سایت یکی از کاربران به خطر بیفتد، بقیه‌ی سایت‌ها دست‌نخورده می‌مانند.

**۲) دیپلوی خودکار از Git** — کلون از برنچ دلخواه در مسیر `/home/<user>/<domain>` (هم‌راستا با دیپلوی ZIP) و سپس در صورت وجود:
`composer install --no-dev --optimize-autoloader`، `npm install && npm run build` و برای Laravel ساخت `.env` از روی `.env.example` و اجرای `php artisan key:generate`.

> 🔑 **ریپوی خصوصی؟** بعد از وارد کردن URL و برنچ، مرحله‌ی **Repository access** نمایش داده می‌شود:
> **۱) Public** — کلون مستقیم. **۲) Personal Access Token** — توکن با ورودی مخفی پرسیده می‌شود (از طریق `GIT_ASKPASS`) و در هیچ فایلی — حتی `.git/config` — ذخیره نمی‌شود. **۳) SSH Deploy Key** (روش پیشنهادی) — کلید `ed25519` خودکار ساخته و کلید عمومی نمایش داده می‌شود؛ آن را در GitHub ← repo ← Settings ← Deploy keys اضافه کنید (Read-only کافی است). URL هم خودکار به فرمت SSH تبدیل می‌شود، اتصال قبل از کلون تأیید می‌شود و `git pull`های بعدی کاربر هم بدون رمز کار می‌کند.
>
> 🚫 گیت‌هاب از سال ۲۰۲۱ پسورد اکانت را برای عملیات Git قبول نمی‌کند؛ باید توکن یا کلید بدهید. اگر کلون شکست بخورد، دیپلوی با پیام راهنما متوقف می‌شود و فایل‌های قبلی سایت دست‌نخورده می‌مانند.

**۳) دیپلوی با ZIP** — نمایش دستور آماده‌ی `scp` برای آپلود، اکسترکت خودکار به `/home/<user>/<domain>` و پاک‌کردن آرشیو بعد از اتمام.

**۴) پرمیژن‌های امن** — پوشه‌ها `755`، فایل‌ها `644`، فایل‌های اجرایی (باینری‌های `node_modules/.bin`، `vendor/bin`، `artisan` و…) اجرایی می‌مانند تا `npm run build` و `./artisan` بعد از دیپلوی هم کار کنند، `.env` روی `600` قفل می‌شود و `storage` + `bootstrap/cache` روی `775`.

**۵) PHP-FPM Pool اختصاصی** — سوکت یونیکس جداگانه برای هر کاربر (`/run/php/php8.4-fpm-<user>.sock`)؛ اشباع منابع یک سایت، سایت‌های دیگر را درگیر نمی‌کند.

**۶) Vhost آماده‌ی Laravel** — روت روی `public`، هدرهای امنیتی (`X-Frame-Options`، `nosniff` و…) و مسدودسازی فایل‌های مخفی به‌جز `.well-known`.

## 🗑️ حذف سایت (گزینه ۳ ← Delete Site)

پاک‌سازی کامل و امن یک سایت فقط با وارد کردن دامنه — با تأیید دوباره (تایپ مجدد دامنه) قبل از هر تغییری:

1. کاربر ایزوله به‌صورت خودکار از روی خط `root` داخل Vhost شناسایی می‌شود (در صورت نیاز دستی پرسیده می‌شود).
2. **همیشه حذف می‌شود:** Vhost + سیم‌لینک `sites-enabled` (با ریلود Nginx) و فایل‌های سایت `/home/<user>/<domain>`.
3. **اختیاری (y/n):** حذف گواهینامه‌ی SSL آن دامنه (`certbot delete`).
4. **اختیاری (y/n):** حذف کاربر ایزوله به‌همراه PHP-FPM Pool، کران‌جاب‌ها، پروسه‌های باقی‌مانده و هوم دایرکتوری — فقط زمانی که هیچ سایت دیگری از آن کاربر استفاده نکند؛ در غیر این صورت کاربر حفظ می‌شود و فقط سایت حذف می‌شود.

## 🧱 استک نصب‌شده (گزینه ۲)

| کامپوننت | منبع |
|----------|------|
| Nginx / MySQL / PostgreSQL | مخازن رسمی اوبونتو |
| PHP 8.4 — FPM، CLI و اکستنشن‌های mysql، pgsql (شامل PDO)، redis، xml، mbstring، curl، zip، gd، bcmath | PPA ondrej |
| Node.js 22.x | NodeSource |
| Composer | آخرین نسخه‌ی پایدار |
| Redis، Supervisor، UFW، Fail2ban، Certbot | مخازن رسمی |

> 💡 اگر قبلاً Node 20 با همین روش نصب شده، اجرای دوباره‌ی گزینه ۲ مخزن NodeSource را به نسخه‌ی بالا سوئیچ و Node را ارتقا می‌دهد.

در پایان، DNS سرور روی `8.8.8.8` / `1.1.1.1` تنظیم و مشکل resolve هاست‌نیم در `sudo` نیز برطرف می‌شود.

## 🗄️ مدیریت MySQL و PostgreSQL (گزینه ۷)

ابتدا نوع دیتابیس را انتخاب کنید: `1) MySQL` یا `2) PostgreSQL`. هر دو همان شش عملیات را دارند: ساخت دیتابیس و کاربر، لیست دیتابیس‌ها، حذف با تایپ دوباره نام، تغییر رمز کاربر، دانلود بکاپ و آپلود/ریستور.

**نصب PostgreSQL:** نصب کامل استک (گزینه ۲) اکنون PostgreSQL، ابزارهای کلاینت و `php8.4-pgsql` را هم نصب می‌کند. روی سروری که قبلاً استک دارد، از `7) Manage DB → 2) PostgreSQL → 7) Install PostgreSQL` استفاده کنید؛ فقط PostgreSQL و در صورت نصب بودن PHP، درایور آن نصب می‌شود و PHP-FPM فعال ری‌استارت می‌شود. نسخه PostgreSQL از مخازن تنظیم‌شده Ubuntu نصب می‌شود. مدیریت با کاربر سیستمی `postgres` و اتصال محلی انجام می‌شود.

**دانلود (بکاپ):** دامپ فشرده `.sql.gz` ساخته می‌شود. MySQL از `mysqldump --single-transaction` به‌همراه triggers، routines و events استفاده می‌کند؛ PostgreSQL از `pg_dump --no-owner --no-acl` برای بازیابی با مالک مقصد استفاده می‌کند. فایل‌های MySQL در `/root/db-backups/` و فایل‌های PostgreSQL در `/root/db-backups/postgresql/` قرار می‌گیرند. هر دو لینک دانلود قابل استفاده تا ۱۰ دقیقه و دستور `scp` با پورت SSH صحیح نمایش می‌دهند؛ فایل بکاپ بعد از ۱۰ دقیقه پاک می‌شود.

**آپلود (ریستور):** فرمت‌های `.sql` و `.sql.gz` پشتیبانی می‌شوند. برای MySQL، دیتابیس مقصدِ جدید پس از تأیید با charset `utf8mb4` ساخته می‌شود. برای PostgreSQL، اگر مقصد موجود نباشد، نام یک کاربر دیتابیس موجود برای مالکیت آن پرسیده می‌شود؛ می‌توانید آن کاربر را از گزینه ۱ بسازید. ریستور PostgreSQL با توقف روی خطای SQL، در یک تراکنش و با نقش مالک مقصد انجام می‌شود تا جدول‌ها و sequenceها متعلق به همان کاربر باشند. پس از موفقیت، تعداد جدول‌ها نمایش داده می‌شود.

دامپ باید مربوط به همان موتور انتخاب‌شده باشد. بکاپ PostgreSQL شامل نقش‌های سراسری و رمز کاربران نیست؛ کاربر مقصد را جداگانه بسازید. برای ریستور خارجی، دامپ plain SQL بدون `CREATE DATABASE` و با `--no-owner --no-acl` تهیه کنید و از دیتابیس مقصد خالی استفاده کنید.

```bash
# آپلود فایل بکاپ از سیستم خودتان به سرور:
scp -P 22 ./backup.sql.gz root@SERVER_IP:/root/
```

اتصال Laravel به PostgreSQL پس از ساخت دیتابیس و کاربر:

```dotenv
DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=5432
DB_DATABASE=app_db
DB_USERNAME=app_user
DB_PASSWORD="your-password"
```

نام دیتابیس و کاربر PostgreSQL حداکثر ۶۳ کاراکتر و شامل حروف، رقم و زیرخط است. دیتابیس‌های سیستمی `postgres`، `template0` و `template1` و نقش `postgres` یا نقش‌های با پیشوند `pg_` در این عملیات قابل تغییر نیستند. اگر خوشه محلی روی پورت دیگری است، اسکریپت را با `sudo env PUSHIT_PG_PORT=5433 pushit` اجرا کنید و `DB_PORT` برنامه را هم مطابق آن تنظیم کنید.

### بررسی توسعه

تست واقعی PostgreSQL با یک خوشه موقت داخل `tmp/` اجرا می‌شود و به دیتابیس موجود وصل نمی‌شود. پیش‌نیاز: ابزارهای PostgreSQL (`initdb`، `pg_ctl`، `psql`، `pg_dump`)، Python 3 و `rg`. تست را با کاربر معمولی، نه root، اجرا کنید:

```bash
bash -n server_manager.sh
bash tests/postgresql.sh
```

## 🔒 امنیت

- **گارد ضد قفل‌شدگی:** گزینه ۶ قبل از هر تغییری بررسی می‌کند حداقل یک کاربر کلید SSH داشته باشد؛ در غیر این صورت بدون هیچ تغییری متوقف می‌شود.
- **بکاپ خودکار:** قبل از اعمال تغییرات از `sshd_config` با timestamp نسخه‌ی پشتیبان گرفته می‌شود (`/etc/ssh/sshd_config.bak.*`).
- **اعتبارسنجی قبل از اعمال:** کانفیگ با `sshd -t` تست می‌شود و در صورت خطا، تغییرات خودکار revert می‌شوند.
- 💡 توصیه: در گزینه ۳ روش **SSH Public Key** را انتخاب کنید تا پس از Hardening دسترسی SSH شما حفظ بماند.

## 🆘 عیب‌یابی

| مشکل | راه‌حل |
|------|--------|
| بعد از Harden وارد SSH نمی‌شوم | از یک session باز استفاده کنید: `sudo cp /etc/ssh/sshd_config.bak.<زمان> /etc/ssh/sshd_config && sudo systemctl reload ssh` |
| گواهینامه SSL صادر نمی‌شود | رکورد A دامنه باید به IP سرور اشاره کند و پورت ۸۰ باز باشد (گزینه ۵) |
| پیام `codename is not supported` هنگام نصب PHP | PPA ondrej فقط focal/jammy/noble را پشتیبانی می‌کند؛ PHP را دستی نصب و گزینه ۲ را دوباره اجرا کنید |
| Composer نصب نشد | ابتدا گزینه ۲ را کامل اجرا کنید تا PHP CLI موجود باشد |
| خطا در دانلود پکیج‌ها | با گزینه ۱ مخازن را دوباره تنظیم کنید |
| مطمئن نیستم تمدید خودکار SSL فعال است | با `certbot renew --dry-run` تست کنید و `systemctl list-timers \| grep certbot` را بررسی کنید |
| کلون گیت‌هاب خطای `Authentication failed` می‌دهد | پسورد اکانت گیت‌هاب هرگز پذیرفته نمی‌شود؛ در Repository access گزینه‌ی ۲ (Personal Access Token با دسترسی Contents: Read-only) یا ۳ (Deploy Key) را انتخاب کنید و نام برنچ (main/master) را چک کنید |
| در نصب سایت، `npm run build` با خطای `[plugin laravel:fonts] TypeError: fetch failed` (و `ETIMEDOUT`) شکست می‌خورد | پلاگین `laravel:fonts` موقع build، CSS و فایل‌های woff2 فونت را از `fonts.bunny.net` / `fonts.googleapis.com` دانلود می‌کند و سرور به این CDNها دسترسی ندارد. اتصال خروجی سرور، DNS (گزینه ۱۰) و فایروال را چک کنید؛ سپس دستور پیشنهادی خود اسکریپت را اجرا کنید: `sudo -u <user> bash -c 'cd /home/<user>/<domain> && npm install && npm run build'`. پس از یک دانلود موفق، فونت‌ها در `node_modules/.cache/laravel-vite-plugin/fonts` کش می‌شوند و buildهای بعدی بدون اینترنت کار می‌کنند. راه‌حل قطعی: در `vite.config.ts` به‌جای `bunny()`/`google()` از پکیج‌های `@fontsource/*` (که با npm install دانلود می‌شوند) استفاده کنید |
| کلون سایت خطای `fatal: Unable to read current working directory: No such file or directory` می‌دهد (با اینکه URL، برنچ و توکن درست‌اند) | شلِ اسکریپت داخل دایرکتوری‌ای ایستاده که قبلاً حذف شده (مثلاً پوشه‌ی سایتی که با گزینه‌ی ۲ پاک کرده‌اید). از منوی خارج شوید و اسکریپت را دوباره اجرا کنید — نسخه‌های جدید خودکار به دایرکتوری امن برمی‌گردند (`anchor_cwd`) و دیگر `cd` داخل پوشه‌ی سایت انجام نمی‌دهند |

## 📋 پیش‌نیازها

- Ubuntu 20.04 / 22.04 / 24.04 (سرور خام)
- دسترسی root یا sudo
- اتصال اینترنت

---

<div align="center">

ساخته‌شده با ❤️ توسط تیم **Pushit**

</div>
