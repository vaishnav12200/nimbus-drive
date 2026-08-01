"""Maps a `files.storage_provider` value to a provider instance.

Providers are singletons: they hold no per-user state, so one instance serves
every request and credentials travel with each call.
"""

from __future__ import annotations

from app.core.errors import StorageError
from app.models.enums import StorageProvider as ProviderName
from app.providers.base import StorageProvider

_REGISTRY: dict[str, StorageProvider] = {}


def register_provider(provider: StorageProvider) -> None:
    _REGISTRY[provider.name] = provider


def get_provider(name: str | ProviderName = ProviderName.TELEGRAM) -> StorageProvider:
    key = str(name)
    provider = _REGISTRY.get(key)
    if provider is None:
        raise StorageError(
            f"No storage provider is registered for {key!r}",
            code="UNKNOWN_STORAGE_PROVIDER",
            details={"provider": key},
        )
    return provider


def _bootstrap() -> None:
    from app.providers.telegram import TelegramStorage

    register_provider(TelegramStorage())


_bootstrap()
