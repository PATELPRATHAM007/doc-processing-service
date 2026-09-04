import redis

from app.core.config import settings


class RedisService:
    """Manages Redis connection pooling, health checks, and client operations."""

    _pool: redis.ConnectionPool | None = None

    @classmethod
    def get_pool(cls) -> redis.ConnectionPool:
        """Get or lazily initialize the shared Redis connection pool."""
        if cls._pool is None:
            cls._pool = redis.ConnectionPool.from_url(
                settings.REDIS_URL, decode_responses=True
            )
        return cls._pool

    @classmethod
    def get_client(cls) -> redis.Redis:
        """Return a Redis client instance from the connection pool."""
        return redis.Redis(connection_pool=cls.get_pool())

    @classmethod
    def check_health(cls) -> bool:
        """Verify Redis connectivity."""
        try:
            client = cls.get_client()
            return bool(client.ping())
        except Exception:  # noqa: BLE001
            return False

    @classmethod
    def close(cls) -> None:
        """Disconnect and release connection pool resources."""
        if cls._pool is not None:
            cls._pool.disconnect()
            cls._pool = None


# Functional aliases for backward compatibility
get_redis_client = RedisService.get_client
check_redis_health = RedisService.check_health
