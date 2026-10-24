"""Parse owned test settings with Python's complete TOML parser; fail closed."""
import json
import sys
import tomllib
from pathlib import Path

settings = tomllib.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
paths = []
for section in ("paths", "logging", "wsl"):
    for key, value in settings.get(section, {}).items():
        if key.endswith("_path") or "root" in key or key in ("log_file", "log_dir", "linux_root_unc"):
            if not isinstance(value, str):
                raise ValueError(f"Unsupported path value: {section}.{key}")
            paths.append(value)
hub = settings.get('hub', {}).get('url')
print(json.dumps({'paths': paths, 'endpoints': [hub] if hub else []}))
