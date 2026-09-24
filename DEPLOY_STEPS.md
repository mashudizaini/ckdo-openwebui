# CKDO AI Chat Portal — Panduan Deploy

> Target server: `172.21.2.157` (Xeon E-2104G, 4GB RAM*, always-on, Docker sudah terinstall)
> Akses: LAN/VPN kantor saja, tidak publik ke internet.
>
> *df -h menunjukkan tmpfs /run=790M dan /dev/shm=3.9G, yang biasanya di-set otomatis
> 10% dan 50% dari total RAM — kemungkinan RAM fisik sebenarnya ~8GB. Cek dengan
> `free -h` untuk konfirmasi sebelum lanjut; tidak mengubah langkah di bawah, hanya
> menambah headroom.

---

## 0. Cek Prasyarat


> **PENTING — sejak 2026-09-24 compose dipecah per lingkungan.**
> `docker-compose.yml` sendiri TIDAK lengkap: volume konfigurasi SearXNG ada di
> berkas override, karena dev dan prod memasangnya dari lokasi berbeda (Docker
> dev dipasang lewat snap dan hanya boleh bind-mount dari `$HOME`). Selalu
> sertakan override yang sesuai:
>
> ```
> # produksi (172.21.2.29)
> docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
>
> # dev (172.21.2.157)
> docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d
> ```
>
> Menjalankan `docker compose up -d` tanpa override membuat SearXNG start
> dengan konfigurasi bawaan — web search akan gagal tanpa pesan yang jelas,
> karena format JSON yang dibutuhkan Open WebUI tidak aktif di situ.
>
> Sebelum start pertama di host baru, siapkan settings SearXNG-nya:
> ```
> cp searxng/settings.example.yml searxng/settings.yml
> sed -i "s|GANTI-DENGAN-HASIL-openssl-rand-hex-32|$(openssl rand -hex 32)|" searxng/settings.yml
> ```


```bash
docker --version          # sudah ada, konfirmasi versi 20+
docker compose version    # pastikan plugin compose v2 tersedia
free -h                   # konfirmasi RAM aktual
df -h /opt                # pastikan cukup ruang (target minimal 20-30GB free)
```

Karena `/opt` saat ini dipakai untuk backup sementara (475G terpakai) yang akan dihapus
setelah pindah ke Synology — pastikan penghapusan itu dilakukan dulu, atau setidaknya
ruang sisanya (296G) sudah cukup, sebelum lanjut.

---

## 1. Siapkan Direktori Project

```bash
sudo mkdir -p /opt/ckdo-chat
sudo chown $USER:$USER /opt/ckdo-chat
cd /opt/ckdo-chat
```

Upload `docker-compose.yml` dan `.env.example` ke folder ini (via `scp` dari laptop,
atau copy-paste manual dengan `nano`).

```bash
cp .env.example .env
nano .env
```

---

## 2. Isi Nilai di `.env`

### 2a. Generate secret key & password

```bash
openssl rand -hex 32
# hasilnya masukkan ke WEBUI_SECRET_KEY

openssl rand -base64 24 | tr -d '/+=@#$'
# hasilnya masukkan ke POSTGRES_PASSWORD (sudah otomatis buang karakter bermasalah)
```

### 2b. Cek IP AI Server (VM101) untuk `OLLAMA_SERVER_URL`

Dari server AI (VM101 `ai-engine`), jalankan:
```bash
hostname -I
```
Masukkan IP-nya ke `OLLAMA_SERVER_URL=http://<IP_VM101>:11434` di `.env`.

Kalau belum mau pakai fitur RAG/dokumen sama sekali di tahap awal, baris
`RAG_EMBEDDING_ENGINE` dkk di `docker-compose.yml` boleh dihapus dulu — tidak wajib
untuk chat biasa.

---

## 3. Setup Client Baru di Keycloak (realm `ckdo`)

Jangan pakai ulang client `ckdo-dashboard` — buat client terpisah supaya kalau ada
masalah konfigurasi di salah satu app, yang lain tidak ikut terganggu.

1. Login ke `https://dashboard.ckd-otto.com/auth/admin`
2. **Clients** → **Create client**
   - Client ID: `ckdo-openwebui`
   - Client authentication: **On** (confidential client)
   - Save
3. Tab **Settings**:
   | Field | Nilai |
   |---|---|
   | Valid Redirect URIs | `http://172.21.2.157:3010/oauth/oidc/callback` |
   | Web Origins | `http://172.21.2.157:3010` |
4. Tab **Credentials** → copy **Client secret** → masukkan ke `.env` sebagai
   `KEYCLOAK_CLIENT_SECRET`

> ⚠️ Redirect URI harus persis sama termasuk path `/oauth/oidc/callback` — ini path
> callback default Open WebUI untuk generic OIDC provider. Kalau beda satu karakter
> pun, login SSO akan gagal dengan error redirect_uri_mismatch.

---

## 4. Ambil API Key OpenRouter

1. Daftar/login ke https://openrouter.ai
2. **Keys** → **Create Key** → copy → masukkan ke `.env` sebagai `OPENROUTER_API_KEY`
3. **Opsional tapi disarankan untuk Claude (BYOK, hindari markup):**
   - Settings → **Integrations** → tambahkan API key Anthropic-mu sendiri
   - Setelah ini aktif, request ke model `anthropic/*` otomatis lewat key-mu sendiri,
     bukan kredit OpenRouter — kamu tetap dapat satu interface untuk semua model, tapi
     biaya Claude tetap sesuai tarif Anthropic langsung.
4. Cek dulu harga model yang mau dipakai di https://openrouter.ai/models sebelum
   diaktifkan luas ke semua department head.

---

## 5. Jalankan

```bash
cd /opt/ckdo-chat
docker compose up -d

# Monitor
docker compose ps
docker compose logs -f --tail=30
```

Tunggu sampai `ckdo-chat-postgres` berstatus `healthy` dan `ckdo-chat-webui` `Up`.

---

## 6. Verifikasi

```bash
# 1. Frontend hidup
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3010
# Harus: 200

# 2. Dari komputer lain di jaringan kantor
curl -s -o /dev/null -w "%{http_code}\n" http://172.21.2.157:3010
```

Buka `http://172.21.2.157:3010` di browser:
- Klik **Sign in with CKDO SSO** → harus redirect ke Keycloak → login → kembali ke Open WebUI.
- Login pertama akan berstatus **pending** (karena `DEFAULT_USER_ROLE=pending`) —
  approve manual di **Admin Panel → Users** sebagai admin pertama kali.
- User pertama yang mendaftar otomatis jadi admin di Open WebUI (perilaku bawaan) —
  pastikan kamu yang login duluan.
- Buka **Settings → Connections**, cek koneksi OpenRouter sudah muncul otomatis
  (dari env var). Coba chat pakai satu model dulu (mis. `anthropic/claude-sonnet-4.5`)
  untuk pastikan key valid dan biaya kepotong dari kredit OpenRouter.

---

## 7. Firewall (UFW) — batasi ke jaringan kantor saja

```bash
# Hanya izinkan dari subnet kantor, bukan dari semua IP
sudo ufw allow from 172.21.0.0/16 to any port 3010 proto tcp
sudo ufw status
```//
Sesuaikan range subnet `172.21.0.0/16` dengan subnet kantor/VPN yang sebenarnya.

---

## 8. Checklist Deploy

```
PRASYARAT
[ ] free -h dicek, RAM aktual dikonfirmasi
[ ] Ruang disk /opt cukup (>20GB free setelah backup sementara dibersihkan)

SETUP
[ ] docker-compose.yml & .env di /opt/ckdo-chat
[ ] .env terisi semua (password tanpa karakter @ # $)
[ ] Image open-webui di-pin ke versi tertentu (bukan :main)

KEYCLOAK
[ ] Client "ckdo-openwebui" dibuat terpisah dari "ckdo-dashboard"
[ ] Redirect URI persis: http://172.21.2.157:3010/oauth/oidc/callback
[ ] Client secret disalin ke .env

OPENROUTER
[ ] API key dibuat
[ ] (Opsional) BYOK Anthropic key ditambahkan untuk Claude
[ ] Harga model yang akan dipakai sudah dicek di openrouter.ai/models

JALANKAN & VERIFIKASI
[ ] docker compose up -d berhasil, kedua container healthy/Up
[ ] Login SSO berhasil, redirect balik dengan benar
[ ] User pertama (kamu) jadi admin, bisa approve user pending lain
[ ] Chat test ke minimal 1 model Claude, 1 Gemini/GPT via OpenRouter berhasil
[ ] UFW dibatasi ke subnet kantor saja

GOVERNANCE
[ ] Daftar department head yang akan diberi akses sudah disiapkan
[ ] SOP approve user baru di Admin Panel sudah disosialisasikan (siapa yang approve)
```

---

## Catatan Tambahan

- **Kenapa DEFAULT_USER_ROLE=pending + ENABLE_SIGNUP=false**: supaya siapa pun yang
  bisa reach SSO Keycloak (misalnya karyawan non-department-head yang tahu akun
  Google/Oracle-nya bisa dipakai login) tidak otomatis dapat akses chat — tetap perlu
  approve manual sekali per user baru.
- **Kenapa tidak pakai HTTPS di tahap ini**: karena akses dibatasi LAN/VPN kantor,
  bukan internet publik, HTTP polos di jaringan internal masih dalam batas wajar untuk
  tahap awal. Kalau nanti mau ditingkatkan (mis. token OIDC/API key terasa perlu
  dienkripsi in-transit juga), tinggal tambahkan reverse proxy Nginx dengan sertifikat
  self-signed atau internal CA di depan port 3010 — pola konfigurasinya sama seperti
  `nginx.prod.conf` yang sudah dipakai di Dashboard v2, tinggal disesuaikan tanpa
  Let's Encrypt (karena tidak ada domain publik yang reachable dari internet).
- **Update berkala**: `docker compose pull && docker compose up -d` — tapi karena image
  di-pin ke versi tertentu, update hanya terjadi kalau kamu sengaja naikkan nomor versi
  di `docker-compose.yml` setelah cek changelog resminya. Ini sengaja, bukan bug —
  supaya tidak ada breaking change tiba-tiba dari upstream Open WebUI.
