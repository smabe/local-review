"""Tiny JSON-backed key-value store with atomic writes."""
import json
import os
import tempfile


class Store:
    def __init__(self, path):
        self.path = path
        self._data = {}
        if os.path.exists(path):
            with open(path) as fh:
                self._data = json.load(fh)

    def get(self, key, default=None):
        return self._data.get(key, default)

    def set(self, key, value):
        self._data[key] = value
        self._flush()

    def delete(self, key):
        if key in self._data:
            del self._data[key]
            self._flush()

    def keys_with_prefix(self, prefix):
        return [k for k in self._data if k.startswith(prefix)]

    def _flush(self):
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(self.path) or ".")
        try:
            with os.fdopen(fd, "w") as fh:
                json.dump(self._data, fh)
            os.replace(tmp, self.path)
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise
