#!/bin/bash
# ============================================================================
#  Config7x Sub Template — Installer & Configurator
#  نصب و تنظیم قالب صفحه اشتراک Config7x روی پنل 3x-ui
#
#  استفاده:
#    sudo bash install-config7x-template.sh
#
#  این اسکریپت قالب را از ریپوی گیت‌هاب دانلود می‌کند و:
#   ۱) قالب را روی پنل نصب می‌کند (فایل + تنظیمات دیتابیس 3x-ui)
#   ۲) یک منوی تعاملی برای تنظیم برند، لینک‌ها، خدمات، قیمت‌ها و رنگ حباب دارد
#
#  ریپو: https://github.com/Config7x/config7x-sub-template
# ============================================================================

THEME_DIR="/opt/3x-ui-subscription-dashboard/current/theme"
TEMPLATE_FILE="$THEME_DIR/index.html"
DB="/etc/x-ui/x-ui.db"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${CYAN}[i]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }

# ---------- checks ----------
if [ "$(id -u)" -ne 0 ]; then
  err "این اسکریپت را با sudo اجرا کنید:  sudo bash $0"
  exit 1
fi
command -v python3 >/dev/null 2>&1 || { err "python3 روی سرور پیدا نشد."; exit 1; }
[ -f "$DB" ] || { err "دیتابیس 3x-ui پیدا نشد: $DB — آیا پنل 3x-ui نصب است؟"; exit 1; }

# ---------- helpers ----------
backup_template() {
  if [ -f "$TEMPLATE_FILE" ]; then
    local b="$TEMPLATE_FILE.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$TEMPLATE_FILE" "$b" && ok "پشتیبان گرفته شد: $b"
  fi
}

ensure_template() {
  if [ ! -f "$TEMPLATE_FILE" ]; then
    err "قالب هنوز نصب نشده است! اول گزینهٔ ۱ (نصب قالب) را بزنید."
    return 1
  fi
  return 0
}

# جایگزینی سادهٔ رشته‌ای (sed) — برای لینک‌ها
sed_replace() {
  local from="$1" to="$2"
  sed -i "s|$from|$to|g" "$TEMPLATE_FILE"
}

# ---------- 1) install ----------
install_template() {
  echo
  info "در حال نصب قالب..."
  mkdir -p "$THEME_DIR"
  backup_template
  info "در حال دانلود قالب از گیت‌هاب..."
  if ! curl -fsSL "https://raw.githubusercontent.com/Config7x/config7x-sub-template/main/index.html" -o "$TEMPLATE_FILE"; then
    err "دانلود قالب انجام نشد! اتصال اینترنت سرور یا آدرس ریپو را چک کنید."
    return 1
  fi
  chmod 640 "$TEMPLATE_FILE"
  ok "فایل قالب نوشته شد: $TEMPLATE_FILE ($(du -h "$TEMPLATE_FILE" | cut -f1))"

  info "در حال تنظیم پنل 3x-ui (Profile Mode = custom)..."
  python3 - "$DB" "$THEME_DIR" <<'PYEOF'
import sqlite3, sys
db, theme = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
cur = con.cursor()
cur.execute("UPDATE settings SET value='custom' WHERE key='subProfileMode'")
cur.execute("UPDATE settings SET value=? WHERE key='subThemeDir'", (theme + "/",))
con.commit()
cur.execute("SELECT key, value FROM settings WHERE key IN ('subProfileMode','subThemeDir')")
print("  " + ", ".join(f"{k}={v}" for k, v in cur.fetchall()))
PYEOF
  ok "تنظیمات پنل ذخیره شد."

  info "ری‌استارت x-ui..."
  if systemctl restart x-ui 2>/dev/null; then ok "x-ui ری‌استارت شد."; else warn "ری‌استارت x-ui انجام نشد — دستی اجرا کنید: systemctl restart x-ui"; fi

  echo
  ok "نصب کامل شد! لینک ساب یک کاربر را در مرورگر گوشی باز کنید تا داشبورد را ببینید."
}

# ---------- 2) brand ----------
set_brand() {
  ensure_template || return
  echo
  read -rp "نام برند جدید (مثلاً MyBrand): " BRAND
  [ -z "$BRAND" ] && { warn "نام خالی است."; return; }
  local UPPER
  UPPER=$(echo "$BRAND" | tr '[:lower:]' '[:upper:]')
  backup_template
  python3 - "$TEMPLATE_FILE" "$BRAND" "$UPPER" <<'PYEOF'
import re, sys
path, brand, upper = sys.argv[1], sys.argv[2], sys.argv[3]
def _protected_lines(text):
    """Split into lines, marking the credit regions to skip."""
    lines = text.split("\n")
    out = []
    in_credit = False
    for ln in lines:
        if "CONFIG7X-CREDIT-START" in ln:
            in_credit = True
        skip = in_credit or ("pz-credit" in ln)
        out.append((ln, skip))
        if "CONFIG7X-CREDIT-END" in ln:
            in_credit = False
    return out
lines = _protected_lines(open(path, encoding="utf-8").read())
out = []
for ln, skip in lines:
    if skip:
        out.append(ln)  # امضای Config7x همیشه می‌ماند
    else:
        out.append(re.sub(r"(?<![\w./])Config7x", brand, ln))
s = "\n".join(out)
# عنوان بزرگ وسط کارت (CONFIG 7X)
s = s.replace('<div class="pz-brand-title">CONFIG 7X</div>', f'<div class="pz-brand-title">{upper}</div>')
open(path, "w", encoding="utf-8").write(s)
print(f"brand -> {brand} (credit kept as Config7x)")
PYEOF
  ok "نام برند به «$BRAND» تغییر کرد."
}

# ---------- 3-6) links ----------
# ورودی را نرمال می‌کند: @MyChannel / t.me/MyChannel / https://t.me/MyChannel -> MyChannel
normalize_user() {
  local u="$1"
  u="${u#@}"; u="${u#https://t.me/}"; u="${u#http://t.me/}"; u="${u#t.me/}"; u="${u%/}"
  echo "$u"
}

set_channel() {
  ensure_template || return
  echo
  read -rp "آیدی کانال (مثلاً CONFIG7X): " U
  U=$(normalize_user "$U"); [ -z "$U" ] && { warn "آیدی خالی است."; return; }
  backup_template
  python3 - "$TEMPLATE_FILE" "$U" <<'PYEOF'
import sys
path, new = sys.argv[1], sys.argv[2]
def _protected_lines(text):
    """Split into lines, marking the credit regions to skip."""
    lines = text.split("\n")
    out = []
    in_credit = False
    for ln in lines:
        if "CONFIG7X-CREDIT-START" in ln:
            in_credit = True
        skip = in_credit or ("pz-credit" in ln)
        out.append((ln, skip))
        if "CONFIG7X-CREDIT-END" in ln:
            in_credit = False
    return out
lines = _protected_lines(open(path, encoding="utf-8").read())
out = []
for ln, skip in lines:
    if skip:
        out.append(ln)  # امضای Config7x همیشه می‌ماند
    else:
        out.append(ln.replace("t.me/CONFIG7X", "t.me/" + new).replace("@CONFIG7X", "@" + new))
open(path, "w", encoding="utf-8").write("\n".join(out))
print(f"channel -> @{new} (credit kept as Config7x)")
PYEOF
  ok "کانال به @$U تغییر کرد."
}

set_support() {
  ensure_template || return
  echo
  read -rp "آیدی پشتیبانی (مثلاً Mld7z): " U
  U=$(normalize_user "$U"); [ -z "$U" ] && { warn "آیدی خالی است."; return; }
  backup_template
  sed_replace "t.me/Mld7z" "t.me/$U"
  sed_replace "@Mld7z" "@$U"
  ok "پشتیبانی به @$U تغییر کرد."
}

set_group() {
  ensure_template || return
  echo
  read -rp "آیدی گروه (مثلاً Config7x_Gap): " U
  U=$(normalize_user "$U"); [ -z "$U" ] && { warn "آیدی خالی است."; return; }
  backup_template
  sed_replace "t.me/Config7x_Gap" "t.me/$U"
  ok "گروه به @$U تغییر کرد."
}

set_shop() {
  ensure_template || return
  echo
  read -rp "آیدی فروشگاه/ربات فروش (مثلاً DIGI7X_APP): " U
  U=$(normalize_user "$U"); [ -z "$U" ] && { warn "آیدی خالی است."; return; }
  backup_template
  sed_replace "t.me/DIGI7X_APP" "t.me/$U"
  sed_replace "@DIGI7X_APP" "@$U"
  ok "فروشگاه به @$U تغییر کرد."
}

# ---------- 7) services ----------
edit_services() {
  ensure_template || return
  backup_template
  cat > /tmp/config7x-services.py <<'PYEOF'
import re, sys
# EOF (Ctrl+D) -> clean exit instead of a traceback
import builtins
_orig_input = builtins.input
def _safe_input(prompt=""):
    try:
        return _orig_input(prompt)
    except EOFError:
        print()
        raise SystemExit(0)
builtins.input = _safe_input
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
m = re.search(r"(const services = \[)(.*?)(\n  \];)", s, re.S)
if not m:
    print("! آرایهٔ خدمات پیدا نشد."); sys.exit(1)
block = m.group(2)
objs = re.findall(r"\{([^{}]*)\}", block)
svcs = []
for o in objs:
    d = dict(re.findall(r'(\w+):\s*"((?:[^"\\]|\\.)*)"', o))
    if d: svcs.append(d)
CLASSES = ["svc-shop", "svc-botsazan", "svc-rich", "svc-ssh"]
def save():
    global s
    lines = []
    for sv in svcs:
        lines.append('    { cls: "%s", icon: "%s", name: "%s", id: "%s", desc: "%s", url: "%s", btn: "%s" },' % (
            sv.get("cls","svc-shop"), sv.get("icon","🛒"), sv.get("name",""),
            sv.get("id",""), sv.get("desc",""), sv.get("url",""), sv.get("btn","")))
    if lines: lines[-1] = lines[-1].rstrip(",")
    new = m.group(1) + "\n" + "\n".join(lines) + m.group(3)
    s = s[:m.start()] + new + s[m.end():]
    open(path, "w", encoding="utf-8").write(s)
    print("✓ ذخیره شد.")
def ask(prompt, cur=""):
    v = input(f"{prompt} [{cur}]: ").strip()
    return v if v else cur
while True:
    print("\n--- خدمات فعلی ---")
    for i, sv in enumerate(svcs, 1):
        print(f"  {i}) {sv.get('name','')} ({sv.get('id','')})")
    print("  a) افزودن سرویس   e) ویرایش   d) حذف   q) بازگشت")
    c = input("انتخاب: ").strip().lower()
    if c == "q": break
    if c == "a":
        print("سرویس جدید (Enter = مقدار پیش‌فرض):")
        name = input("  نام سرویس: ").strip()
        if not name: print("! نام خالی است."); continue
        sv = {"cls": CLASSES[len(svcs) % len(CLASSES)],
              "icon": ask("  آیکون (ایموجی)", "🛒"),
              "name": name,
              "id": ask("  آیدی/آدرس نمایشی", ""),
              "desc": ask("  توضیح یک‌خطی", ""),
              "url": ask("  لینک", ""),
              "btn": ask("  متن دکمه", "باز کردن")}
        svcs.append(sv); save()
    elif c == "e":
        try: i = int(input("شمارهٔ سرویس: ")) - 1; sv = svcs[i]
        except (ValueError, IndexError): print("! شماره اشتباه است."); continue
        print("ویرایش (Enter = بدون تغییر):")
        sv["name"] = ask("  نام", sv.get("name",""))
        sv["id"] = ask("  آیدی/آدرس", sv.get("id",""))
        sv["desc"] = ask("  توضیح", sv.get("desc",""))
        sv["url"] = ask("  لینک", sv.get("url",""))
        sv["btn"] = ask("  متن دکمه", sv.get("btn",""))
        sv["icon"] = ask("  آیکون", sv.get("icon",""))
        print("  رنگ: 1) آبی/بنفش  2) سبز  3) صورتی  4) خاکستری")
        cc = input("  انتخاب رنگ [فعلی]: ").strip()
        if cc in "1234": sv["cls"] = CLASSES[int(cc)-1]
        save()
    elif c == "d":
        try: i = int(input("شمارهٔ سرویس برای حذف: ")) - 1
        except ValueError: print("! شماره اشتباه است."); continue
        if 0 <= i < len(svcs):
            print(f"حذف شد: {svcs[i].get('name','')}")
            del svcs[i]; save()
        else: print("! شماره اشتباه است.")
    else:
        print("! گزینهٔ نامعتبر.")
PYEOF
  python3 /tmp/config7x-services.py "$TEMPLATE_FILE"
  rm -f /tmp/config7x-services.py
}

# ---------- 8) prices ----------
edit_prices() {
  ensure_template || return
  backup_template
  cat > /tmp/config7x-prices.py <<'PYEOF'
import re, sys
# EOF (Ctrl+D) -> clean exit instead of a traceback
import builtins
_orig_input = builtins.input
def _safe_input(prompt=""):
    try:
        return _orig_input(prompt)
    except EOFError:
        print()
        raise SystemExit(0)
builtins.input = _safe_input
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
m = re.search(r"(const SERVICES_PACKAGES = \[)(.*?)(\n\];)", s, re.S)
if not m:
    print("! آرایهٔ قیمت‌ها پیدا نشد."); sys.exit(1)
block = m.group(2)
plans = []
for o in re.findall(r"\{([^{}]*)\}", block):
    d = {}
    lm = re.search(r'label:\s*"((?:[^"\\]|\\.)*)"', o); 
    if lm: d["label"] = lm.group(1)
    vm = re.search(r'volume:\s*"((?:[^"\\]|\\.)*)"', o)
    if vm: d["volume"] = vm.group(1)
    dm = re.search(r"days:\s*(\d+)", o)
    if dm: d["days"] = dm.group(1)
    pm = re.search(r"price:\s*(\d+)", o)
    if pm: d["price"] = pm.group(1)
    d["popular"] = "popular: true" in o
    if d.get("label"): plans.append(d)
def save():
    global s
    lines = []
    for p in plans:
        pop = ", popular: true" if p["popular"] else ""
        lines.append('  { label: "%s",  volume: "%s",  days: %s, price: %s%s },' % (
            p["label"], p.get("volume",""), p.get("days","30"), p.get("price","0"), pop))
    if lines: lines[-1] = lines[-1].rstrip(",")
    new = m.group(1) + "\n" + "\n".join(lines) + m.group(3)
    s = s[:m.start()] + new + s[m.end():]
    open(path, "w", encoding="utf-8").write(s)
    print("✓ ذخیره شد.")
def ask(prompt, cur=""):
    v = input(f"{prompt} [{cur}]: ").strip()
    return v if v else cur
while True:
    print("\n--- قیمت‌های فعلی ---")
    for i, p in enumerate(plans, 1):
        star = " ★ پرفروش" if p["popular"] else ""
        print(f"  {i}) {p['label']} — {p.get('volume','')} — {p.get('days','')} روز — {int(p.get('price','0')):,} تومان{star}")
    print("  a) افزودن محصول   e) ویرایش   d) حذف   q) بازگشت")
    c = input("انتخاب: ").strip().lower()
    if c == "q": break
    if c == "a":
        label = input("  نام محصول (مثلاً ۵۰ گیگ): ").strip()
        if not label: print("! نام خالی است."); continue
        p = {"label": label,
             "volume": ask("  حجم (مثلاً 50 GB)", ""),
             "days": ask("  مدت به روز", "30"),
             "price": ask("  قیمت به تومان", "0"),
             "popular": input("  پرفروش‌ترین؟ (y/N): ").strip().lower() == "y"}
        if p["popular"]:
            for q in plans: q["popular"] = False
        plans.append(p); save()
    elif c == "e":
        try: i = int(input("شمارهٔ محصول: ")) - 1; p = plans[i]
        except (ValueError, IndexError): print("! شماره اشتباه است."); continue
        p["label"] = ask("  نام", p["label"])
        p["volume"] = ask("  حجم", p.get("volume",""))
        p["days"] = ask("  مدت به روز", p.get("days","30"))
        p["price"] = ask("  قیمت به تومان", p.get("price","0"))
        pop = input(f"  پرفروش‌ترین؟ (فعلی: {'بله' if p['popular'] else 'خیر'}) (y/n/Enter): ").strip().lower()
        if pop == "y":
            for q in plans: q["popular"] = False
            p["popular"] = True
        elif pop == "n":
            p["popular"] = False
        save()
    elif c == "d":
        try: i = int(input("شمارهٔ محصول برای حذف: ")) - 1
        except ValueError: print("! شماره اشتباه است."); continue
        if 0 <= i < len(plans):
            print(f"حذف شد: {plans[i]['label']}")
            del plans[i]; save()
        else: print("! شماره اشتباه است.")
    else:
        print("! گزینهٔ نامعتبر.")
PYEOF
  python3 /tmp/config7x-prices.py "$TEMPLATE_FILE"
  rm -f /tmp/config7x-prices.py
}

# ---------- 9) ring color ----------
set_ring_color() {
  ensure_template || return
  echo
  echo "رنگ حباب مصرف:"
  echo "  1) آبی (پیش‌فرض قالب)"
  echo "  2) سبز"
  echo "  3) قرمز"
  echo "  4) بنفش"
  echo "  5) رنگ دلخواه (کد HEX مثل #ff8800)"
  echo "  6) گرادیان پیش‌فرض (فیروزه‌ای ← آبی ← بنفش ← صورتی)"
  read -rp "انتخاب: " C
  local HEX=""
  case "$C" in
    1) HEX="#4f9bff" ;;
    2) HEX="#22c55e" ;;
    3) HEX="#ef4444" ;;
    4) HEX="#8b5cf6" ;;
    5) read -rp "کد رنگ HEX (مثلاً #ff8800): " HEX ;;
    6) ;;
    *) warn "گزینهٔ نامعتبر."; return ;;
  esac
  backup_template
  if [ "$C" = "6" ]; then
    # برگرداندن گرادیان پیش‌فرض — از روی نسخهٔ سالم داخل خود اسکریپت
    python3 - "$TEMPLATE_FILE" <<'PYEOF'
import re, sys
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
fn = '''function getUsageColor(percent, unlimited = false) {
  if (unlimited) return "#4f9bff";
  const p = Math.max(0, Math.min(100, percent));
  let r, g, b;
  if (p <= 40) {
    const k = p / 40;
    r = Math.round(34 + (79 - 34) * k);
    g = Math.round(211 + (155 - 211) * k);
    b = Math.round(238 + (255 - 238) * k);
  } else if (p <= 60) {
    const k = (p - 40) / 20;
    r = Math.round(79 + (139 - 79) * k);
    g = Math.round(155 + (92 - 155) * k);
    b = Math.round(255 + (246 - 255) * k);
  } else {
    const k = (p - 60) / 40;
    r = Math.round(139 + (244 - 139) * k);
    g = Math.round(92 + (63 - 92) * k);
    b = Math.round(246 + (94 - 246) * k);
  }
  return `rgb(${r}, ${g}, ${b})`;
}'''
s2, n = re.subn(r"function getUsageColor\(percent, unlimited = false\) \{.*?\n\}", fn, s, count=1, flags=re.S)
assert n == 1, "getUsageColor not found"
open(path, "w", encoding="utf-8").write(s2)
print("ring -> default gradient")
PYEOF
    ok "گرادیان پیش‌فرض برگردانده شد."
  else
    [ -z "$HEX" ] && { warn "رنگ خالی است."; return; }
    python3 - "$TEMPLATE_FILE" "$HEX" <<'PYEOF'
import re, sys
path, hx = sys.argv[1], sys.argv[2]
s = open(path, encoding="utf-8").read()
fn = 'function getUsageColor(percent, unlimited = false) {\n  return "%s";\n}' % hx
s2, n = re.subn(r"function getUsageColor\(percent, unlimited = false\) \{.*?\n\}", fn, s, count=1, flags=re.S)
assert n == 1, "getUsageColor not found"
open(path, "w", encoding="utf-8").write(s2)
print(f"ring -> {hx}")
PYEOF
    ok "رنگ حباب به $HEX تغییر کرد."
  fi
}

# ---------- 10) show current ----------
show_current() {
  ensure_template || return
  echo
  echo -e "${BOLD}--- تنظیمات فعلی قالب ---${NC}"
  echo "برند (subscriptionHub): $(grep -o 'subscriptionHub: "[^"]*"' "$TEMPLATE_FILE" | head -1)"
  echo "عنوان بزرگ: $(grep -o '<div class="pz-brand-title">[^<]*</div>' "$TEMPLATE_FILE")"
  echo "کانال: $(grep -o 't.me/[A-Za-z0-9_]*' "$TEMPLATE_FILE" | sort -u | tr '\n' ' ')"
  echo
  echo "خدمات:"
  grep -o '{ cls: "svc-[^"]*", icon: "[^"]*", name: "[^"]*", id: "[^"]*"' "$TEMPLATE_FILE" | sed 's/{ cls: "[^"]*", icon: "[^"]*", name: "/  - /; s/", id: "/ (/' | sed 's/"$/)/'
  echo
  echo "قیمت‌ها:"
  grep -o '{ label: "[^"]*",  volume: "[^"]*",  days: [0-9]*, price: [0-9]*[^}]*}' "$TEMPLATE_FILE" | sed 's/, popular: true//; s/{ label: "/  - /; s/",  volume: "/ — /; s/",  days: / — /; s/, price: / — /; s/ },*$/ تومان/'
  echo
  echo "فایل: $TEMPLATE_FILE"
}

# ---------- menu ----------
menu() {
  while true; do
    echo
    echo -e "${BOLD}===== قالب صفحه اشتراک Config7x =====${NC}"
    echo " 1) نصب قالب روی پنل"
    echo " 2) تنظیم نام برند"
    echo " 3) تنظیم لینک کانال تلگرام"
    echo " 4) تنظیم لینک پشتیبانی"
    echo " 5) تنظیم لینک گروه"
    echo " 6) تنظیم لینک فروشگاه / ربات فروش"
    echo " 7) تنظیم خدمات (تب خدمات)"
    echo " 8) تنظیم محصولات و قیمت‌ها (تب خرید)"
    echo " 9) تنظیم رنگ حباب مصرف"
    echo "10) نمایش تنظیمات فعلی"
    echo " 0) خروج"
    echo
    read -rp "انتخاب گزینه: " CH
    case "$CH" in
      1) install_template ;;
      2) set_brand ;;
      3) set_channel ;;
      4) set_support ;;
      5) set_group ;;
      6) set_shop ;;
      7) edit_services ;;
      8) edit_prices ;;
      9) set_ring_color ;;
      10) show_current ;;
      0) echo "خدانگهدار!"; exit 0 ;;
      *) warn "گزینهٔ نامعتبر." ;;
    esac
    echo
    read -rp "Enter بزنید تا به منو برگردید..." _
  done
}

clear
echo -e "${BOLD}قالب صفحه اشتراک Config7x برای پنل 3x-ui${NC}"
echo "نصب + تنظیم از ترمینال — قبل از هر تغییر، پشتیبان گرفته می‌شود."
menu
