"""tv_mcp — Windows laptop reference TV remote over Android TV Remote v2.

SPEC 52d93f1 section 7.3 H. Exposes a stdio MCP server; the laptop is a
reference/control surface only and must not modify PC (BLE HID) input.

Third-party runtime dependencies (NOT iPad dependencies, do not add more):
- androidtvremote2 @ git+https://github.com/tronikos/androidtvremote2
  @b09f21432ba33e42536215a8f41641d801cf6a2c  (Apache-2.0, canonical reference)
- mcp SDK >=1,<2  (MIT)
This project's own code remains AGPL-3.0-only (see repository LICENSE).

androidtvremote2 and mcp are imported lazily so unit tests remain
dependency-free (stdlib + fakes only).
"""

__all__ = ["__version__"]
__version__ = "0.1.0"
