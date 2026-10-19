import io
import os
from pathlib import Path

from PIL import Image


def atomic_bytes(path: Path, content: bytes):
    temporary = path.with_name(f"{path.name}.tmp-{os.getpid()}")
    try:
        with temporary.open("wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def decode_rgb(content: bytes) -> Image.Image:
    with Image.open(io.BytesIO(content)) as image:
        image.load()
        if "A" in image.getbands() or "transparency" in image.info:
            rgba = image.convert("RGBA")
            background = Image.new("RGBA", rgba.size, "white")
            background.alpha_composite(rgba)
            return background.convert("RGB")
        return image.convert("RGB")


def write_images(rgb: Image.Image, directory: Path, prefix: str, widths: tuple[int, ...], quality: int):
    directory.mkdir(parents=True, exist_ok=True)
    for width in widths:
        resized = rgb
        if rgb.width > width:
            resized = rgb.resize((width, max(1, round(rgb.height * width / rgb.width))), Image.Resampling.LANCZOS)
        data = io.BytesIO()
        resized.save(data, format="WEBP", quality=quality, method=4)
        atomic_bytes(directory / f"{prefix}-{width}.webp", data.getvalue())
