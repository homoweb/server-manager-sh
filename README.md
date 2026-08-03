# Server Manager

اسکریپت Shell جامع برای پیکربندی، استقرار، امن‌سازی و نگهداری سرورهای خام اوبونتو جهت میزبانی پروژه‌های PHP و Laravel.

## نصب و اجرای سریع (One-Liner)

فقط با اجرای دستور زیر در سرور اوبونتو، اسکریپت دانلود و اجرا می‌شود:
```bash
bash <(curl -s https://raw.githubusercontent.com/homoweb/server-manager-sh/main/server_manager.sh)

پس از اولین اجرا، اسکریپت به صورت خودکار در سیستم نصب می‌شود. برای اجراهای بعدی، در هر مسیر از سرور فقط دستور زیر را وارد کنید:

bash
sudo lsm

## قابلیت‌ها

- **نصب پشته کامل**: Nginx, MySQL, PHP, Node.js, Composer, Git, Redis, Supervisor.
- **استقرار خودکار سایت**: ساخت کاربر ایزوله، تنظیم Nginx و PHP-FPM Pool اختصاصی.
- **مدیریت SSL**: دریافت خودکار گواهینامه رایگان Let's Encrypt با Certbot.
- **امنیت (Hardening)**: تنظیم فایروال UFW، نصب Fail2ban و ایمن‌سازی SSH.
- **بهینه‌سازی و نگهداری**: مدیریت Swap، بکاپ‌گیری هوشمند، بازیابی، تنظیم مقادیر Nginx و PHP.

## پیش‌نیازها

- اوبونتو 20.04 / 22.04 / 24.04
- دسترسی `root`


---

محل قرارگیری `install_to_bin` در فایل `server_manager.sh`:

۱. تابع را در بالای اسکریپت، بعد از بررسی دسترسی `root` و قبل از سایر توابع تعریف کن:

```bash
#!/bin/bash

# Check root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

install_to_bin() {
    if [ ! -f /usr/local/bin/lsm ]; then
        curl -s https://raw.githubusercontent.com/homoweb/server-manager-sh/main/server_manager.sh > /usr/local/bin/lsm
        chmod +x /usr/local/bin/lsm
        echo "دستور lsm برای اجرای سریع به سیستم اضافه شد."
    fi
}

# فراخوانی تابع برای نصب خودکار در اولین اجرا
install_to_bin

# ... ادامه کدهای اسکریپت و منوی اصلی ...
