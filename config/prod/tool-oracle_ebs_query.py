import time

import requests
from pydantic import BaseModel, Field


class Tools:
    class Valves(BaseModel):
        dashboard_api_url: str = Field(
            default="", description="URL endpoint /api/ebs/chat"
        )
        dashboard_api_key: str = Field(
            default="", description="Service key dari tim Dashboard"
        )

    def __init__(self):
        self.valves = self.Valves()

    async def ask_oracle_ebs(self, question: str, __user__: dict) -> str:
        """
        Tanya data Oracle EBS maupun kondisi infrastruktur yang menjalankannya,
        sesuai hak akses user yang sedang chat.

        Data bisnis: penjualan, COGS/margin, produksi, budget, AR/AP,
        persediaan, purchase order, headcount, daftar karyawan.

        Infrastruktur/DBA (hanya untuk user yang diberi akses IT): pemakaian
        tablespace Oracle beserta trennya, CPU/memori/load server database dan
        aplikasi, pemakaian disk per mount point, jumlah sesi Oracle dan
        antrean concurrent request. Pakai tool ini juga untuk pertanyaan
        seperti tablespace yang hampir penuh, partisi yang kehabisan ruang,
        atau beban CPU server.
        :param question: pertanyaan dalam bahasa natural
        """
        # 180 detik, bukan 30. Dashboard menjalankan beberapa putaran
        # tool-calling ke model sebelum menyusun jawaban; pertanyaan nyata
        # terukur 9-24 detik, jadi batas 30 detik terlalu rapat dan sudah
        # menandai jawaban yang sebenarnya sedang dibuat sebagai "gangguan".
        #
        # Satu kali coba ulang untuk kegagalan koneksi. Penyebab tersering
        # bukan gangguan sungguhan melainkan backend yang sedang naik ulang
        # setelah deploy; jendelanya biasanya puluhan detik, dan sekali ulang
        # setelah jeda 5 detik menutup sebagian besar di antaranya tanpa
        # membuat user menunggu dua kali penuh.
        last_error = None
        for attempt in (1, 2):
            try:
                resp = requests.post(
                    self.valves.dashboard_api_url,
                    headers={"X-Service-Key": self.valves.dashboard_api_key},
                    json={"question": question, "user_email": __user__.get("email")},
                    timeout=180,
                )
                break
            except requests.exceptions.Timeout as e:
                last_error = e
                break
            except requests.exceptions.RequestException as e:
                last_error = e
                if attempt == 1:
                    time.sleep(5)
        else:
            resp = None

        if last_error is not None and (attempt == 2 or isinstance(last_error, requests.exceptions.Timeout)):
            if isinstance(last_error, requests.exceptions.Timeout):
                return (
                    "[INFO SISTEM] Permintaan ke sistem EBS melewati batas waktu 180 detik. "
                    "Sampaikan ke user apa adanya: pertanyaannya terlalu berat untuk diproses "
                    "sekaligus, sarankan mempersempit periode atau memecahnya jadi beberapa "
                    "pertanyaan. Jangan menebak penyebab teknis lain."
                )
            return (
                "[INFO SISTEM] Sistem EBS tidak bisa dihubungi setelah dua kali percobaan "
                "(kemungkinan sedang dideploy ulang). Sampaikan ke user apa adanya: sistem "
                "sedang tidak tersedia sesaat, coba lagi satu-dua menit lagi. "
                "Jangan menebak penyebab teknis lain."
            )

        if resp.status_code == 403:
            return (
                "[INFO SISTEM] Email user ini belum terdaftar di sistem data Oracle EBS. "
                "Sampaikan ke user apa adanya: akunnya belum didaftarkan, minta hubungi "
                "tim IT/Dashboard untuk didaftarkan. Jangan menebak penyebab lain."
            )

        if not resp.ok:
            return (
                f"[INFO SISTEM] Sistem EBS mengembalikan error (HTTP {resp.status_code}). "
                "Sampaikan ke user apa adanya bahwa ada gangguan sistem, coba lagi nanti. "
                "Jangan menebak penyebab teknisnya."
            )

        answer = (resp.json().get("answer") or "").strip()
        if not answer:
            return (
                "[INFO SISTEM] Sistem EBS tidak mengembalikan jawaban untuk pertanyaan ini "
                "(kemungkinan bug yang sedang diperbaiki tim IT). Sampaikan ke user apa adanya "
                "bahwa sistem belum bisa menjawab pertanyaan ini, jangan menebak alasan lain."
            )

        return answer

