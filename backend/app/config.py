"""Configuration for the Anxin backend.

The settings object is deliberately small and dependency free.  It can be
constructed directly by tests and reads environment variables for deployment.
"""

from __future__ import annotations

import os
import secrets
from dataclasses import dataclass, field


@dataclass(slots=True)
class Settings:
    app_name: str = "Anxin Companion API"
    environment: str = "development"
    database_url: str = "sqlite:///./anxin.db"
    # A random process-local secret is safe for an unconfigured local demo.
    # Deployments must provide AUTH_SECRET so tokens survive restarts.
    auth_secret: str = field(default_factory=lambda: secrets.token_urlsafe(32))
    access_token_ttl_seconds: int = 60 * 60 * 24
    model_api_key: str | None = None
    model_base_url: str = "https://api.openai.com/v1"
    model_name: str = "gpt-4o-mini"
    model_timeout_seconds: float = 45.0
    demo_mode: bool = False

    @classmethod
    def from_env(cls) -> "Settings":
        """Load deployment configuration from environment variables.

        ``OPENAI_API_KEY`` is accepted as an alias for ``MODEL_API_KEY`` so a
        standard OpenAI-compatible deployment can be configured without a
        second set of secrets.
        """

        defaults = cls(auth_secret=secrets.token_urlsafe(32))
        api_key = os.getenv("MODEL_API_KEY") or os.getenv("OPENAI_API_KEY")
        environment = os.getenv("APP_ENV", defaults.environment).lower()
        configured_secret = os.getenv("AUTH_SECRET")
        if environment == "production" and not configured_secret:
            raise RuntimeError("AUTH_SECRET must be configured when APP_ENV=production")
        database_url = os.getenv("DATABASE_URL", defaults.database_url)
        # SQLAlchemy's psycopg dialect is explicit here so both the familiar
        # postgres:// form and postgresql:// work in container environments.
        if database_url.startswith("postgres://"):
            database_url = "postgresql+psycopg://" + database_url[len("postgres://") :]
        elif database_url.startswith("postgresql://"):
            database_url = "postgresql+psycopg://" + database_url[len("postgresql://") :]

        return cls(
            app_name=os.getenv("APP_NAME", defaults.app_name),
            environment=environment,
            database_url=database_url,
            auth_secret=configured_secret or defaults.auth_secret,
            access_token_ttl_seconds=int(
                os.getenv("ACCESS_TOKEN_TTL_SECONDS", str(defaults.access_token_ttl_seconds))
            ),
            model_api_key=api_key,
            model_base_url=os.getenv("MODEL_BASE_URL", os.getenv("OPENAI_BASE_URL", defaults.model_base_url)),
            model_name=os.getenv("MODEL_NAME", os.getenv("OPENAI_MODEL", defaults.model_name)),
            model_timeout_seconds=float(os.getenv("MODEL_TIMEOUT_SECONDS", str(defaults.model_timeout_seconds))),
            demo_mode=os.getenv("DEMO_MODE", "").lower() in {"1", "true", "yes", "on"},
        )

    @property
    def using_demo_mode(self) -> bool:
        """Whether responses should use the deterministic demo adapter."""

        return self.demo_mode or not bool(self.model_api_key)
