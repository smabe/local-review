"""Parse simple KEY=VALUE config lines."""


def parse_config(text):
    """Return a dict of config values; later duplicates win."""
    result = {}
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"line {lineno}: expected KEY=VALUE, got {raw!r}")
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if not key:
            raise ValueError(f"line {lineno}: empty key")
        result[key] = value
    return result


def merge_defaults(config, defaults):
    """Fill missing keys from defaults without mutating either input."""
    merged = dict(defaults)
    merged.update(config)
    return merged
