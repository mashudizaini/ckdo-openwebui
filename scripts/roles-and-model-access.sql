-- Kebijakan peran & akses model CoChat — diterapkan 2026-09-30 di dev dan prod.
--
-- Idempoten: aman dijalankan berulang. Pakai:
--   docker exec -i ckdo-chat-postgres psql -U <user> -d <db> -v ON_ERROR_STOP=1 -1 \
--       -f - < scripts/roles-and-model-access.sql
--   docker compose -f docker-compose.yml -f docker-compose.<env>.yml restart open-webui
--
-- Kenapa berkas ini ada, bukan sekadar klik di Admin Panel: peran, grant model,
-- dan default model semuanya baris database tanpa riwayat. Tiga keputusan di
-- bawah mudah terbalik diam-diam oleh orang berikutnya yang membuka UI.
--
--   1. Hanya tim IT (mashudi, utomo, itsupport) yang admin; sisanya `user`.
--      Sebelum ini KEDELAPAN akun adalah admin — bukan karena dipromosikan,
--      tapi karena ui.default_user_role di database berisi "admin" sementara
--      berkas compose menulis "pending" (jebakan PersistentConfig). Jadi ini
--      MEMPERKETAT akses, bukan melonggarkan.
--
--   2. Setiap asisten kustom terbuka untuk semua user lewat grant principal
--      '*'. Grant '*' bersifat dinamis: user baru langsung ikut tanpa perlu
--      didaftarkan satu per satu — itulah sebabnya dipakai '*' dan bukan
--      daftar user.
--
--      KECUALI keluarga ebs-* (EBS Analyst, Finance Controller, Support).
--      Ketiganya memanggil server tool ebs-data-tools / ebs-sysadmin-tools,
--      dan dashboard memeriksa ebs_chat_scope.ebs_groups pada SETIAP panggilan
--      (app/services/ebs_mart/access.py: scope_groups). Untuk user dengan
--      ebs_groups kosong — per 2026-09-30 itu ellvin, maria, dessy, tika —
--      membuka modelnya hanya memberi asisten yang menjawab 403 di tiap
--      pertanyaan. Jalur yang benar menambah akses: Setup > AI > EBS Chat
--      Access di dashboard, isi grup ebs-finance / ebs-management; anggota
--      grup Open WebUI ikut tersinkron oleh
--      backend/scripts/configure_openwebui_ebs_analyst.py.
--
--      Juga kecuali cochat-task-model: itu model internal untuk judul chat,
--      bukan asisten yang dipilih user.
--
--   3. Model dasar mentah (claude-sonnet-5, claude-haiku-4-5-*, qwen3:14b,
--      ~openai/gpt-latest) sengaja TIDAK dibuka. Tanpa system prompt dan tanpa
--      tool, tapi namanya terdengar paling hebat di daftar — user cenderung
--      memilihnya lalu kehilangan Oracle EBS maupun Company Rules tanpa tahu
--      kenapa. Kalau memang ingin dibuka, hapus syarat base_model_id di (2).
--
-- Yang TIDAK diatur di sini, dan perlu diingat: izin fitur per-grup hanya bisa
-- MENAMBAH, tidak bisa mengurangi. utils/access_control/get_permissions()
-- menggabungkan izin grup ke atas user.permissions global dengan OR. Karena
-- seluruh user.permissions global bernilai true, nilai false di grup
-- `dashboard` tidak berefek apa pun. Untuk benar-benar membatasi sesuatu,
-- kecilkan user.permissions global lalu pakai grup untuk mengembalikannya.
\set ON_ERROR_STOP on

-- (1) Peran
UPDATE "user"
   SET role = 'user', updated_at = EXTRACT(EPOCH FROM now())::bigint
 WHERE email NOT IN ('mashudi@ckd-otto.com','utomo@ckd-otto.com','itsupport@ckd-otto.com')
   AND role <> 'user';

-- (2) Grant baca untuk semua user pada setiap asisten kustom
INSERT INTO access_grant (id, resource_type, resource_id, principal_type, principal_id, permission, created_at)
SELECT gen_random_uuid()::text, 'model', m.id, 'user', '*', 'read', EXTRACT(EPOCH FROM now())::bigint
  FROM model m
 WHERE m.base_model_id IS NOT NULL AND m.base_model_id <> ''
   AND m.id NOT LIKE 'ebs-%'
   AND m.id <> 'cochat-task-model'
ON CONFLICT (resource_type, resource_id, principal_type, principal_id, permission) DO NOTHING;

-- (3) Buang grant per-user yang kini tertutup oleh '*' (sisa dari uji coba)
DELETE FROM access_grant a
 WHERE a.resource_type = 'model'
   AND a.principal_type = 'user'
   AND a.principal_id <> '*'
   AND EXISTS (SELECT 1 FROM access_grant b
                WHERE b.resource_type = 'model' AND b.resource_id = a.resource_id
                  AND b.principal_type = 'user' AND b.principal_id = '*'
                  AND b.permission = a.permission);

-- (4) Model yang dipakai user baru saat pertama membuka chat.
--     Dibaca per-permintaan lewat Config.get('ui.default_models'), dan hanya
--     muncul di /api/config untuk permintaan yang sudah login — panggilan
--     anonim mengembalikan null, itu bukan tanda gagal.
UPDATE config
   SET value = '"cochat-claude-haiku-3"'::json, updated_at = EXTRACT(EPOCH FROM now())::bigint
 WHERE key = 'ui.default_models';
