"""AI-koppeling: Grok via de xAI-API (XAI_API_KEY). Claude (ANTHROPIC_API_KEY) kan als alternatief.

complete(prompt, images=[...]) geeft de tekst terug; fouten worden nette AIError-uitzonderingen,
zodat een API-limiet of storing nooit de site laat crashen.
"""
import base64
import json
import os
import re

import httpx

from . import db

XAI_KEY = os.environ.get("XAI_API_KEY", "")
XAI_BASE = os.environ.get("XAI_BASE_URL", "https://api.x.ai/v1").rstrip("/")
XAI_MODEL = os.environ.get("XAI_MODEL", "grok-4.7")
XAI_MODEL_COMPLEX = os.environ.get("XAI_MODEL_COMPLEX", XAI_MODEL)
ANTHROPIC_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
CLAUDE_MODEL = os.environ.get("CLAUDE_MODEL", "claude-sonnet-5-5")
CLAUDE_MODEL_COMPLEX = os.environ.get("CLAUDE_MODEL_COMPLEX", "claude-opus-5-5")


class AIError(Exception):
    code = "upstream_error"


class AIRateLimit(AIError):
    code = "rate_limited"


class AIAuthError(AIError):
    code = "not_granted"


class AINotConfigured(AIError):
    code = "not_declared"


def provider():
    pref = os.environ.get("AI_PROVIDER", "").lower()
    if pref == "claude" and ANTHROPIC_KEY:
        return "claude"
    if XAI_KEY:
        return "grok"
    if ANTHROPIC_KEY:
        return "claude"
    return None


def model_name(tier="default"):
    p = provider()
    if p == "grok":
        return XAI_MODEL_COMPLEX if tier == "complex" else XAI_MODEL
    if p == "claude":
        return CLAUDE_MODEL_COMPLEX if tier == "complex" else CLAUDE_MODEL
    return None


def _raise_for(r, who):
    if r.status_code == 429:
        raise AIRateLimit(f"{who}: limiet bereikt, later opnieuw")
    if r.status_code in (401, 403):
        raise AIAuthError(f"{who}: sleutel wordt niet geaccepteerd")
    if r.status_code >= 400:
        raise AIError(f"{who} gaf fout {r.status_code}: {r.text[:200]}")


def complete(prompt: str, images=None, tier="default", max_tokens=4000, timeout=180):
    """images: lijst van (mime, bytes) voor JPG/PNG."""
    p = provider()
    if not p:
        raise AINotConfigured("Geen XAI_API_KEY ingesteld")
    model = model_name(tier)
    images = images or []
    try:
        if p == "grok":
            content = prompt if not images else (
                [{"type": "image_url", "image_url": {"url": f"data:{m};base64,{base64.b64encode(b).decode()}", "detail": "high"}}
                 for m, b in images] + [{"type": "text", "text": prompt}])
            r = httpx.post(f"{XAI_BASE}/chat/completions", timeout=timeout,
                           headers={"Authorization": f"Bearer {XAI_KEY}", "Content-Type": "application/json"},
                           json={"model": model, "messages": [{"role": "user", "content": content}],
                                 "max_tokens": max_tokens, "temperature": 0.2, "stream": False})
            _raise_for(r, "Grok")
            data = r.json()
            text = ((data.get("choices") or [{}])[0].get("message") or {}).get("content") or ""
            u = data.get("usage") or {}
            db.log_usage("grok", model, {"input_tokens": u.get("prompt_tokens"), "output_tokens": u.get("completion_tokens")})
            truncated = ((data.get("choices") or [{}])[0].get("finish_reason") == "length")
        else:
            content = prompt if not images else (
                [{"type": "image", "source": {"type": "base64", "media_type": m, "data": base64.b64encode(b).decode()}}
                 for m, b in images] + [{"type": "text", "text": prompt}])
            r = httpx.post("https://api.anthropic.com/v1/messages", timeout=timeout,
                           headers={"x-api-key": ANTHROPIC_KEY, "anthropic-version": "2023-06-01"},
                           json={"model": model, "max_tokens": max_tokens, "messages": [{"role": "user", "content": content}]})
            _raise_for(r, "Claude")
            data = r.json()
            text = "".join(b.get("text", "") for b in data.get("content", []) if b.get("type") == "text")
            db.log_usage("claude", model, data.get("usage") or {})
            truncated = data.get("stop_reason") == "max_tokens"
    except httpx.HTTPError as e:
        raise AIError(f"{'Grok' if p == 'grok' else 'Claude'} niet bereikbaar: {e.__class__.__name__}") from e
    return text, truncated


def parse_json(text: str):
    """Haalt JSON uit een antwoord, ook als het in ```-blokken of tussen tekst staat."""
    t = (text or "").strip()
    for cand in (t, *(m.group(1) for m in re.finditer(r"```(?:json)?\s*([\s\S]*?)```", t))):
        try:
            return json.loads(cand)
        except ValueError:
            pass
    a, b = t.find("{"), t.rfind("}")
    if a >= 0 and b > a:
        try:
            return json.loads(t[a:b + 1])
        except ValueError:
            pass
    return None
