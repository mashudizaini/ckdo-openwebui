"""
title: Export Excel
author: CKDO IT
version: 1.0.0
description: Tombol di bawah jawaban EBS Analyst — mengubah tabel di jawaban menjadi file .xlsx.
"""
# Open WebUI Action function (Admin Panel -> Functions -> +). Blueprint 8.6.
#
# Tabel markdown dari jawaban dikirim ke dashboard (/api/v1/ebs-tools/export/xlsx),
# yang membuat file .xlsx dan mengembalikan link unduh sekali-pakai berumur
# 1 jam. File dibuat di dashboard, bukan di server Open WebUI, supaya tidak
# ada kode pengolah data yang berjalan di proses Open WebUI selain HTTP call
# ini (blueprint section 9, catatan keamanan).
from typing import Optional

import requests
from pydantic import BaseModel, Field


class Action:
    class Valves(BaseModel):
        dashboard_url: str = Field("https://dashboard.ckd-otto.com", description="Base URL dashboard CKDO")
        service_key: str = Field("", description="EBS_TOOLS_SERVICE_KEY (atau EBS_CHAT_SERVICE_KEY) dashboard")
        timeout: int = Field(60, description="Timeout HTTP (detik)")

    def __init__(self):
        self.valves = self.Valves()

    async def action(self, body: dict, __user__: Optional[dict] = None, __event_emitter__=None, **kwargs):
        messages = body.get("messages", [])
        answer = next((m.get("content", "") for m in reversed(messages) if m.get("role") == "assistant"), "")
        question = next((m.get("content", "") for m in reversed(messages) if m.get("role") == "user"), "")

        async def status(text, done=False):
            if __event_emitter__:
                await __event_emitter__({"type": "status", "data": {"description": text, "done": done}})

        if "|" not in answer:
            await status("Tidak ada tabel di jawaban ini untuk diekspor.", True)
            return

        await status("Membuat file Excel…")
        try:
            r = requests.post(
                f"{self.valves.dashboard_url.rstrip('/')}/api/v1/ebs-tools/export/xlsx",
                json={"markdown": answer, "title": (question or "EBS Analyst")[:120]},
                headers={
                    "X-Service-Key": self.valves.service_key,
                    "X-User-Email": (__user__ or {}).get("email", ""),
                },
                timeout=self.valves.timeout,
            )
            r.raise_for_status()
            data = r.json()
        except Exception as e:
            await status(f"Gagal membuat Excel: {e}", True)
            return

        url = self.valves.dashboard_url.rstrip("/") + data["path"]
        await status(f"Excel siap ({data.get('tables', 0)} tabel).", True)
        if __event_emitter__:
            await __event_emitter__({
                "type": "message",
                "data": {"content": f"\n\n[⬇️ Unduh Excel]({url}) — link berlaku 1 jam."},
            })

