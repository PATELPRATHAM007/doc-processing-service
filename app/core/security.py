import base64
import json
import time
from typing import Any


class SecurityService:
    """Security service for token handling and authentication utilities."""

    @staticmethod
    def decode_token(token: str) -> dict[str, Any]:
        """Decode and parse a JWT token payload.

        Extracts claims (e.g. 'sub', 'exp') from standard JWT tokens (header.payload.signature).
        Raises ValueError on malformed or expired tokens.
        """
        parts = token.strip().split(".")
        if len(parts) < 2:
            raise ValueError("Invalid JWT token format")

        payload_b64 = parts[1]
        remainder = len(payload_b64) % 4
        if remainder:
            payload_b64 += "=" * (4 - remainder)

        try:
            decoded_bytes = base64.urlsafe_b64decode(payload_b64.encode("utf-8"))
            payload = json.loads(decoded_bytes.decode("utf-8"))
        except Exception as exc:
            raise ValueError(f"Invalid JWT payload encoding: {exc}") from exc

        if not isinstance(payload, dict):
            raise ValueError("JWT payload must be a JSON dictionary")

        exp = payload.get("exp")
        if exp is not None and isinstance(exp, (int, float)) and exp < time.time():
            raise ValueError("Token has expired")

        return payload
