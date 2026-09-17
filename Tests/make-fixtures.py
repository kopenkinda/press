"""Small local archives for integration tests. No network or large expanded files."""
import bz2
import gzip
import io
import lzma
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import zipfile

root = Path(sys.argv[1])
helper = sys.argv[2]
root.mkdir(parents=True, exist_ok=True)
files = {"Folder/hello.txt": b"Hello from Press.\n", "notes.txt": b"Notes.\n", "Folder/caf\u00e9.txt": b"Unicode filename.\n"}
with zipfile.ZipFile(root / "Tree.zip", "w", zipfile.ZIP_DEFLATED) as archive:
    for name, data in files.items():
        archive.writestr(name, data)
    archive.writestr("Empty/", b"")
with zipfile.ZipFile(root / "Tree.zipx", "w", zipfile.ZIP_LZMA) as archive:
    for name, data in files.items():
        archive.writestr(name, data)
    archive.writestr("Empty/", b"")
shutil.copyfile(root / "Tree.zip", root / "Tree.unknown")
with tarfile.open(root / "Tree.tar", "w") as archive:
    for name, data in files.items():
        entry = tarfile.TarInfo(name)
        entry.size = len(data)
        archive.addfile(entry, io.BytesIO(data))
    entry = tarfile.TarInfo("Empty")
    entry.type = tarfile.DIRTYPE
    archive.addfile(entry)
tar = (root / "Tree.tar").read_bytes()
for ext, compress in [("gz", gzip.compress), ("bz2", bz2.compress), ("xz", lzma.compress)]:
    (root / f"Tree.tar.{ext}").write_bytes(compress(tar))
    (root / f"hello.txt.{ext}").write_bytes(compress(files["Folder/hello.txt"]))
shutil.copyfile(root / "Tree.tar.gz", root / "Tree.tgz")
(root / "Broken.tar.gz").write_bytes((root / "Tree.tar.gz").read_bytes()[:30])
(root / "Broken.zip").write_bytes(b"This is not an archive.")
with zipfile.ZipFile(root / "Traversal.zip", "w") as archive:
    archive.writestr("../escaped.txt", b"Must not escape.")
with tarfile.open(root / "Link.tar", "w") as archive:
    entry = tarfile.TarInfo("link")
    entry.type = tarfile.SYMTYPE
    entry.linkname = "../outside"
    archive.addfile(entry)
with zipfile.ZipFile(root / "Many.zip", "w") as archive:
    for index in range(10001):
        archive.writestr(f"{index}.txt", b"")
# Three falsely advertised 3.5 GB entries test the pre-extraction size guard.
with zipfile.ZipFile(root / "Oversize.zip", "w") as archive:
    for index in range(3):
        archive.writestr(f"{index}.txt", b"x")
data = bytearray((root / "Oversize.zip").read_bytes())
for signature, offset in [(b"PK\x03\x04", 22), (b"PK\x01\x02", 24)]:
    start = 0
    while (start := data.find(signature, start)) != -1:
        struct.pack_into("<I", data, start + offset, 3_500_000_000)
        start += 4
(root / "Oversize.zip").write_bytes(data)
(root / "hello.txt").write_bytes(files["Folder/hello.txt"])
for name, options in [("Plain.7z", []), ("Encrypted.7z", ["-psecret", "-mhe=on"]),
                      ("Encrypted.zip", ["-psecret", "-mem=AES256"])]:
    (root / name).unlink(missing_ok=True)
    subprocess.run([helper, "a", "-bd", *options, name, "hello.txt"], cwd=root,
                   check=True, stdout=subprocess.DEVNULL)
shutil.copyfile(Path(__file__).parent / "Fixtures/Encrypted.rar", root / "Encrypted.rar")

for name in ["Tree.tar.zst", "hello.txt.zst"]:
    shutil.copyfile(Path(__file__).parent / "Fixtures" / name, root / name)
