"""Record serialization: dict <-> wire format with schema version."""
import json

SCHEMA_VERSION = 1


def to_wire(record):
    """Serialize a record dict to a wire string."""
    payload = {"v": SCHEMA_VERSION, "data": dict(record)}
    return json.dumps(payload, sort_keys=True)


def from_wire(text):
    """Parse a wire string back to a record dict."""
    payload = json.loads(text)
    version = payload.get("v", 0)
    if version != SCHEMA_VERSION:
        raise ValueError(f"unsupported schema version: {version}")
    return dict(payload["data"])
