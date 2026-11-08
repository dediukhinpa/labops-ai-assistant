"""Только для смоука: направляет обмен refresh_token на локальный мок вместо auth.openai.com."""
import os

_url = os.environ.get("SMOKE_OAUTH_URL")
if _url:
    from litellm.llms.chatgpt import authenticator

    authenticator.CHATGPT_OAUTH_TOKEN_URL = _url
