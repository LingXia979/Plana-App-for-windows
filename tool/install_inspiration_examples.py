"""Add the requested local preview examples while Plana is closed.

No startup hook: deleted examples stay deleted. Existing entries are retained,
and the original library is backed up before the atomic JSON replacement.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import struct
import time


def install(support: Path) -> None:
    assets = Path(__file__).resolve().parents[1] / "examples/inspiration-previews"
    library = support / "tag_library.json"
    original = library.read_bytes()
    data = json.loads(original.decode("utf-8-sig"))
    if not isinstance(data, dict) or not isinstance(data.get("entries"), list):
        raise ValueError("Unexpected library format; refusing to overwrite")
    previews = support / "tag_previews"
    previews.mkdir(exist_ok=True)
    existing = {e["id"] for e in data["entries"]}
    scenes = [
        ("coastal-station", "海边", "暖光", "横图",
         "scenery, seaside, train station, ocean, sunset, clouds, no humans",
         "warm lighting, golden hour, sunset glow, long shadows"),
        ("greenhouse", "花房", "柔光", "方图",
         "scenery, greenhouse, flowers, plants, tea table, morning, no humans",
         "soft lighting, sunlight, light rays, pastel colors, depth of field"),
        ("moonlit-waterfall", "月瀑", "月光", "竖图",
         "scenery, forest, waterfall, bridge, moon, fireflies, night, no humans",
         "moonlight, blue lighting, glowing particles, atmospheric perspective"),
    ]
    added = []
    stamp = time.time_ns() // 1_000_000
    for file_id, scene, prompt, shape, scene_tags, prompt_tags in scenes:
        source = assets / f"{file_id}.png"
        raw = source.read_bytes()
        if raw[:8] != b"\x89PNG\r\n\x1a\n":
            raise ValueError(f"Invalid preview image: {source}")
        width, height = struct.unpack(">II", raw[16:24])
        for category, title, positive in [
            ("scene", scene, scene_tags), ("other", prompt, prompt_tags)
        ]:
            entry_id = f"preview_example_20261002_{category}_{file_id}"
            if entry_id in existing:
                continue
            # Each entry owns its copy, so deleting one cannot break another.
            target = previews / f"{entry_id}.png"
            if target.exists() and target.read_bytes() != raw:
                raise ValueError(f"Refusing to replace an existing image: {target}")
            if not target.exists():
                shutil.copy2(source, target)
            added.append({
                "id": entry_id,
                "category": category,
                "name": f"{title} · {width}×{height}",
                "positive": positive,
                "negative": "",
                "tags": ["预览示例", shape, f"{width}×{height}"],
                "origin": "local",
                "previews": [str(target)],
                "createdAt": stamp - len(added),
                "extra": {"previewExample": True, "width": width, "height": height},
            })
    if not added:
        print("Examples already installed; no changes.")
        return
    # Detect an app write since the read, before replacing the library.
    if library.read_bytes() != original:
        raise RuntimeError("Library changed; close Plana and retry")
    backup = support / f"tag_library.before-preview-examples-{stamp}.json"
    with backup.open("xb") as stream:
        stream.write(original)
    data["entries"].extend(added)
    pending = support / f"tag_library.examples-{stamp}.pending"
    with pending.open("x", encoding="utf-8") as stream:
        json.dump(data, stream, ensure_ascii=False, separators=(",", ":"))
        stream.flush()
        os.fsync(stream.fileno())
    try:
        os.replace(pending, library)
    except OSError as error:
        if getattr(error, "winerror", None) != 17:
            raise
        # Some Windows redirected profiles reject same-directory replacement.
        # The original backup and complete pending file both survive a failure.
        shutil.copyfile(pending, library)
        if library.read_bytes() != pending.read_bytes():
            raise IOError("Preview library verification failed")
        pending.unlink()
    checked = json.loads(library.read_text(encoding="utf-8"))
    assert checked == data
    print(json.dumps({"added": len(added), "total": len(data["entries"]),
                      "backup": str(backup)}, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--support-dir", required=True, type=Path)
    install(parser.parse_args().support_dir.resolve(strict=True))
