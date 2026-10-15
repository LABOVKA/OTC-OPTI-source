#!/usr/bin/env python3
"""Генератор лицензионных ключей (только для тебя - владельца!).

  pip install cryptography
  python keygen.py init                 # один раз: создаёт локальный private.pem и вставляет публичный ключ в Program.cs
  python keygen.py check                # проверка: совпадают ли ключи с программой
  python keygen.py make --days 30 --tier plus   # ключ PLUS на 30 дней
  python keygen.py make --days 30 --tier ultra  # ключ ULTRA на 30 дней (по умолчанию)
  python keygen.py make --lifetime --tier plus  # бессрочный ключ PLUS
  python keygen.py make --days 30 --tier ultra --discord 123456789012345678
  python keygen.py discord <CLIENT_ID>  # один раз: Discord Client ID приложения
  python keygen.py links --discord https://discord.gg/XXXX --web https://tvuj-web.cz   # ссылки в приложении
  python keygen.py publish --version 7.2 --base-url https://example.com/otc-updates --changelog "Новые функции"

Signing key and issued-key log are stored outside the source tree under %LOCALAPPDATA%\\OTC OPTI\\Signing.
Never share or upload the private key - anyone who has it can issue licenses.
"""
import argparse, base64, hashlib, json, os, re, struct, sys, time
from pathlib import Path
from urllib.parse import urlsplit
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

HERE = Path(__file__).parent
KEY_DIR = Path(os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData" / "Local"))) / "OTC OPTI" / "Signing"
PRIV = KEY_DIR / "private.pem"
SRC = next((c for c in (HERE / "OtcLoader" / "Program.cs", HERE / "Program.cs") if c.exists()), HERE / "OtcLoader" / "Program.cs")
LOG = KEY_DIR / "keys.log"

def b64url(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def load_priv():
    if not PRIV.exists():
        sys.exit("Сначала запусти: python keygen.py init")
    return serialization.load_pem_private_key(PRIV.read_bytes(), None)

def pub_of(key):
    n = key.public_key().public_numbers()
    return base64.b64encode(n.x.to_bytes(32, "big") + n.y.to_bytes(32, "big")).decode()

def current_pub(src):
    m = re.search(r'const string PUBLIC_KEY = "([^"]*)";', src)
    return m.group(1) if m else None

def init():
    if not SRC.exists():
        sys.exit("Не найден Program.cs (ищу в OtcLoader\\Program.cs и рядом с keygen.py).")
    if PRIV.exists():
        k = load_priv()
        print("private.pem уже есть - использую его.")
    else:
        k = ec.generate_private_key(ec.SECP256R1())
        PRIV.parent.mkdir(parents=True, exist_ok=True)
        PRIV.write_bytes(k.private_bytes(serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        print("Создан новый локальный ключ:", PRIV)
    pub = pub_of(k)
    s = SRC.read_text(encoding="utf-8")
    cur = current_pub(s)
    if cur is None:
        sys.exit("В Program.cs не найдена строка PUBLIC_KEY.")
    if cur.startswith("PASTE_"):
        SRC.write_text(s.replace('const string PUBLIC_KEY = "%s";' % cur, 'const string PUBLIC_KEY = "%s";' % pub), encoding="utf-8")
        print("Готово. Публичный ключ вставлен в", SRC)
        print("ТЕПЕРЬ ПЕРЕСОБЕРИ ПРОГРАММУ (1-SESTAVIT.bat), иначе ключи не будут работать.")
    elif cur == pub:
        print("Публичный ключ в Program.cs уже совпадает с private.pem. Всё в порядке.")
    else:
        sys.exit("ВНИМАНИЕ: публичный ключ в Program.cs НЕ совпадает с private.pem. Ключи будут 'неверные'.\n"
                 "Решение: удали private.pem и в Program.cs верни PASTE_PUBLIC_KEY_HERE, затем снова init - или используй оригинальный private.pem.")

def check():
    ok = True
    if not SRC.exists(): sys.exit("Не найден Program.cs")
    s = SRC.read_text(encoding="utf-8")
    cur = current_pub(s)
    print("Program.cs:", SRC)
    if not PRIV.exists():
        print("- private.pem: НЕТ (запусти init)"); ok = False
    else:
        print("- private.pem: есть")
        if cur and not cur.startswith("PASTE_"):
            same = (cur == pub_of(load_priv()))
            print("- публичный ключ в Program.cs совпадает с private.pem:", "ДА" if same else "НЕТ (ключи будут неверными!)"); ok = ok and same
        else:
            print("- публичный ключ в Program.cs: НЕ ВСТАВЛЕН (запусти init)"); ok = False
    upd = re.search(r'UPDATE_URL = "([^"]*)"', s)
    has_upd = upd and not upd.group(1).startswith("PASTE_")
    print("- Auto-update URL:", upd.group(1) if has_upd else "не задан (автообновления выключены)")
    cid = re.search(r'DISCORD_CLIENT_ID = "([^"]*)"', s)
    print("- Discord Client ID:", cid.group(1) if cid else "383226320970055681 (по умолчанию)")
    print("ИТОГ:", "всё хорошо. Пересоберите программу (1-SESTAVIT.bat)." if ok else "есть проблемы, см. выше.")

def parse_version(value):
    if not re.fullmatch(r"\d+(?:\.\d+){1,3}", value):
        raise ValueError("Версия должна состоять из 2–4 числовых частей, например 7.2.")
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (4 - len(parts))

def update_source(version, manifest_url):
    source = SRC.read_text(encoding="utf-8")
    updated, url_count = re.subn(
        r'public const string UPDATE_URL = "[^"]*";',
        lambda _: 'public const string UPDATE_URL = "%s";' % manifest_url,
        source,
    )
    updated, version_count = re.subn(
        r'public const string LAUNCHER_VERSION = "[^"]*";',
        lambda _: 'public const string LAUNCHER_VERSION = "%s";' % version,
        updated,
    )
    if url_count != 1 or version_count != 1:
        sys.exit("V Program.cs nebyly nalezeny konstanty UPDATE_URL / LAUNCHER_VERSION.")
    SRC.write_text(updated, encoding="utf-8")

def publish_update(version, base_url, changelog):
    try:
        version_parts = parse_version(version)
    except ValueError as exc:
        sys.exit(str(exc))
    parsed = urlsplit(base_url)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or
            parsed.query or parsed.fragment or any(ch in base_url for ch in ('"', "\\", "\r", "\n"))):
        sys.exit("Adresa hostingu musí být čistá HTTPS URL bez přihlašovacích údajů, query nebo fragmentu.")
    try:
        parsed.port
    except ValueError:
        sys.exit("Port v adrese hostingu není platný.")

    if not SRC.exists():
        sys.exit("Nejprve nastav program: Program.cs nebyl nalezen.")
    source = SRC.read_text(encoding="utf-8")
    current_version = re.search(r'LAUNCHER_VERSION = "([^"]*)"', source)
    if not current_version:
        sys.exit("V Program.cs nebyla nalezena LAUNCHER_VERSION.")
    try:
        if version_parts <= parse_version(current_version.group(1)):
            sys.exit("Nová verze musí být vyšší než verze v Program.cs (%s)." % current_version.group(1))
    except ValueError as exc:
        sys.exit(str(exc))

    payload = SRC.parent / "payload.ps1"
    if not payload.is_file():
        sys.exit("Vedle keygen.py nebyl nalezen payload.ps1.")
    payload_bytes = payload.read_bytes()
    if not payload_bytes:
        sys.exit("payload.ps1 je prázdný.")

    base = base_url.rstrip("/")
    manifest_url = base + "/version.json"
    payload_url = base + "/payload.ps1"
    out_dir = HERE / "dist" / "updates"
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest = {
        "version": version,
        "script_url": payload_url,
        "sha256": hashlib.sha256(payload_bytes).hexdigest(),
        "changelog": changelog,
    }

    payload_tmp = out_dir / "payload.ps1.tmp"
    manifest_tmp = out_dir / "version.json.tmp"
    try:
        payload_tmp.write_bytes(payload_bytes)
        manifest_tmp.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        payload_tmp.replace(out_dir / "payload.ps1")
        manifest_tmp.replace(out_dir / "version.json")
    finally:
        payload_tmp.unlink(missing_ok=True)
        manifest_tmp.unlink(missing_ok=True)

    update_source(version, manifest_url)
    print("Update balíček připraven:", out_dir)
    print("  version.json:", manifest_url)
    print("  payload.ps1: ", payload_url)
    print("  SHA-256:      ", manifest["sha256"])
    print("Nahraj oba soubory z dist/updates na HTTPS hosting. Pak sestav nový OTC-OPTI.exe a jednorázově ho rozešli; další změny už přijdou automaticky.")

def make(seconds, discord=None, tier="ultra", lifetime=False):
    k = load_priv()
    exp = 0xFFFFFFFF if lifetime else int(time.time()) + seconds
    if exp > 0xFFFFFFFF:
        sys.exit("Срок ключа превышает поддерживаемый диапазон.")
    tier_marker = {"plus": b"PLUS", "ultra": b"ULTR"}[tier]
    payload = struct.pack(">I", exp) + tier_marker + struct.pack(">Q", int(discord or 0))
    r, s = decode_dss_signature(k.sign(payload, ec.ECDSA(hashes.SHA256())))
    key = b64url(payload + r.to_bytes(32, "big") + s.to_bytes(32, "big"))
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a") as f:
        expiry_label = "lifetime" if lifetime else time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(exp))
        f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')}  tier={tier.upper()}  discord={discord or 'any'}  expires={expiry_label}  {key}\n")
    print("Ключ:\n" + key)
    print("Тариф:", tier.upper())
    print("Привязан к Discord ID:", discord or "нет (любой аккаунт)")
    print("\nСрок:", "бессрочно" if lifetime else time.strftime('%d.%m.%Y %H:%M:%S', time.localtime(exp)))
    return key

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init")
    sub.add_parser("check")
    u = sub.add_parser("update"); u.add_argument("url", help="HTTPS URL на version.json для автообновлений")
    pu = sub.add_parser("publish", help="собирает payload и version.json для публикации обновления")
    pu.add_argument("--version", required=True, help="новая версия, например 7.2")
    pu.add_argument("--base-url", required=True, help="HTTPS адрес папки на статическом хостинге")
    pu.add_argument("--changelog", default="", help="краткое описание изменений")
    d = sub.add_parser("discord"); d.add_argument("client_id")
    ln = sub.add_parser("links"); ln.add_argument("--discord", default=None); ln.add_argument("--web", default=None)
    m = sub.add_parser("make")
    m.add_argument("--days", type=float, default=0)
    m.add_argument("--hours", type=float, default=0)
    m.add_argument("--discord", default=None, help="Discord ID покупателя (ключ будет работать только для него)")
    m.add_argument("--tier", choices=("plus", "ultra"), default="ultra", help="уровень доступа (по умолчанию ultra)")
    m.add_argument("--lifetime", action="store_true", help="бессрочная лицензия; не используй вместе с --days / --hours")
    a = ap.parse_args()
    if a.cmd == "init": init()
    elif a.cmd == "check": check()
    elif a.cmd == "update":
        url = a.url.strip()
        parsed = urlsplit(url)
        if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or
                parsed.query or parsed.fragment or any(ch in url for ch in ('"', "\\", "\r", "\n"))):
            sys.exit("Адрес version.json должен быть чистой HTTPS-ссылкой.")
        try:
            parsed.port
        except ValueError:
            sys.exit("Port v adrese není platný.")
        if not SRC.exists():
            sys.exit("Не найден Program.cs.")
        src = SRC.read_text(encoding="utf-8")
        new_src = re.sub(r'const string UPDATE_URL = "[^"]*";',
                         lambda _: 'const string UPDATE_URL = "%s";' % url, src)
        if new_src == src:
            sys.exit("В Program.cs не найдена строка UPDATE_URL.")
        SRC.write_text(new_src, encoding="utf-8")
        print(f"Готово. URL автообновлений ({url}) успешно установлен.")
    elif a.cmd == "publish":
        publish_update(a.version, a.base_url, a.changelog)
    elif a.cmd == "links":
        import re as _re
        src = SRC.read_text(encoding="utf-8")
        for name, val in (("DISCORD_URL", a.discord), ("WEB_URL", a.web)):
            if val:
                if not val.startswith(("http://", "https://")): sys.exit(name + ": ссылка должна начинаться с http:// или https://")
                src = _re.sub(r'const string %s = "[^"]*";' % name, lambda m: 'const string %s = "%s";' % (name, val), src)
        SRC.write_text(src, encoding="utf-8")
        print("Готово. Ссылки обновлены (нужен новый build).")
    elif a.cmd == "discord":
        src = SRC.read_text(encoding="utf-8")
        cid = a.client_id.strip()
        new_src = re.sub(r'const string DISCORD_CLIENT_ID = "[^"]*";', f'const string DISCORD_CLIENT_ID = "{cid}";', src)
        if new_src == src:
            sys.exit("В Program.cs не найдена строка DISCORD_CLIENT_ID.")
        SRC.write_text(new_src, encoding="utf-8")
        print(f"Готово. Discord Client ID ({cid}) успешно установлен.")
    else:
        sec = int(a.days * 86400 + a.hours * 3600)
        if a.lifetime:
            if sec != 0: sys.exit("--lifetime нельзя использовать вместе с --days или --hours.")
            make(0, a.discord, a.tier, lifetime=True)
        else:
            if sec <= 0: sys.exit("Укажи --days или --hours")
            make(sec, a.discord, a.tier)
