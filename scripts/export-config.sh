#!/usr/bin/env bash
#
# Ekspor konfigurasi runtime CoChat dari Postgres ke berkas JSON di config/,
# supaya bisa di-commit.
#
# Kenapa ini ada: Open WebUI menyimpan hampir semua yang kita atur di dalam
# database, bukan di berkas. Kode tool ask_oracle_ebs, deskripsi yang dibaca
# model (kolom specs), URL valve, definisi tiap asisten beserta base_model_id
# dan toolIds, setelan web search — semuanya baris tabel. Tanpa ekspor, satu
# hari kerja mengatur CoChat tidak punya riwayat, tidak bisa di-review, dan
# tidak bisa dipulihkan selain mengulang dari ingatan.
#
# Ini ekspor SATU ARAH, sengaja. Berkas hasilnya untuk dibaca, dibandingkan,
# dan dipulihkan manual — bukan untuk diterapkan otomatis. Menerapkan
# konfigurasi dev ke prod begitu saja akan menimpa URL valve prod dengan milik
# dev, dan itu persis kesalahan yang pernah membuat CoChat prod memanggil
# dashboard dev berbulan-bulan.
#
# Nilai rahasia disamarkan: valve dashboard_api_key tidak ikut keluar.
#
# Pakai:
#   ./scripts/export-config.sh dev     # atau: prod
#
set -euo pipefail

ENV_NAME="${1:-}"
if [[ "$ENV_NAME" != "dev" && "$ENV_NAME" != "prod" ]]; then
    echo "Pakai: $0 <dev|prod>" >&2
    exit 1
fi

cd "$(dirname "$0")/.."
OUT="config/$ENV_NAME"
mkdir -p "$OUT"

PG_USER="$(grep '^POSTGRES_USER=' .env | cut -d= -f2-)"
PG_DB="$(grep '^POSTGRES_DB=' .env | cut -d= -f2-)"
PSQL="docker exec -i ckdo-chat-postgres psql -U $PG_USER -d $PG_DB -tA"

# ── Tool: kode + spesifikasi + valve (kunci disamarkan) ────────────────────
$PSQL -c "
SELECT jsonb_pretty(jsonb_build_object(
  'id', id, 'name', name,
  'specs', specs::jsonb,
  'valves', (valves::jsonb) - 'dashboard_api_key',
  'catatan', 'dashboard_api_key sengaja tidak diekspor'
))
FROM tool ORDER BY id;
" > "$OUT/tools.json"

$PSQL -c "SELECT content FROM tool WHERE id = 'oracle_ebs_query';" \
    > "$OUT/tool-oracle_ebs_query.py"

# ── Model: asisten kustom saja; model dari koneksi tidak perlu ─────────────
$PSQL -c "
SELECT jsonb_pretty(jsonb_build_object(
  'id', id, 'name', name, 'base_model_id', base_model_id,
  'is_active', is_active,
  'params', params::jsonb,
  'meta', meta::jsonb
))
FROM model WHERE id LIKE 'cochat%' OR id IN ('ebs-analyst', 'ebs-support', 'ebs-finance-controller') ORDER BY id;
" > "$OUT/models.json"

# ── EBS Analyst (Blueprint AI Chat Oracle EBS): tool server, functions,
#    skills, prompts. Sumbernya openwebui_kit/ di repo dashboard dan dipasang
#    oleh backend/scripts/configure_openwebui_ebs_analyst.py di sana; ekspor
#    ini untuk melihat apa yang benar-benar aktif di instance. Kunci bearer
#    tool server dan valve service_key tidak ikut.
$PSQL -c "
SELECT jsonb_pretty(COALESCE(jsonb_agg(c - 'key'), '[]'::jsonb))
FROM config, jsonb_array_elements(value::jsonb) c
WHERE key = 'tool_server.connections';
" > "$OUT/tool-servers.json"

$PSQL -c "
SELECT jsonb_pretty(jsonb_build_object(
  'id', id, 'name', name, 'type', type, 'is_active', is_active, 'is_global', is_global,
  'meta', meta::jsonb,
  'valves', COALESCE(valves::jsonb, '{}'::jsonb) - 'service_key',
  'catatan', 'service_key sengaja tidak diekspor; kode ada di function-<id>.py'
))
FROM function ORDER BY id;
" > "$OUT/functions.json"

for fid in $($PSQL -c "SELECT id FROM function ORDER BY id;"); do
    $PSQL -c "SELECT content FROM function WHERE id = '$fid';" > "$OUT/function-$fid.py"
done

$PSQL -c "
SELECT jsonb_pretty(jsonb_build_object(
  'id', id, 'name', name, 'description', description, 'is_active', is_active,
  'meta', meta::jsonb, 'content', content
))
FROM skill ORDER BY id;
" > "$OUT/skills.json"

$PSQL -c "
SELECT jsonb_pretty(jsonb_build_object('command', command, 'name', name, 'content', content))
FROM prompt ORDER BY command;
" > "$OUT/prompts.json"

# ── Peran user + siapa boleh memakai model/skill/tool apa ──────────────────
#
# Ditambahkan 2026-09-30 bersama scripts/roles-and-model-access.sql. Tanpa ini
# kebijakan akses tidak punya riwayat: peran ada di tabel `user`, dan grant ada
# di `access_grant` — tak satu pun terlihat di models.json maupun config.json,
# dan keduanya bisa diubah dengan beberapa klik di Admin Panel.
#
# principal_id '*' berarti "semua user" dan bersifat dinamis: user baru ikut
# tanpa didaftarkan. id user/grup mentah tidak berguna saat dibaca manusia, jadi
# diterjemahkan ke email dan nama grup.
#
# Satu-satunya keluaran yang TIDAK dilacak git (lihat .gitignore): berkas ini
# adalah daftar karyawan. Untuk dibaca dan dibandingkan di server; kebijakan
# yang menghasilkannya ada di scripts/roles-and-model-access.sql.
$PSQL -c "
SELECT jsonb_pretty(jsonb_build_object(
  'catatan', 'peran & grant akses; principal * = semua user. Lihat scripts/roles-and-model-access.sql',
  'peran', (SELECT jsonb_object_agg(email, role) FROM \"user\"),
  'grup', (SELECT jsonb_object_agg(g.name, COALESCE(anggota, '[]'::jsonb))
             FROM \"group\" g
             LEFT JOIN (SELECT m.group_id, jsonb_agg(u.email ORDER BY u.email) AS anggota
                          FROM group_member m JOIN \"user\" u ON u.id = m.user_id
                         GROUP BY m.group_id) x ON x.group_id = g.id),
  'grant', (SELECT jsonb_object_agg(resource_type, per_type)
              FROM (SELECT a.resource_type,
                           jsonb_object_agg(a.resource_id, principals) AS per_type
                      FROM (SELECT resource_type, resource_id,
                                   jsonb_agg(DISTINCT CASE
                                     WHEN principal_id = '*' THEN '*'
                                     WHEN principal_type = 'group' THEN 'grup:' || COALESCE(g.name, principal_id)
                                     ELSE COALESCE(u.email, principal_id) END || ':' || permission) AS principals
                              FROM access_grant a
                              LEFT JOIN \"group\" g ON g.id = a.principal_id
                              LEFT JOIN \"user\" u ON u.id = a.principal_id
                             GROUP BY resource_type, resource_id) a
                     GROUP BY a.resource_type) t)
));
" > "$OUT/access.json"

# ── Config: hanya kunci yang pernah kita atur, bukan seluruh tabel ─────────
$PSQL -c "
SELECT jsonb_pretty(jsonb_object_agg(key, value::jsonb))
FROM config
WHERE key LIKE 'web.search.%'
   OR key LIKE 'web.loader.%'
   OR key IN ('code_execution.enable','code_interpreter.enable',
              'rag.embedding_engine','rag.embedding_model',
              'ui.default_models','user.permissions',
              -- Kebijakan login. Ditambahkan 2026-09-30 setelah mematikan form
              -- login lokal dan mengubah peran default: keduanya PersistentConfig,
              -- jadi berkas compose tidak mencerminkan apa yang berlaku. Justru
              -- kunci-kunci inilah yang paling perlu punya riwayat.
              'ui.enable_login_form','ui.enable_signup','ui.default_user_role',
              'auth.enable_api_keys');
" > "$OUT/config.json"

echo "Diekspor ke $OUT/:"
ls -1 "$OUT"
echo
echo "Periksa dulu sebelum commit — pastikan tidak ada rahasia yang lolos:"
echo "  grep -riE 'sk-|password|secret|api_key' $OUT/ || echo '  bersih'"
