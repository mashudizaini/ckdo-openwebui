#!/usr/bin/env bash
#
# Periksa hal-hal yang kalau rusak TIDAK terlihat dari pesan di layar.
#
# Pakai:
#   cd /opt/ckdo-chat && ./scripts/healthcheck.sh
#
# Kenapa skrip, bukan perintah satu baris: diagnosis ini butuh kutip bersarang
# (`--format '{{index .Config.Labels "..."}}'`), dan perintah seperti itu pecah
# saat disalin ke PowerShell — persis yang terjadi 2026-10-01. Satu berkas di
# repo tidak punya masalah kutip, dan bisa dipanggil dari shell apa pun:
#   ssh root@172.21.2.29 'cd /opt/ckdo-chat && ./scripts/healthcheck.sh'
#
# Keluar dengan kode != 0 kalau ada temuan, jadi aman dipakai di cron/alert.
set -uo pipefail
cd "$(dirname "$0")/.."

WEBUI=ckdo-chat-webui
CERT_PATH=/usr/local/lib/python3.11/site-packages/certifi/cacert.pem
BAD=0

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mMASALAH\033[0m %s\n' "$1"; BAD=$((BAD+1)); }
info() { printf '  ----  %s\n' "$1"; }

echo "== CoChat healthcheck — $(hostname) — $(date '+%F %H:%M %Z') =="

# 1. Override lingkungan ikut terpasang di container yang BERJALAN.
#    Ini temuan paling penting dan paling tidak terlihat: tanpa override,
#    semuanya start rapi lalu login SSO balas 500 untuk semua pengguna.
FILES=$(docker inspect "$WEBUI" 2>/dev/null \
        | grep -o 'docker-compose[a-z.]*\.yml' | sort -u | tr '\n' ' ')
case "$FILES" in
    *docker-compose.prod.yml*|*docker-compose.dev.yml*)
        ok "override terpasang: $FILES" ;;
    "") bad "container $WEBUI tidak ditemukan" ;;
    *)  bad "override TIDAK terpasang (hanya: $FILES) — jalankan: docker compose up -d" ;;
esac

# 2. Bundel CA menimpa certifi. Tanpa ini httpx menolak sertifikat
#    self-signed dashboard dan discovery OIDC gagal.
#    Sumber bundel dibaca dari mount yang benar-benar terpasang, bukan
#    diasumsikan ./certs: dev memakai path absolut /home/cochat/... karena
#    Docker-nya dari snap dan hanya boleh bind-mount dari $HOME. Menebak path
#    di sini membuat dev selalu dilaporkan rusak padahal sehat.
IN=$(docker exec "$WEBUI" grep -cE BEGIN.CERTIFICATE "$CERT_PATH" 2>/dev/null)
SRC=$(docker inspect "$WEBUI"       --format "{{range .Mounts}}{{if eq .Destination \"$CERT_PATH\"}}{{.Source}}{{end}}{{end}}" 2>/dev/null)
if [ -z "$IN" ]; then
    bad "tidak bisa membaca certifi di dalam container"
elif [ -z "$SRC" ]; then
    bad "bundel CA TIDAK ter-mount ke certifi (container pakai bawaan: $IN sertifikat)"
else
    HOST_BUNDLE=$(grep -cE BEGIN.CERTIFICATE "$SRC" 2>/dev/null || echo 0)
    if [ "$IN" = "$HOST_BUNDLE" ]; then
        ok "bundel CA terpasang ($IN sertifikat) dari $SRC"
    else
        bad "certifi di container $IN sertifikat, berkas host $SRC punya $HOST_BUNDLE — mount basi (inode berganti), perlu recreate"
    fi
fi

# 3. Login OIDC. 302 = melempar ke Keycloak (benar). 500 = rantai
#    sertifikat/discovery rusak. Inilah yang dilihat pengguna sebagai
#    "internal error", tanpa menyebut sertifikat sama sekali.
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 http://localhost:3010/oauth/oidc/login)
case "$CODE" in
    302) ok "login OIDC -> 302 (melempar ke Keycloak)" ;;
    500) bad "login OIDC -> 500 — cek 2 temuan di atas, lalu: docker logs $WEBUI | grep -i certificate" ;;
    000) bad "login OIDC tidak menjawab — container mungkin masih start (tunggu ~30s)" ;;
    *)   bad "login OIDC -> $CODE (diharapkan 302)" ;;
esac

# 4. Volume konfigurasi SearXNG — kalau hilang, web search mati tanpa
#    pesan yang jelas (format JSON tidak aktif di konfigurasi bawaan).
if docker inspect ckdo-chat-searxng 2>/dev/null | grep -q '/etc/searxng'; then
    ok "konfigurasi SearXNG ter-mount"
else
    bad "konfigurasi SearXNG TIDAK ter-mount — web search akan gagal"
fi

# 5. Versi image: yang berjalan vs yang tertulis di compose. Berbeda berarti
#    ada yang menyunting compose tanpa menerapkannya, atau sebaliknya.
RUN=$(docker inspect "$WEBUI" --format '{{.Config.Image}}' 2>/dev/null)
WANT=$(docker compose config 2>/dev/null | grep -oE 'open-webui:v[0-9.]+' | head -1)
if [ -n "$WANT" ] && [ "${RUN##*/}" = "$WANT" ]; then
    ok "versi image: $WANT"
else
    bad "image berjalan '${RUN##*/}' != compose '${WANT:-?}' — perlu docker compose up -d"
fi

# 6. Repo bersih? Suntingan tak ter-commit di server adalah bagaimana
#    bump v0.11.4 sempat hilang dari riwayat.
DIRTY=$(git status --porcelain 2>/dev/null | grep -v '^?? config/.*/access.json' | wc -l)
if [ "$DIRTY" = "0" ]; then
    ok "repo bersih di $(git log --oneline -1 2>/dev/null)"
else
    bad "$DIRTY berkas berubah tanpa commit — periksa: git status"
fi

echo
if [ "$BAD" = "0" ]; then
    echo "Semua sehat."
else
    echo "$BAD temuan. Perbaikan paling umum: cd /opt/ckdo-chat && docker compose up -d"
fi
exit "$BAD"
