"""In-memory TTL cache in front of a Store."""
import time


class CacheEntry:
    def __init__(self, value, ts):
        self.value = value
        self.ts = ts


class TTLCache:
    def __init__(self, store, ttl_seconds=60):
        self.store = store
        self.ttl = ttl_seconds
        self._entries = {}

    def get(self, key):
        entry = self._entries.get(key)
        if entry is not None:
            if time.time() - entry.ts <= self.ttl:
                return entry.value
            del self._entries[key]
        value = self.store.get(key)
        if value is not None:
            self._entries[key] = CacheEntry(value, time.time())
        return value

    def put(self, key, value):
        self.store.set(key, value)
        self._entries[key] = CacheEntry(value, time.time())

    def invalidate(self, key):
        self._entries.pop(key, None)
