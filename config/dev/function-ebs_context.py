"""
title: EBS Context
author: CKDO IT
version: 1.0.0
description: Menyisipkan tanggal & periode EBS aktif ke percakapan model EBS Analyst, dan menyamarkan data sensitif sebelum dikirim ke model.
"""
# Open WebUI Filter function (Admin Panel -> Functions -> +). Pasang ke model
# "EBS Analyst" saja. Blueprint section 8.5.
#
# inlet  : tanggal hari ini, periode berjalan & periode lalu dalam format EBS
#          (JUL-26), dan email user — supaya "bulan ini"/"bulan lalu" tidak
#          ditebak model dari tanggal pelatihannya.
# redaksi: nomor rekening bank dan NPWP di pesan user diganti placeholder
#          sebelum dikirim ke model cloud (blueprint section 12, risiko "data
#          keluar ke model cloud"). Tool server tidak pernah mengembalikan
#          kolom sensitif; ini menjaga sisi yang diketik user.
import re
from datetime import date, datetime
from typing import Optional
from zoneinfo import ZoneInfo

from pydantic import BaseModel, Field

_MONTHS = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

# NPWP 15/16 digit dengan atau tanpa tanda baca, dan deret 10–16 digit yang
# didahului kata rekening/rek/account.
_NPWP = re.compile(r"\b\d{2}[.\s]?\d{3}[.\s]?\d{3}[.\s]?\d[-\s]?\d{3}[.\s]?\d{3}\b|\b\d{16}\b")
_ACCOUNT = re.compile(r"(?i)\b(rek(?:ening)?|acc(?:ount)?|no\.?\s*rek)\b[\s:.#-]*(\d[\d\s-]{8,20}\d)")


def _period(d: date) -> str:
    return f"{_MONTHS[d.month - 1]}-{d.year % 100:02d}"


class Filter:
    class Valves(BaseModel):
        priority: int = Field(0, description="Urutan filter")
        timezone: str = Field("Asia/Jakarta", description="Zona waktu untuk tanggal hari ini")
        redact_sensitive: bool = Field(True, description="Samarkan NPWP dan nomor rekening di pesan user")

    def __init__(self):
        self.valves = self.Valves()

    def inlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        today = datetime.now(ZoneInfo(self.valves.timezone)).date()
        prev = date(today.year - (today.month == 1), (today.month - 2) % 12 + 1, 1)
        email = (__user__ or {}).get("email", "-")
        ctx = (
            f"Tanggal hari ini: {today:%d-%m-%Y} ({today.isoformat()}). "
            f"Periode EBS berjalan: {_period(today)}. Periode lalu: {_period(prev)}. "
            f"User: {email}."
        )

        messages = body.get("messages", [])
        if messages and messages[0].get("role") == "system" and isinstance(messages[0].get("content"), str):
            messages[0]["content"] = f"{messages[0]['content']}\n\n{ctx}"
        else:
            messages.insert(0, {"role": "system", "content": ctx})

        if self.valves.redact_sensitive:
            for m in messages:
                if m.get("role") == "user" and isinstance(m.get("content"), str):
                    text = _ACCOUNT.sub(lambda x: f"{x.group(1)} [REKENING DISAMARKAN]", m["content"])
                    m["content"] = _NPWP.sub("[NPWP DISAMARKAN]", text)

        body["messages"] = messages
        return body

    def outlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        # Audit dilakukan di tool server (meta.chat_query_log) — setiap angka
        # yang sampai ke user sudah tercatat di sana beserta SQL-nya.
        return body

