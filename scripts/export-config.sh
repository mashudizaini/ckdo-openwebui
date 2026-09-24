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
FROM model WHERE id LIKE 'cochat%' ORDER BY id;
" > "$OUT/models.json"

# ── Config: hanya kunci yang pernah kita atur, bukan seluruh tabel ─────────
$PSQL -c "
SELECT jsonb_pretty(jsonb_object_agg(key, value::jsonb))
FROM config
WHERE key LIKE 'web.search.%'
   OR key LIKE 'web.loader.%'
   OR key IN ('code_execution.enable','code_interpreter.enable',
              'rag.embedding_engine','rag.embedding_model',
              'ui.default_models','user.permissions');
" > "$OUT/config.json"

echo "Diekspor ke $OUT/:"
ls -1 "$OUT"
echo
echo "Periksa dulu sebelum commit — pastikan tidak ada rahasia yang lolos:"
echo "  grep -riE 'sk-|password|secret|api_key' $OUT/ || echo '  bersih'"
