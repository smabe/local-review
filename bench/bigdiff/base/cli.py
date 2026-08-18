"""Command-line front end: get/set/delete/export against a store."""
import sys

from parser import parse_config
from store import Store


def load_settings(path):
    try:
        with open(path) as fh:
            return parse_config(fh.read())
    except FileNotFoundError:
        return {}


def main(argv):
    if len(argv) < 2:
        print("usage: cli.py <get|set|delete> ...", file=sys.stderr)
        return 2
    settings = load_settings("app.conf")
    store = Store(settings.get("store_path", "store.json"))
    cmd = argv[1]
    if cmd == "get" and len(argv) == 3:
        value = store.get(argv[2])
        if value is None:
            return 1
        print(value)
        return 0
    if cmd == "set" and len(argv) == 4:
        store.set(argv[2], argv[3])
        return 0
    if cmd == "delete" and len(argv) == 3:
        store.delete(argv[2])
        return 0
    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
