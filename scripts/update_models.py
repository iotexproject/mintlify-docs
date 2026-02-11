#!/usr/bin/env python3
"""Fetch live model list and pricing from IoTeX AI Gateway and update supported-ai-models.mdx."""

import json
import urllib.request
from pathlib import Path

MODELS_URL = "https://gateway.iotex.ai/v1/models"
PRICING_URL = "https://gateway.iotex.ai/api/pricing"
OUTPUT = Path(__file__).resolve().parent.parent / "overview" / "supported-ai-models.mdx"

# Ratio 1.0 = $2/M tokens (standard one-api base unit)
BASE_UNIT = 2.0

# Map model ID prefixes to human-readable provider names
PROVIDER_MAP = {
    "gemini": "Google",
    "google/": "Google",
    "deepseek-ai/": "DeepSeek",
    "meta-llama/": "Meta",
    "Qwen/": "Qwen",
    "mistralai/": "Mistral",
    "moonshotai/": "Moonshot",
    "openai/": "OpenAI",
    "gpt-": "OpenAI",
    "black-forest-labs/": "Black Forest Labs",
    "x-ai/": "xAI",
    "openrouter/": "OpenRouter",
    "zai-org/": "Zhipu AI",
    "whisper-": "OpenAI",
}

CATEGORY_MAP = {
    "openai": "Chat",
    "gemini": "Chat",
    "image-generation": "Image",
}


def detect_provider(model_id: str, owned_by: str) -> str:
    for prefix, provider in PROVIDER_MAP.items():
        if model_id.startswith(prefix):
            return provider
    if owned_by == "vertex-ai":
        return "Google"
    if owned_by == "openai":
        return "OpenAI"
    return owned_by.replace("-", " ").title()


def detect_category(endpoint_types: list[str]) -> str:
    categories = []
    for ep in endpoint_types:
        cat = CATEGORY_MAP.get(ep, ep.replace("-", " ").title())
        if cat not in categories:
            categories.append(cat)
    return ", ".join(categories)


def format_price(value: float) -> str:
    if value == 0:
        return "Free"
    if value < 0.01:
        return f"${value:.4f}"
    if value >= 1:
        return f"${value:.2f}"
    return f"${value:.2f}"


def main():
    with urllib.request.urlopen(MODELS_URL) as resp:
        models_data = json.loads(resp.read())

    with urllib.request.urlopen(PRICING_URL) as resp:
        pricing_data = json.loads(resp.read())

    # Build pricing lookup
    pricing = {}
    for p in pricing_data["data"]:
        pricing[p["model_name"]] = p

    models = models_data["data"]
    models.sort(key=lambda m: (detect_provider(m["id"], m["owned_by"]), m["id"]))

    rows = []
    for m in models:
        model_id = m["id"]
        provider = detect_provider(model_id, m["owned_by"])
        p = pricing.get(model_id, {})
        quota_type = p.get("quota_type", 0)

        if quota_type == 1:
            # Fixed per-request pricing
            price = p.get("model_price", 0)
            input_str = f"${price}/req" if price > 0 else "Free"
            output_str = "-"
        else:
            ratio = p.get("model_ratio", 0)
            comp_ratio = p.get("completion_ratio", 1)
            input_price = ratio * BASE_UNIT
            output_price = ratio * comp_ratio * BASE_UNIT
            input_str = format_price(input_price)
            output_str = format_price(output_price)

        rows.append(f"| `{model_id}` | {provider} | {input_str} | {output_str} |")

    table = "\n".join(rows)

    content = f"""---
title: "Supported AI Models"
description: "List of AI models available through IoTeX AI Gateway"
---

IoTeX AI Gateway provides access to models from multiple leading AI providers. The model list is updated regularly as new models become available.

## Available Models ({len(models)} models)

Prices are per 1M tokens.

| Model | Provider | Input | Output |
|-------|----------|------:|-------:|
{table}

<Note>
This list may not reflect the latest additions. Call the `/v1/models` endpoint for the most up-to-date list.
</Note>

## Query Models Programmatically

```bash
curl https://gateway.iotex.ai/v1/models
```
"""

    OUTPUT.write_text(content)
    print(f"Updated {OUTPUT} with {len(models)} models")


if __name__ == "__main__":
    main()
